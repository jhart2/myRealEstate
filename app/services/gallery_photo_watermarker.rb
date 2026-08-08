# Burns the TT Realty brand mark into gallery download bytes (bottom-right, soft).
class GalleryPhotoWatermarker
  DEFAULT_OPACITY = 0.45
  WIDTH_RATIO = 0.22
  MIN_MARK_WIDTH = 120
  MAX_MARK_WIDTH = 420
  PADDING_RATIO = 0.03

  class Error < StandardError; end

  def self.call(binary, content_type: "image/jpeg", opacity: DEFAULT_OPACITY)
    new(binary, content_type: content_type, opacity: opacity).call
  end

  def initialize(binary, content_type: "image/jpeg", opacity: DEFAULT_OPACITY)
    @binary = binary
    @content_type = content_type.to_s.presence || "image/jpeg"
    @opacity = opacity.to_f.clamp(0.05, 1.0)
  end

  def call
    require "vips"
    require "image_processing/vips"

    raise Error, "empty image" if @binary.blank?

    image = Vips::Image.new_from_buffer(@binary, "")
    image = image.colourspace("srgb") if image.interpretation != :srgb
    image = ensure_alpha(image)

    mark = load_mark_for(image)
    x = [ image.width - mark.width - padding_for(image.width), 0 ].max
    y = [ image.height - mark.height - padding_for(image.height), 0 ].max

    composed = image.composite(mark, :over, x: [ x ], y: [ y ])
    composed = composed.flatten(background: [ 0, 0, 0 ]) if composed.has_alpha?

    pipeline = ImageProcessing::Vips.source(composed).convert("jpg").saver(quality: 90, strip: true)
    file = pipeline.call
    data = File.binread(file.path)
    file.close!
    data
  rescue LoadError, Vips::Error => e
    raise Error, e.message
  end

  private

  def load_mark_for(image)
    mark = brand_mark_rgba
    target_w = (image.width * WIDTH_RATIO).round.clamp(MIN_MARK_WIDTH, MAX_MARK_WIDTH)
    scale = target_w.to_f / mark.width
    mark = mark.resize(scale) if (scale - 1.0).abs > 0.01

    rgb = mark.extract_band(0, n: 3)
    alpha = mark.extract_band(3) * @opacity
    rgb.bandjoin(alpha)
  end

  # Soft white "TT" + trinidad "REALTY" — mirrors the site header brand.
  def brand_mark_rgba
    tt = Vips::Image.text(
      "TT",
      font: "sans bold 72",
      rgba: true,
      align: :low
    )
    # Force near-white RGB, keep glyph alpha.
    tt_rgb = tt.new_from_image([ 255, 255, 255 ]).copy(interpretation: :srgb)
    tt = tt_rgb.bandjoin(tt.extract_band(3))

    realty = Vips::Image.text(
      "REALTY",
      font: "sans bold 22",
      rgba: true,
      align: :low
    )
    # Brand trinidad-ish red #CE1528
    realty_rgb = realty.new_from_image([ 206, 21, 40 ]).copy(interpretation: :srgb)
    realty = realty_rgb.bandjoin(realty.extract_band(3))

    gap = 14
    height = [ tt.height, realty.height ].max
    width = tt.width + gap + realty.width
    canvas = Vips::Image.black(width, height, bands: 4).copy(interpretation: :srgb)

    tt_y = [ ((height - tt.height) / 2.0).round, 0 ].max
    realty_y = [ ((height - realty.height) / 2.0).round + 4, 0 ].max

    canvas = canvas.insert(tt, 0, tt_y)
    canvas.insert(realty, tt.width + gap, realty_y)
  end

  def ensure_alpha(image)
    return image if image.has_alpha?

    image.bandjoin(image.new_from_image(255))
  end

  def padding_for(dimension)
    [ (dimension * PADDING_RATIO).round, 16 ].max
  end
end
