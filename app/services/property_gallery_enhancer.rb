# Polishes a downloaded listing image before Active Storage upload.
# Pipeline: analyze → darktable style → adaptive ImageMagick → Real-ESRGAN (bosgame) → JPEG.
#
# Env:
#   GALLERY_ENHANCE=0           disable entirely (pass-through)
#   GALLERY_ENHANCE_ESRGAN=0    skip Real-ESRGAN step
#   GALLERY_ENHANCE_MAX_EDGE    long-edge cap before ESRGAN (default 1280)
#   SSH_HOST                    Real-ESRGAN host (default bosgame)
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

  def self.enabled?
    return false if Rails.env.test? && ENV["GALLERY_ENHANCE"].nil?

    ENV["GALLERY_ENHANCE"].to_s !~ /\A(0|false|no|off)\z/i
  end

  def self.esrgan_enabled?
    ENV["GALLERY_ENHANCE_ESRGAN"].to_s !~ /\A(0|false|no|off)\z/i
  end

  # payload: { io:, filename:, content_type: } → same shape (JPEG when enhanced)
  def self.enhance_payload(payload)
    return payload unless enabled?

    new.enhance_payload(payload)
  rescue StandardError => e
    Rails.logger.warn("[gallery_enhance] pass-through after error: #{e.class}: #{e.message}")
    payload
  end

  def enhance_payload(payload)
    io = payload.fetch(:io)
    filename = payload.fetch(:filename).to_s
    bytes = io.respond_to?(:read) ? (io.rewind rescue nil; io.read) : io.to_s
    raise Error, "empty image" if bytes.blank?

    Dir.mktmpdir("tt_gallery_enhance_") do |dir|
      work = Pathname.new(dir)
      src = work.join("00_src.jpg")
      write_normalized_jpeg!(bytes, src)

      analysis = analyze!(src, work)
      dt_out = work.join("01_darktable.jpg")
      run_darktable!(src, dt_out, work)

      im_out = work.join("02_imagemagick.jpg")
      run_imagemagick_adaptive!(dt_out, im_out, analysis)

      final = work.join("03_final.jpg")
      if self.class.esrgan_enabled?
        esrgan_in = work.join("02b_esrgan_in.jpg")
        resize_max_edge!(im_out, esrgan_in, max_edge)
        esrgan_png = work.join("03_esrgan.png")
        if run_esrgan!(esrgan_in, esrgan_png, work)
          encode_jpeg!(esrgan_png, final)
        else
          FileUtils.cp(im_out, final)
        end
      else
        FileUtils.cp(im_out, final)
      end

      out_name = filename.sub(/\.[^.]+\z/, "")
      out_name = "image" if out_name.blank?
      {
        io: StringIO.new(File.binread(final)),
        filename: "#{out_name}.jpg",
        content_type: "image/jpeg",
        metadata: {
          enhanced: true,
          enhance_pipeline: PIPELINE_VERSION,
          enhance_analysis: analysis.slice(
            "mean", "stddev", "exposure_ev", "wb_gains", "contrast", "sharpen_radius", "notes"
          )
        }
      }
    end
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

  def ssh_host
    ENV.fetch("SSH_HOST", "bosgame")
  end

  def esrgan_model
    ENV.fetch("ESRGAN_MODEL", "realesr-animevideov3")
  end

  def esrgan_scale
    ENV.fetch("ESRGAN_SCALE", "2")
  end

  def esrgan_tile
    ENV.fetch("ESRGAN_TILE", "64")
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
    installer = Rails.root.join("scripts/image_enhance/install_style.py")
    return unless installer.file?

    system("python3", installer.to_s, out: File::NULL, err: File::NULL)
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

  def run_esrgan!(src, dst, work)
    return false unless ssh_available?

    lock_path = Rails.root.join("tmp/gallery_esrgan.lock")
    FileUtils.mkdir_p(lock_path.dirname)
    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      locked = lock.flock(File::LOCK_EX | File::LOCK_NB)
      unless locked
        Rails.logger.info("[gallery_enhance] ESRGAN busy — waiting for FIFO slot")
        lock.flock(File::LOCK_EX)
      end

      remote_in = "#{ssh_host}:AppData/Local/Temp/tt_enhance_in.jpg"
      ps1 = Rails.root.join("scripts/image_enhance/tt_enhance_once.ps1")
      return false unless system("scp", "-q", "-o", "BatchMode=yes", src.to_s, remote_in,
                                  out: File::NULL, err: File::NULL)
      return false unless system("scp", "-q", "-o", "BatchMode=yes", ps1.to_s,
                                  "#{ssh_host}:tools/realesrgan-ncnn-vulkan/tt_enhance_once.ps1",
                                  out: File::NULL, err: File::NULL)

      log = work.join("esrgan_remote.log").to_s
      cmd = [
        "ssh", "-o", "BatchMode=yes", ssh_host,
        "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\\tools\\realesrgan-ncnn-vulkan\\tt_enhance_once.ps1 " \
        "-Model #{esrgan_model} -Scale #{esrgan_scale} -Tile #{esrgan_tile}"
      ]
      out, status = Open3.capture2e(*cmd)
      File.write(log, out.to_s)
      unless system("scp", "-q", "-o", "BatchMode=yes",
                    "#{ssh_host}:AppData/Local/Temp/tt_enhance_out.png", dst.to_s,
                    out: File::NULL, err: File::NULL)
        return false
      end
      return false unless File.size?(dst)

      Rails.logger.info("[gallery_enhance] ESRGAN ok model=#{esrgan_model} scale=#{esrgan_scale} rc=#{status.exitstatus}")
      true
    end
  rescue StandardError => e
    Rails.logger.warn("[gallery_enhance] ESRGAN error: #{e.message}")
    false
  end

  def ssh_available?
    system("ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", ssh_host, "echo", "ok",
           out: File::NULL, err: File::NULL)
  end

  def capture!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise Error, "command failed: #{cmd.join(' ')} — #{out}" unless status.success?

    out.to_s.strip
  end
end
