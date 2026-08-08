# Optional listing-image polish (darktable + ImageMagick + Real-ESRGAN).
# Not part of BOK sync / PropertyGalleryIngestor — run separately when ready
# (e.g. scripts/listing_image_enhance_dry.sh, or a future gallery:enhance task).
#
# Pipeline: analyze → darktable style → adaptive ImageMagick → Real-ESRGAN → JPEG.
# Real-ESRGAN is dispatched through EsrganGpuFanout (multi-host GPU slots).
#
# Env:
#   GALLERY_ENHANCE=1           opt-in polish (default off — BOK sync must never enable this)
#   GALLERY_ENHANCE_ESRGAN=0    skip Real-ESRGAN step when enhance is on
#   GALLERY_ENHANCE_MAX_EDGE    long-edge cap before ESRGAN (default 1280)
#   ESRGAN_SLOTS                host:gpu slots (see EsrganGpuFanout::DEFAULT_SLOTS)
#   ESRGAN_MODEL / ESRGAN_SCALE / ESRGAN_TILE
require "open3"
require "json"
require "stringio"
require "tmpdir"
require "fileutils"

class PropertyGalleryEnhancer
  class Error < StandardError; end

  PIPELINE_VERSION = "tt_realty_v1".freeze
  TARGET_MEAN = 0.48
  DEFAULT_MAX_EDGE = 1280

  # CPU-staged image ready for ESRGAN (caller owns cleanup! via #cleanup!).
  StagedPrep = Struct.new(
    :work_dir, :esrgan_in, :im_out, :analysis, :filename, :prep_ms, :skip_esrgan,
    keyword_init: true
  ) do
    def cleanup!
      FileUtils.remove_entry_secure(work_dir) if work_dir && Dir.exist?(work_dir)
    rescue StandardError
      nil
    end
  end

  def self.enabled?
    ENV["GALLERY_ENHANCE"].to_s.match?(/\A(1|true|yes|on)\z/i)
  end

  def self.esrgan_enabled?
    return false unless enabled?

    ENV["GALLERY_ENHANCE_ESRGAN"].to_s !~ /\A(0|false|no|off)\z/i
  end

  # GPU slots for parallel Real-ESRGAN (delegates to EsrganGpuFanout).
  def self.esrgan_slots
    EsrganGpuFanout.slots
  end

  # payload: { io:, filename:, content_type: } → same shape (JPEG when enhanced)
  def self.enhance_payload(payload)
    return payload unless enabled?

    new.enhance_payload(payload)
  rescue StandardError => e
    Rails.logger.warn("[gallery_enhance] pass-through after error: #{e.class}: #{e.message}")
    payload
  end

  # CPU-only prep for pipeline ingest. Returns StagedPrep (must #cleanup!).
  def self.stage_cpu!(payload)
    new.stage_cpu!(payload)
  end

  # After ESRGAN (or skip): JPEG + metadata payload. Always cleans staged work dir.
  def self.finalize_staged!(staged, esrgan_png: nil, esrgan_ms: nil, queue_wait_ms: nil)
    new.finalize_staged!(staged, esrgan_png: esrgan_png, esrgan_ms: esrgan_ms, queue_wait_ms: queue_wait_ms)
  end

  def enhance_payload(payload)
    staged = stage_cpu!(payload)
    esrgan_png = nil
    esrgan_ms = nil
    begin
      if self.class.esrgan_enabled? && !staged.skip_esrgan
        esrgan_path = Pathname(staged.work_dir).join("03_esrgan.png")
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if run_esrgan!(staged.esrgan_in, esrgan_path)
          esrgan_png = esrgan_path
        end
        esrgan_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      end
      finalize_staged!(staged, esrgan_png: esrgan_png, esrgan_ms: esrgan_ms, queue_wait_ms: 0)
    rescue StandardError
      staged.cleanup!
      raise
    end
  end

  def stage_cpu!(payload)
    io = payload.fetch(:io)
    filename = payload.fetch(:filename).to_s
    bytes = io.respond_to?(:read) ? (io.rewind rescue nil; io.read) : io.to_s
    raise Error, "empty image" if bytes.blank?

    work_dir = Dir.mktmpdir("tt_gallery_enhance_")
    work = Pathname.new(work_dir)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    src = work.join("00_src.jpg")
    write_normalized_jpeg!(bytes, src)

    analysis = analyze!(src, work)
    dt_out = work.join("01_darktable.jpg")
    run_darktable!(src, dt_out, work)

    im_out = work.join("02_imagemagick.jpg")
    run_imagemagick_adaptive!(dt_out, im_out, analysis)

    skip_esrgan = !self.class.esrgan_enabled?
    esrgan_in = work.join("02b_esrgan_in.jpg")
    if skip_esrgan
      FileUtils.cp(im_out, esrgan_in)
    else
      resize_max_edge!(im_out, esrgan_in, max_edge)
    end

    prep_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    out_name = filename.sub(/\.[^.]+\z/, "")
    out_name = "image" if out_name.blank?

    StagedPrep.new(
      work_dir: work_dir,
      esrgan_in: esrgan_in,
      im_out: im_out,
      analysis: analysis,
      filename: "#{out_name}.jpg",
      prep_ms: prep_ms,
      skip_esrgan: skip_esrgan
    )
  rescue StandardError
    FileUtils.remove_entry_secure(work_dir) if work_dir && Dir.exist?(work_dir)
    raise
  end

  def finalize_staged!(staged, esrgan_png: nil, esrgan_ms: nil, queue_wait_ms: nil)
    work = Pathname.new(staged.work_dir)
    final = work.join("03_final.jpg")
    used_esrgan = false

    if esrgan_png && File.size?(esrgan_png)
      encode_jpeg!(esrgan_png, final)
      used_esrgan = true
    else
      FileUtils.cp(staged.im_out, final)
    end

    Rails.logger.info(
      "[gallery_enhance] timing prep_ms=#{staged.prep_ms} queue_wait_ms=#{queue_wait_ms || "-"} " \
      "esrgan_ms=#{esrgan_ms || "-"} esrgan=#{used_esrgan} file=#{staged.filename}"
    )

    {
      io: StringIO.new(File.binread(final)),
      filename: staged.filename,
      content_type: "image/jpeg",
      metadata: {
        enhanced: true,
        enhance_pipeline: PIPELINE_VERSION,
        enhance_analysis: staged.analysis.slice(
          "mean", "stddev", "exposure_ev", "wb_gains", "contrast", "sharpen_radius", "notes"
        ),
        enhance_timing: {
          prep_ms: staged.prep_ms,
          queue_wait_ms: queue_wait_ms,
          esrgan_ms: esrgan_ms,
          esrgan: used_esrgan
        }.compact
      }
    }
  ensure
    staged.cleanup!
  end

  private

  def magick
    @magick ||= ENV["MAGICK_BIN"].presence || which!("magick")
  end

  def identify
    @identify ||= ENV["IDENTIFY_BIN"].presence || which!("identify")
  end

  def darktable_cli
    @darktable_cli ||= ENV["DT_BIN"].presence || which("darktable-cli")
  end

  def max_edge
    Integer(ENV.fetch("GALLERY_ENHANCE_MAX_EDGE", DEFAULT_MAX_EDGE))
  end

  def which(cmd)
    path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).find do |dir|
      candidate = File.join(dir, cmd)
      File.executable?(candidate)
    end
    path && File.join(path, cmd)
  end

  def which!(cmd)
    which(cmd) || raise(Error, "missing dependency: #{cmd}")
  end

  def write_normalized_jpeg!(bytes, dest)
    tmp = "#{dest}.in"
    File.binwrite(tmp, bytes)
    ok = system(magick, tmp, "-colorspace", "sRGB", "-quality", "95", dest.to_s, out: File::NULL, err: File::NULL)
    raise Error, "magick normalize failed" unless ok && File.size?(dest)
  ensure
    FileUtils.rm_f(tmp)
  end

  def analyze!(src, work)
    global = capture!(magick, src.to_s, "-colorspace", "sRGB", "-format",
                      "%[fx:mean],%[fx:maxima],%[fx:minima],%[fx:standard_deviation]", "info:")
    rgb = capture!(magick, src.to_s, "-colorspace", "RGB", "-format",
                   "%[fx:mean.r],%[fx:mean.g],%[fx:mean.b]", "info:")
    ident = capture!(identify, "-format", "%w %h %m", src.to_s)
    mean, maxima, minima, stddev = global.split(",").map(&:to_f)
    r, g, b = rgb.split(",").map(&:to_f)
    w, h, fmt = ident.split
    exposure_ev = [[(TARGET_MEAN - mean) * 2.4, -1.25].max, 1.25].min
    eps = 1e-6
    ref = [ g, eps ].max
    wb_r = [[ref / [ r, eps ].max, 0.85].max, 1.18].min
    wb_b = [[ref / [ b, eps ].max, 0.85].max, 1.18].min
    contrast = if stddev < 0.12
      1.12
    elsif stddev > 0.28
      0.94
    else
      1.0
    end
    sharpen = stddev < 0.18 ? 0.55 : 0.35
    notes = []
    notes << "underexposed" if mean < 0.35
    notes << "bright" if mean > 0.62
    notes << "wb_cast" if (wb_r - 1).abs > 0.04 || (wb_b - 1).abs > 0.04

    {
      "width" => w.to_i,
      "height" => h.to_i,
      "format" => fmt.to_s,
      "mean" => mean,
      "min" => minima,
      "max" => maxima,
      "stddev" => stddev,
      "rgb_mean" => { "r" => r, "g" => g, "b" => b },
      "exposure_ev" => exposure_ev.round(3),
      "wb_gains" => { "r" => wb_r.round(4), "g" => 1.0, "b" => wb_b.round(4) },
      "contrast" => contrast.round(3),
      "sharpen_radius" => sharpen.round(3),
      "notes" => notes
    }.tap { |a| File.write(work.join("analysis.json"), JSON.pretty_generate(a)) }
  end

  def run_darktable!(src, dst, work)
    install_style!
    if darktable_cli.blank? || ENV["SKIP_DARKTABLE"].to_s.match?(/\A(1|true|yes)\z/i)
      FileUtils.cp(src, dst)
      return
    end

    style_args = []
    style_file = Pathname(Dir.home).join(".config/darktable/styles/tt_realty_listing.dtstyle")
    if style_file.file? && style_file.read.include?("<plugin>")
      style_args = [ "--style", "tt_realty_listing", "--style-overwrite" ]
    end

    log = work.join("darktable.log")
    ok = system(darktable_cli, src.to_s, dst.to_s, *style_args, "--hq", "true",
                out: log.to_s, err: log.to_s)
    return if ok && File.size?(dst)

    FileUtils.rm_f(dst)
    ok = system(darktable_cli, src.to_s, dst.to_s, "--hq", "true", out: log.to_s, err: log.to_s)
    FileUtils.cp(src, dst) unless ok && File.size?(dst)
  end

  def install_style!
    return if self.class.instance_variable_get(:@style_installed)

    installer = Rails.root.join("scripts/image_enhance/install_style.py")
    system("python3", installer.to_s, out: File::NULL, err: File::NULL) if installer.file?
    self.class.instance_variable_set(:@style_installed, true)
  end

  def run_imagemagick_adaptive!(src, dst, analysis)
    ev = analysis["exposure_ev"].to_f
    brightness = [[ev * 10.0, -18.0].max, 18.0].min
    contrast = ((analysis["contrast"].to_f - 1.0) * 100).round
    wb = analysis["wb_gains"]
    sharpen = analysis["sharpen_radius"].to_f
    sig = 2.2 + (analysis["notes"].include?("underexposed") ? 0.8 : 0.0)
    cmd = [
      magick, src.to_s,
      "-colorspace", "sRGB",
      "-channel", "R", "-evaluate", "multiply", wb["r"].to_s,
      "-channel", "B", "-evaluate", "multiply", wb["b"].to_s,
      "+channel",
      "-brightness-contrast", format("%+.1fx%+d", brightness, contrast),
      "-sigmoidal-contrast", format("%.1fx50%%", sig),
      "-unsharp", format("0x%.3f+0.65+0.02", sharpen),
      "-quality", "92",
      dst.to_s
    ]
    ok = system(*cmd, out: File::NULL, err: File::NULL)
    raise Error, "adaptive ImageMagick failed" unless ok && File.size?(dst)
  end

  def resize_max_edge!(src, dst, edge)
    ok = system(magick, src.to_s, "-resize", "#{edge}x#{edge}>", "-quality", "92", dst.to_s,
                out: File::NULL, err: File::NULL)
    raise Error, "resize failed" unless ok && File.size?(dst)
  end

  def encode_jpeg!(src, dst)
    ok = system(magick, src.to_s, "-colorspace", "sRGB", "-strip", "-quality", "88", dst.to_s,
                out: File::NULL, err: File::NULL)
    raise Error, "jpeg encode failed" unless ok && File.size?(dst)
  end

  def run_esrgan!(src, dst)
    result = EsrganGpuFanout.enhance!(src, dst, raise_on_error: false)
    return true if result&.ok

    Rails.logger.warn("[gallery_enhance] ESRGAN skipped — #{result&.error || "unknown"}")
    false
  rescue EsrganGpuFanout::Error => e
    Rails.logger.warn("[gallery_enhance] ESRGAN error: #{e.message}")
    false
  end

  def capture!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise Error, "command failed: #{cmd.join(' ')} — #{out}" unless status.success?

    out.to_s.strip
  end
end
