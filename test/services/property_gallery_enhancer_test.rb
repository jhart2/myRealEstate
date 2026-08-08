require "test_helper"
require "stringio"

class PropertyGalleryEnhancerTest < ActiveSupport::TestCase
  test "disabled by default (pass-through) unless GALLERY_ENHANCE=1" do
    ClimateControlCompat.with("GALLERY_ENHANCE" => nil) do
      refute PropertyGalleryEnhancer.enabled?
      payload = { io: StringIO.new("x"), filename: "a.jpg", content_type: "image/jpeg" }
      out = PropertyGalleryEnhancer.enhance_payload(payload)
      assert_same payload, out
    end
  end

  test "default ESRGAN slots include Windows fleet plus jays-mbp" do
    ClimateControlCompat.with("ESRGAN_SLOTS" => nil) do
      slots = PropertyGalleryEnhancer.esrgan_slots
      assert_equal 6, slots.size
      assert_equal %w[bosgame_g0 zephyrus_g1 zephyrus_g0 gpdwin_g0 ayaneo_g0 jays-mbp_g0], slots.map(&:id)
      assert_equal [ 0, 1, 0, 0, 0, 0 ], slots.map(&:gpu)
    end
  end

  test "ESRGAN_SLOTS overrides default fanout slots" do
    ClimateControlCompat.with("ESRGAN_SLOTS" => "zephyrus:1,zephyrus:0") do
      slots = PropertyGalleryEnhancer.esrgan_slots
      assert_equal %w[zephyrus_g1 zephyrus_g0], slots.map(&:id)
    end
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
