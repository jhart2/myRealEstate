# Dedicated Real-ESRGAN fanout across remote GPU slots (SSH + scp).
#
# Dynamic speed scheduling (default):
#   - Track EWMA latency per slot; when several slots are free, prefer the fastest.
#   - process_all / batches order work heaviest-first (file size ≈ cost) so big jobs
#     land on fast workers while they are free (list scheduling / LPT).
#   - Slow slots still run when they are the only free workers — no idle waiting.
# ESRGAN_SCHEDULE=fifo disables speed preference (legacy any-free-slot pop).
#
# Env:
#   ESRGAN_SLOTS              host:gpu pairs (default below)
#   ESRGAN_SCHEDULE           speed (default) | fifo
#   ESRGAN_MODEL / ESRGAN_SCALE / ESRGAN_TILE
#   ESRGAN_SSH_CONTROL_DIR    ControlMaster socket dir (default /tmp/tt_esrgan_ssh; must not contain spaces)
#   ESRGAN_HOST_PROBE_TTL     seconds to trust a warm host (default 60)
require "open3"
require "fileutils"
require "digest"
require "securerandom"
require "pathname"
require "thread"
require "timeout"
require "set"

class EsrganGpuFanout
  class Error < StandardError; end
  class SlotBusyError < Error; end
  class HostUnreachableError < Error; end

  DEFAULT_SLOTS = "bosgame:0,zephyrus:1,zephyrus:0,gpdwin:0,ayaneo:0,jays-mbp:0".freeze
  REMOTE_SCRIPT_WIN = "tools/realesrgan-ncnn-vulkan/tt_enhance_once.ps1".freeze
  REMOTE_SCRIPT_UNIX = "tools/realesrgan-ncnn-vulkan/tt_enhance_once.sh".freeze
  REMOTE_SCRIPT_REL = REMOTE_SCRIPT_WIN
  PS1_LOCAL = Rails.root.join("scripts/image_enhance/tt_enhance_once.ps1")
  SH_LOCAL = Rails.root.join("scripts/image_enhance/tt_enhance_once.sh")

  # Seed EWMA until real samples arrive (seconds). Faster seeds → priority early on.
  LATENCY_HINTS = {
    "zephyrus_g1" => 3.0,
    "jays-mbp_g0" => 2.5, # Apple M5 / MoltenVK
    "bosgame_g0" => 4.0,
    "zephyrus_g0" => 4.5,
    "gpdwin_g0" => 6.5,
    "ayaneo_g0" => 8.0,
    "devs-macbook_g0" => 12.0
  }.freeze
  LATENCY_EWMA_ALPHA = 0.35
  DEFAULT_LATENCY_S = 5.0

  Slot = Struct.new(:host, :gpu, :id, keyword_init: true)

  Result = Struct.new(
    :ok, :src, :dst, :slot_id, :host, :gpu, :elapsed_s, :error,
    keyword_init: true
  )

  class << self
    def slots(raw = ENV["ESRGAN_SLOTS"].presence || DEFAULT_SLOTS)
      parse_slots(raw)
    end

    def parse_slots(raw)
      raw.to_s.split(/[,\s]+/).filter_map do |pair|
        host, idx = pair.split(":", 2)
        next if host.blank? || idx.blank?

        host = host.strip
        gpu = idx.strip.to_i
        Slot.new(host: host, gpu: gpu, id: "#{host.gsub(/[^\w.-]/, "_")}_g#{gpu}")
      end
    end

    def speed_schedule?
      ENV.fetch("ESRGAN_SCHEDULE", "speed").to_s !~ /\A(fifo|fair|off|0)\z/i
    end

    def shared
      @shared_mutex ||= Mutex.new
      @shared_mutex.synchronize { @shared ||= new(slots: slots) }
    end

    def reset_shared!
      @shared_mutex ||= Mutex.new
      @shared_mutex.synchronize do
        @shared&.shutdown!
        @shared = nil
      end
    end

    def enhance!(src_path, dst_path, **opts)
      shared.enhance!(src_path, dst_path, **opts)
    end

    # Cheap proxy for ESRGAN work: pixel count when identify works, else file bytes.
    def estimate_job_cost(path)
      path = Pathname(path)
      return 1.0 unless path.file?

      dims = image_megapixels(path)
      return dims if dims

      [ File.size(path) / 250_000.0, 0.25 ].max
    end

    def image_megapixels(path)
      out, status = Open3.capture2e("identify", "-format", "%w %h", path.to_s)
      return nil unless status.success?

      w, h = out.to_s.strip.split.map(&:to_i)
      return nil unless w.positive? && h.positive?

      (w * h) / 1_000_000.0
    rescue StandardError
      nil
    end
  end

  def initialize(slots:, control_dir: nil, probe_ttl: nil, schedule: nil)
    @slots = Array(slots).freeze
    raise Error, "no ESRGAN slots configured" if @slots.empty?

    @speed = schedule.nil? ? self.class.speed_schedule? : schedule.to_s != "fifo"
    @control_dir = Pathname(
      control_dir || ENV["ESRGAN_SSH_CONTROL_DIR"].presence || "/tmp/tt_esrgan_ssh"
    )
    @probe_ttl = (probe_ttl || ENV.fetch("ESRGAN_HOST_PROBE_TTL", "60")).to_f
    @host_ok_until = {}
    @host_script_digest = {}
    @host_kind = {}
    @host_quarantine_until = {}
    @quarantine_park = []
    @host_mutex = Mutex.new
    @masters_started = {}
    @slot_mutex = Mutex.new
    @slot_cv = ConditionVariable.new
    @free_slots = @slots.dup
    @latency_ewma = {}
    @slots.each { |s| @latency_ewma[s.id] = LATENCY_HINTS.fetch(s.id, DEFAULT_LATENCY_S) }
    FileUtils.mkdir_p(@control_dir)
  end

  attr_reader :slots

  def speed_schedule?
    @speed
  end

  def enhance!(src_path, dst_path, model: nil, scale: nil, tile: nil, wait: true, raise_on_error: true, job_cost: nil)
    src = Pathname(src_path)
    dst = Pathname(dst_path)
    raise Error, "missing input #{src}" unless src.file?

    cost = job_cost || self.class.estimate_job_cost(src)
    slot = nil
    quarantined = false
    t0 = nil
    begin
      slot = acquire_live_slot(wait: wait, job_cost: cost)
      raise SlotBusyError, "no free ESRGAN slot" unless slot

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ensure_host!(slot.host)
      with_slot_flock(slot) do
        run_on_slot!(slot, src, dst, model: model, scale: scale, tile: tile)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      note_slot_latency!(slot, elapsed)
      Rails.logger.info(
        "[gallery_enhance] ESRGAN ok slot=#{slot.id} host=#{slot.host} gpu=#{slot.gpu} " \
        "elapsed_ms=#{(elapsed * 1000).round} ewma_s=#{slot_latency(slot).round(2)} cost=#{cost.round(2)}"
      )
      Result.new(
        ok: true, src: src.to_s, dst: dst.to_s, slot_id: slot.id,
        host: slot.host, gpu: slot.gpu, elapsed_s: elapsed, error: nil
      )
    rescue HostUnreachableError => e
      quarantined = true
      quarantine_host!(slot.host) if slot
      elapsed = t0 ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) : 0.0
      result = Result.new(
        ok: false, src: src.to_s, dst: dst.to_s, slot_id: slot&.id,
        host: slot&.host, gpu: slot&.gpu, elapsed_s: elapsed, error: e.message
      )
      raise if raise_on_error

      result
    rescue StandardError => e
      elapsed = t0 ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) : 0.0
      result = Result.new(
        ok: false, src: src.to_s, dst: dst.to_s, slot_id: slot&.id,
        host: slot&.host, gpu: slot&.gpu, elapsed_s: elapsed, error: e.message
      )
      raise if raise_on_error

      result
    ensure
      if slot
        if quarantined
          park_quarantined_slot!(slot)
        else
          release_slot(slot)
        end
      end
    end
  end

  def process_all(src_paths, out_dir:, model: nil, scale: nil, tile: nil, concurrency: nil)
    paths = Array(src_paths).map { |p| Pathname(p) }
    raise Error, "no inputs" if paths.empty?

    FileUtils.mkdir_p(out_dir)
    workers = [ concurrency || @slots.size, 1 ].max

    # Heaviest-first so large jobs claim fast slots while available (LPT list scheduling).
    ranked = paths.each_with_index.map do |src, i|
      [ i, src, self.class.estimate_job_cost(src) ]
    end
    ranked.sort_by! { |(_i, _src, cost)| -cost }

    queue = Queue.new
    ranked.each { |i, src, cost| queue << [ i, src, cost ] }

    results = Array.new(paths.size)
    finish_mutex = Mutex.new
    idle_gaps = []
    last_finish = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    warmup_hosts!

    threads = Array.new(workers) do
      Thread.new do
        loop do
          item = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          idx, src, cost = item
          dst = Pathname(out_dir).join(format("%04d_%s.png", idx, src.basename(src.extname)))
          result = enhance!(
            src, dst, model: model, scale: scale, tile: tile,
            wait: true, raise_on_error: false, job_cost: cost
          )
          finish_mutex.synchronize do
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if last_finish
              gap = now - last_finish
              idle_gaps << gap if gap > 0.05
            end
            last_finish = now
            results[idx] = result
          end
        end
      end
    end

    threads.each(&:join)
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    oks = results.compact.select(&:ok)
    {
      results: results,
      wall_s: wall,
      ok_count: oks.size,
      fail_count: results.compact.count { |r| !r.ok },
      imgs_per_min: wall.positive? ? (oks.size / (wall / 60.0)) : 0.0,
      idle_gaps_s: idle_gaps,
      latencies_s: oks.map(&:elapsed_s),
      per_slot: oks.group_by(&:slot_id).transform_values(&:size),
      schedule: @speed ? "speed" : "fifo",
      latency_ewma: latency_snapshot
    }
  end

  def shutdown!
    @slots.map(&:host).uniq.each { |host| stop_master(host) }
    true
  ensure
    @masters_started.clear
    @host_ok_until.clear
    @host_script_digest.clear
  end

  def stats_snapshot
    @slot_mutex.synchronize do
      {
        schedule: @speed ? "speed" : "fifo",
        slots: @slots.map { |s| { id: s.id, host: s.host, gpu: s.gpu, ewma_s: @latency_ewma[s.id] } },
        free: @free_slots.map(&:id),
        hosts_warm: @masters_started.keys,
        scripts: @host_script_digest.dup
      }
    end
  end

  def latency_snapshot
    @slot_mutex.synchronize { @latency_ewma.dup }
  end

  private

  # Prefer the currently-free slot with lowest EWMA latency (speed schedule).
  def acquire_live_slot(wait:, job_cost: 1.0)
    loop do
      flush_expired_quarantine_park!

      slot = nil
      @slot_mutex.synchronize do
        slot = pick_free_slot_locked(job_cost: job_cost)
        if slot.nil? && wait
          @slot_cv.wait(@slot_mutex, 0.25)
          flush_expired_quarantine_park_locked
          slot = pick_free_slot_locked(job_cost: job_cost)
        end
        @free_slots.delete(slot) if slot
      end

      return nil if slot.nil? && !wait
      next if slot.nil?

      if host_quarantined?(slot.host)
        park_quarantined_slot!(slot)
        next
      end

      return slot
    end
  end

  def pick_free_slot_locked(job_cost:)
    live = []
    parked = []
    @free_slots.each do |s|
      if host_quarantined?(s.host)
        parked << s
      else
        live << s
      end
    end
    unless parked.empty?
      @free_slots -= parked
      parked.each { |s| @quarantine_park << s }
    end
    return nil if live.empty?

    return live.first unless @speed

    # Predicted duration ∝ ewma (cost is relative within a batch; same for all free).
    live.min_by { |s| slot_latency_locked(s) * [ job_cost.to_f, 0.01 ].max }
  end

  def slot_latency(slot)
    @slot_mutex.synchronize { slot_latency_locked(slot) }
  end

  def slot_latency_locked(slot)
    @latency_ewma[slot.id] || DEFAULT_LATENCY_S
  end

  def note_slot_latency!(slot, elapsed_s)
    @slot_mutex.synchronize do
      prev = @latency_ewma[slot.id] || DEFAULT_LATENCY_S
      @latency_ewma[slot.id] = (LATENCY_EWMA_ALPHA * elapsed_s) + ((1.0 - LATENCY_EWMA_ALPHA) * prev)
    end
  end

  def release_slot(slot)
    if host_quarantined?(slot.host)
      park_quarantined_slot!(slot)
      return
    end

    @slot_mutex.synchronize do
      @free_slots << slot unless @free_slots.include?(slot)
      @slot_cv.broadcast
    end
  end

  def quarantine_seconds
    ENV.fetch("ESRGAN_HOST_QUARANTINE_S", "180").to_f
  end

  def host_quarantined?(host)
    until_t = @host_mutex.synchronize { @host_quarantine_until[host].to_f }
    until_t > Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def quarantine_host!(host)
    until_t = Process.clock_gettime(Process::CLOCK_MONOTONIC) + quarantine_seconds
    @host_mutex.synchronize do
      @host_quarantine_until[host] = until_t
      @host_ok_until.delete(host)
    end
    Rails.logger.warn(
      "[gallery_enhance] quarantined host=#{host} for #{quarantine_seconds.round}s"
    )
  end

  def park_quarantined_slot!(slot)
    @slot_mutex.synchronize do
      @quarantine_park << slot unless @quarantine_park.include?(slot)
      @slot_cv.broadcast
    end
  end

  def flush_expired_quarantine_park!
    @slot_mutex.synchronize { flush_expired_quarantine_park_locked }
  end

  def flush_expired_quarantine_park_locked
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    revive = []
    remain = []
    @quarantine_park.each do |slot|
      until_t = @host_quarantine_until[slot.host].to_f
      if until_t <= now
        @host_quarantine_until.delete(slot.host)
        revive << slot
      else
        remain << slot
      end
    end
    @quarantine_park = remain
    revive.each do |s|
      @free_slots << s unless @free_slots.include?(s)
    end
    @slot_cv.broadcast unless revive.empty?
  end

  def with_slot_flock(slot)
    lock_path = Rails.root.join("tmp", "gallery_esrgan_#{slot.id}.lock")
    FileUtils.mkdir_p(lock_path.dirname)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    ensure
      lock.flock(File::LOCK_UN) rescue nil
    end
  end

  def model_name
    ENV.fetch("ESRGAN_MODEL", "realesr-animevideov3")
  end

  def scale_value
    ENV.fetch("ESRGAN_SCALE", "2")
  end

  def tile_value
    ENV.fetch("ESRGAN_TILE", "64")
  end

  def ssh_base_opts(host)
    [
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=8",
      "-o", "ControlMaster=auto",
      "-o", "ControlPath=#{control_path(host)}",
      "-o", "ControlPersist=300"
    ]
  end

  def control_path(host)
    @control_dir.join("cm-#{host.gsub(/[^\w.-]/, "_")}").to_s
  end

  def warmup_hosts!
    @slots.map(&:host).uniq.each { |host| ensure_host!(host) }
  end

  def ensure_host!(host)
    @host_mutex.synchronize do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @host_ok_until[host].to_f > now && master_alive?(host) && @host_script_digest[host]
        return true
      end

      start_master!(host)
      deploy_script!(host)
      @host_ok_until[host] = now + @probe_ttl
      true
    end
  end

  def start_master!(host)
    if master_alive?(host)
      @masters_started[host] = true
      return
    end

    FileUtils.mkdir_p(@control_dir)
    # ControlMaster=auto + ControlPersist: first session becomes master and persists.
    ok = system(
      "ssh", *ssh_base_opts(host),
      host, "echo", "ok",
      out: File::NULL, err: File::NULL
    )
    raise HostUnreachableError, "ssh master failed for #{host}" unless ok
    raise HostUnreachableError, "ssh master socket missing for #{host}" unless master_alive?(host)

    @masters_started[host] = true
  end

  def master_alive?(host)
    system(
      "ssh", "-o", "ControlPath=#{control_path(host)}", "-O", "check", host,
      out: File::NULL, err: File::NULL
    )
  end

  def stop_master(host)
    system(
      "ssh", "-o", "ControlPath=#{control_path(host)}", "-O", "exit", host,
      out: File::NULL, err: File::NULL
    )
  rescue StandardError
    nil
  end

  def detect_host_kind!(host)
    return @host_kind[host] if @host_kind[host]

    out, status = Open3.capture2e(
      "ssh", *ssh_base_opts(host), host,
      "uname -s"
    )
    kind =
      if status.success? && out.to_s.strip.match?(/\A(Darwin|Linux)\z/i)
        :unix
      else
        :windows
      end
    @host_kind[host] = kind
  end

  def deploy_script!(host)
    kind = detect_host_kind!(host)
    if kind == :unix
      deploy_unix_script!(host)
    else
      deploy_windows_script!(host)
    end
  end

  def deploy_windows_script!(host)
    raise Error, "missing #{PS1_LOCAL}" unless PS1_LOCAL.file?

    digest = Digest::SHA256.file(PS1_LOCAL).hexdigest
    return if @host_script_digest[host] == digest

    # Ensure toolkit dir under the remote user's profile (works for javon/dev/...).
    ok_mkdir = system(
      "ssh", *ssh_base_opts(host), host,
      "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path (Join-Path \$env:USERPROFILE 'tools\\realesrgan-ncnn-vulkan') | Out-Null\"",
      out: File::NULL, err: File::NULL
    )
    raise Error, "mkdir remote toolkit on #{host} failed" unless ok_mkdir

    remote = "#{host}:#{REMOTE_SCRIPT_WIN}"
    ok = system(
      "scp", "-q", *ssh_base_opts(host), PS1_LOCAL.to_s, remote,
      out: File::NULL, err: File::NULL
    )
    raise Error, "scp ps1 to #{host} failed" unless ok

    @host_script_digest[host] = digest
  end

  def deploy_unix_script!(host)
    raise Error, "missing #{SH_LOCAL}" unless SH_LOCAL.file?

    digest = Digest::SHA256.file(SH_LOCAL).hexdigest
    return if @host_script_digest[host] == digest

    ok_mkdir = system(
      "ssh", *ssh_base_opts(host), host,
      "mkdir -p \"$HOME/tools/realesrgan-ncnn-vulkan\"",
      out: File::NULL, err: File::NULL
    )
    raise Error, "mkdir remote toolkit on #{host} failed" unless ok_mkdir

    remote = "#{host}:#{REMOTE_SCRIPT_UNIX}"
    ok = system(
      "scp", "-q", *ssh_base_opts(host), SH_LOCAL.to_s, remote,
      out: File::NULL, err: File::NULL
    )
    raise Error, "scp sh to #{host} failed" unless ok

    ok_chmod = system(
      "ssh", *ssh_base_opts(host), host,
      "chmod +x \"$HOME/#{REMOTE_SCRIPT_UNIX}\"",
      out: File::NULL, err: File::NULL
    )
    raise Error, "chmod remote sh on #{host} failed" unless ok_chmod

    @host_script_digest[host] = digest
  end

  def run_on_slot!(slot, src, dst, model:, scale:, tile:)
    kind = detect_host_kind!(slot.host)
    if kind == :unix
      run_on_unix_slot!(slot, src, dst, model: model, scale: scale, tile: tile)
    else
      run_on_windows_slot!(slot, src, dst, model: model, scale: scale, tile: tile)
    end
  end

  def run_on_windows_slot!(slot, src, dst, model:, scale:, tile:)
    host = slot.host
    gpu = slot.gpu
    token = SecureRandom.hex(4)
    remote_in_name = "tt_fanout_in_#{slot.id}_#{token}.jpg"
    remote_out_name = "tt_fanout_out_#{slot.id}_#{token}.png"
    remote_in = "#{host}:AppData/Local/Temp/#{remote_in_name}"
    remote_out = "#{host}:AppData/Local/Temp/#{remote_out_name}"
    win_in = "%TEMP%\\#{remote_in_name}"
    win_out = "%TEMP%\\#{remote_out_name}"

    model ||= model_name
    scale ||= scale_value
    tile ||= tile_value

    unless system("scp", "-q", *ssh_base_opts(host), src.to_s, remote_in, out: File::NULL, err: File::NULL)
      invalidate_host!(host)
      raise Error, "scp in failed host=#{host}"
    end

    cmd = [
      "ssh", *ssh_base_opts(host), host,
      "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\\#{REMOTE_SCRIPT_WIN.tr("/", "\\")} " \
      "-Model #{model} -Scale #{scale} -Tile #{tile} -Gpu #{gpu} " \
      "-In #{win_in} -Out #{win_out}"
    ]
    out, status = Open3.capture2e(*cmd)
    unless status.success?
      invalidate_host!(host)
      raise Error, "esrgan ssh failed host=#{host} rc=#{status.exitstatus}: #{out.to_s.lines.last(8).join}"
    end

    unless system("scp", "-q", *ssh_base_opts(host), remote_out, dst.to_s, out: File::NULL, err: File::NULL)
      invalidate_host!(host)
      raise Error, "scp out failed host=#{host}"
    end
    raise Error, "empty esrgan output" unless File.size?(dst)

    system(
      "ssh", *ssh_base_opts(host), host,
      "del /q %TEMP%\\#{remote_in_name} %TEMP%\\#{remote_out_name} 2>nul",
      out: File::NULL, err: File::NULL
    )

    true
  end

  def run_on_unix_slot!(slot, src, dst, model:, scale:, tile:)
    host = slot.host
    gpu = slot.gpu
    token = SecureRandom.hex(4)
    remote_in_name = "tt_fanout_in_#{slot.id}_#{token}.jpg"
    remote_out_name = "tt_fanout_out_#{slot.id}_#{token}.png"
    remote_in = "#{host}:/tmp/#{remote_in_name}"
    remote_out = "#{host}:/tmp/#{remote_out_name}"
    unix_in = "/tmp/#{remote_in_name}"
    unix_out = "/tmp/#{remote_out_name}"

    model ||= model_name
    scale ||= scale_value
    tile ||= tile_value

    unless system("scp", "-q", *ssh_base_opts(host), src.to_s, remote_in, out: File::NULL, err: File::NULL)
      invalidate_host!(host)
      raise Error, "scp in failed host=#{host}"
    end

    cmd = [
      "ssh", *ssh_base_opts(host), host,
      "bash \"$HOME/#{REMOTE_SCRIPT_UNIX}\" " \
      "-Model #{model} -Scale #{scale} -Tile #{tile} -Gpu #{gpu} " \
      "-In #{unix_in} -Out #{unix_out}"
    ]
    out, status = Open3.capture2e(*cmd)
    unless status.success?
      invalidate_host!(host)
      raise Error, "esrgan ssh failed host=#{host} rc=#{status.exitstatus}: #{out.to_s.lines.last(8).join}"
    end

    unless system("scp", "-q", *ssh_base_opts(host), remote_out, dst.to_s, out: File::NULL, err: File::NULL)
      invalidate_host!(host)
      raise Error, "scp out failed host=#{host}"
    end
    raise Error, "empty esrgan output" unless File.size?(dst)

    system(
      "ssh", *ssh_base_opts(host), host,
      "rm -f #{unix_in} #{unix_out}",
      out: File::NULL, err: File::NULL
    )

    true
  end

  def invalidate_host!(host)
    @host_mutex.synchronize do
      @host_ok_until.delete(host)
    end
  end
end
