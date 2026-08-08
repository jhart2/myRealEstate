require "test_helper"
require "stringio"

class PropertyGalleryEnhancerTest < ActiveSupport::TestCase
  test "disabled by default in test (pass-through)" do
    payload = { io: StringIO.new("x"), filename: "a.jpg", content_type: "image/jpeg" }
    out = PropertyGalleryEnhancer.enhance_payload(payload)
    assert_same payload, out
  end

  test "enhance_payload produces JPEG with enhanced metadata when enabled" do
    skip "magick missing" unless system("magick", "-version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      src = File.join(dir, "src.jpg")
      system("magick", "-size", "64x48", "xc:#886655", src, out: File::NULL, err: File::NULL)

      ClimateControlCompat.with(
        "GALLERY_ENHANCE" => "1",
        "GALLERY_ENHANCE_ESRGAN" => "0",
        "SKIP_DARKTABLE" => "1"
      ) do
        payload = {
          io: StringIO.new(File.binread(src)),
          filename: "listing.png",
          content_type: "image/png"
        }
        out = PropertyGalleryEnhancer.enhance_payload(payload)
        assert out[:metadata]["enhanced"] || out[:metadata][:enhanced]
        assert_equal "image/jpeg", out[:content_type]
        assert_match(/\.jpg\z/, out[:filename].to_s)
        bytes = out[:io].read
        assert bytes.bytesize > 100
        assert_equal [ 0xFF, 0xD8 ], bytes.bytes.first(2) # JPEG SOI
      end
    end
  end

  # Tiny ENV helper — avoid adding climate_control gem for one test.
  module ClimateControlCompat
    module_function

    def with(env)
      previous = env.keys.index_with { |k| ENV[k] }
      env.each { |k, v| ENV[k] = v }
      yield
    ensure
      previous.each do |k, v|
        if v.nil?
          ENV.delete(k)
        else
          ENV[k] = v
        end
      end
    end
  end
end
