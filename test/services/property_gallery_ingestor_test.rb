require "test_helper"
require "uri"
require "stringio"

class PropertyGalleryIngestorTest < ActiveSupport::TestCase
  setup do
    Property.delete_all
    Agent.delete_all

    @agent = Agent.create!(
      name: "Gallery Ingest Agent",
      title: "Agent",
      email: "gallery-ingest-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )

    @url_a = "https://cdn.example.com/photos/a.jpg"
    @url_b = "https://cdn.example.com/photos/b.jpg"
    @property = Property.create!(
      agent: @agent,
      title: "Ingest Home",
      slug: "ingest-home-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "1 Test St",
      city: "Port of Spain",
      state: "Trinidad",
      zip: "",
      price_cents: 100_000_00,
      image_url: @url_a,
      image_urls: [ @url_a, @url_b ]
    )
  end

  test "attaches each gallery URL once and is idempotent" do
    calls = Hash.new(0)
    downloader = lambda do |url|
      calls[url] += 1
      {
        io: StringIO.new("fake-image-#{url}"),
        filename: File.basename(URI.parse(url).path),
        content_type: "image/jpeg"
      }
    end

    first = PropertyGalleryIngestor.call(@property, downloader: downloader)
    assert_equal 2, first[:attached]
    assert_equal 0, first[:skipped]
    assert_equal 0, first[:errors].size
    assert_equal 2, @property.reload.gallery_images.count
    assert_equal [ @url_a, @url_b ], @property.hosted_gallery_images.map { |img|
      PropertyGalleryIngestor.source_urls_for(img.blob)
    }.flatten.uniq.sort

    second = PropertyGalleryIngestor.call(@property, downloader: downloader)
    assert_equal 0, second[:attached]
    assert_equal 2, second[:skipped]
    assert_equal 2, @property.reload.gallery_images.count
    assert_equal 1, calls[@url_a]
    assert_equal 1, calls[@url_b]
  end

  test "purges hosted images removed from source gallery" do
    downloader = lambda do |url|
      {
        io: StringIO.new("fake-image-#{url}"),
        filename: File.basename(URI.parse(url).path),
        content_type: "image/jpeg"
      }
    end

    PropertyGalleryIngestor.call(@property, downloader: downloader)
    assert_equal 2, @property.reload.gallery_images.count

    @property.update!(image_url: @url_a, image_urls: [ @url_a ])
    result = PropertyGalleryIngestor.call(@property, downloader: downloader)

    assert_equal 1, result[:purged]
    assert_equal [ @url_a ], @property.reload.hosted_gallery_images.flat_map { |img|
      PropertyGalleryIngestor.source_urls_for(img.blob)
    }.uniq
  end

  test "gallery_ingest_needed is false after ingest" do
    assert @property.gallery_ingest_needed?

    PropertyGalleryIngestor.call(@property, downloader: lambda do |url|
      {
        io: StringIO.new("x"),
        filename: "x.jpg",
        content_type: "image/jpeg"
      }
    end)

    assert_not @property.reload.gallery_ingest_needed?
  end

  test "enqueue_gallery_ingest! queues a gallery_ingest job when needed" do
    assert_enqueued_with(job: PropertyImageIngestJob, args: [ @property.id ], queue: "gallery_ingest") do
      assert @property.enqueue_gallery_ingest!
    end
  end

  test "concurrency > 1 processes missing URLs in parallel" do
    in_flight = 0
    max_in_flight = 0
    mutex = Mutex.new

    downloader = lambda do |url|
      mutex.synchronize do
        in_flight += 1
        max_in_flight = [ max_in_flight, in_flight ].max
      end
      sleep 0.08
      mutex.synchronize { in_flight -= 1 }
      {
        io: StringIO.new("fake-image-#{url}-#{SecureRandom.hex(4)}"),
        filename: File.basename(URI.parse(url).path),
        content_type: "image/jpeg"
      }
    end

    result = PropertyGalleryIngestor.call(
      @property,
      downloader: downloader,
      concurrency: 2
    )

    assert_equal 2, result[:attached]
    assert_equal 0, result[:errors].size
    assert_operator max_in_flight, :>=, 2, "expected overlapping downloads, max_in_flight=#{max_in_flight}"
    assert_equal 2, @property.reload.gallery_images.count
    assert_equal [ @url_a, @url_b ], @property.hosted_gallery_images.flat_map { |img|
      PropertyGalleryIngestor.source_urls_for(img.blob)
    }.uniq
  end

  test "per-URL errors do not abort parallel ingest" do
    downloader = lambda do |url|
      raise PropertyGalleryIngestor::DownloadError, "boom" if url == @url_a

      {
        io: StringIO.new("fake-image-#{url}-#{SecureRandom.hex(4)}"),
        filename: File.basename(URI.parse(url).path),
        content_type: "image/jpeg"
      }
    end

    result = PropertyGalleryIngestor.call(@property, downloader: downloader, concurrency: 2)
    assert_equal 1, result[:attached]
    assert_equal 1, result[:errors].size
    assert_match(/boom/, result[:errors].first)
    assert_equal 1, @property.reload.gallery_images.count
  end

  test "ascii_url percent-encodes unicode spaces in paths" do
    raw = "https://mybunchofkeys.com/wp-content/uploads/2026/04/Screenshot-2026-04-28-at-10.56.34\u202FAM.png"
    encoded = PropertyGalleryIngestor.ascii_url(raw)

    assert encoded.ascii_only?
    assert_includes encoded, "%E2%80%AFAM.png"
    assert_nothing_raised { URI.parse(encoded) }
  end

  test "attach_blob! links by blob_id without gallery_images.attach" do
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("shared-bytes"),
      filename: "shared.jpg",
      content_type: "image/jpeg",
      metadata: { source_url: @url_a, source_urls: [ @url_a ] }
    )

    PropertyGalleryIngestor.new(@property, downloader: ->(_) { raise "unused" }).send(:attach_blob!, blob)

    assert_equal 1, @property.reload.gallery_images.count
    assert_equal blob.id, @property.gallery_images.first.blob_id
  end

  test "enhancer metadata is stored when enhance runs" do
    enhancer = lambda do |payload|
      payload.merge(metadata: { enhanced: true, enhance_pipeline: "test" }, filename: "polished.jpg")
    end
    downloader = lambda do |url|
      { io: StringIO.new("fake-#{url}"), filename: File.basename(URI.parse(url).path), content_type: "image/jpeg" }
    end
    result = PropertyGalleryIngestor.call(@property, downloader: downloader, enhancer: enhancer)
    assert_equal 2, result[:attached]
    assert_equal 2, result[:enhanced]
  end

  test "gpu pipeline stages CPU prep ahead of ESRGAN" do
    skip "magick missing" unless system("magick", "-version", out: File::NULL, err: File::NULL)

    Dir.mktmpdir do |dir|
      sample = File.join(dir, "sample.jpg")
      system("magick", "-size", "32x24", "xc:#445566", sample, out: File::NULL, err: File::NULL)

      ClimateControlCompat.with(
        "GALLERY_ENHANCE" => "1",
        "GALLERY_ENHANCE_ESRGAN" => "1",
        "SKIP_DARKTABLE" => "1",
        "ESRGAN_SLOTS" => "stub_a:0,stub_b:0",
        "GALLERY_PREP_CONCURRENCY" => "2"
      ) do
        EsrganGpuFanout.reset_shared!
        fanout = EsrganGpuFanout.shared
        fanout.define_singleton_method(:warmup_hosts!) { true }
        fanout.define_singleton_method(:ensure_host!) { |_h| true }
        fanout.define_singleton_method(:with_slot_flock) { |_s, &b| b.call }
        fanout.define_singleton_method(:run_on_slot!) do |_slot, src, dst, **_kwargs|
          FileUtils.cp(src, dst)
          true
        end

        downloader = lambda do |url|
          {
            io: StringIO.new(File.binread(sample)),
            filename: File.basename(URI.parse(url).path),
            content_type: "image/jpeg"
          }
        end
        result = PropertyGalleryIngestor.call(@property, downloader: downloader)
        assert_equal 2, result[:attached]
        assert_equal 2, result[:enhanced]
        assert result[:timings].size >= 2
      end
    end
  ensure
    EsrganGpuFanout.reset_shared!
  end

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
