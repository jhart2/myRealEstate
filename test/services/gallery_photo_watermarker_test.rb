require "test_helper"

class GalleryPhotoWatermarkerTest < ActiveSupport::TestCase
  setup do
    require "vips"
  end

  test "composites brand mark and returns jpeg bytes larger context than empty" do
    source = Vips::Image.black(640, 480, bands: 3).copy(interpretation: :srgb)
    binary = source.jpegsave_buffer(Q: 90)

    stamped = GalleryPhotoWatermarker.call(binary)
    assert_operator stamped.bytesize, :>, 1_000

    out = Vips::Image.new_from_buffer(stamped, "")
    assert_equal 640, out.width
    assert_equal 480, out.height
  end

  test "raises on blank input" do
    assert_raises(GalleryPhotoWatermarker::Error) do
      GalleryPhotoWatermarker.call("")
    end
  end
end
