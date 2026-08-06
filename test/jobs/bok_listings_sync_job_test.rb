require "test_helper"

class BokListingsSyncJobTest < ActiveSupport::TestCase
  setup do
    @out_dir = Rails.root.join("tmp/bok_sync_job_test_#{SecureRandom.hex(4)}")
    @out_dir.mkpath
    @json_path = @out_dir.join("houses_last_month_20260806_120000.json")
    @agent = Agent.create!(
      name: "Sync Test Agent",
      title: "Agent",
      email: "sync-agent-#{SecureRandom.hex(3)}@example.com",
      phone: "",
      bio: "t",
      active: true,
      show_on_homepage: false,
      listings_count: 0
    )
  end

  teardown do
    FileUtils.rm_rf(@out_dir) if @out_dir&.exist?
  end

  test "seeds known source_urls into progress cache before scrape" do
    Property.create!(
      agent: @agent,
      bok_id: "BOK-KNOWN-1",
      source_url: "https://mybunchofkeys.com/property/known-home/",
      title: "Known Home",
      slug: "known-home-#{SecureRandom.hex(3)}",
      tag: "sale",
      property_type: "House",
      status: "active",
      address: "1 Test St",
      city: "Port of Spain",
      state: "Trinidad",
      zip: "",
      price_cents: 100_000_00,
      description: "Known"
    )

    @json_path.write("[]")
    out_dir = @out_dir
    json_path = @json_path

    job = Class.new(BokListingsSyncJob) do
      define_method(:out_dir) { out_dir }
      define_method(:run_scraper!) { |**| json_path }
    end.new

    empty_result = BokListingsImporter::Result.new(
      created: 0, updated: 0, skipped: 0, removed: 0, errors: []
    )
    original = BokListingsImporter.method(:import!)
    BokListingsImporter.define_singleton_method(:import!) { |*_args, **_kwargs| empty_result }

    begin
      summary = job.perform(days: 7, max_details: 10, delay: 4, skip_search_crawl: true)
      assert_equal json_path.to_s, summary[:json_path]
    ensure
      BokListingsImporter.define_singleton_method(:import!, original)
    end

    cache = JSON.parse(@out_dir.join("progress_cache.json").read)
    assert cache["completed"].key?("https://mybunchofkeys.com/property/known-home/")
    assert_equal "already_in_db", cache["completed"]["https://mybunchofkeys.com/property/known-home/"]["reason"]
  end

  test "raises when scraper exits non-zero" do
    out_dir = @out_dir
    job = Class.new(BokListingsSyncJob) do
      define_method(:out_dir) { out_dir }
      define_method(:execute_scraper!) { |_cmd| false }
    end.new

    error = assert_raises(BokListingsSyncJob::SyncError) do
      job.perform(days: 1, max_details: 1, delay: 4, skip_search_crawl: true)
    end
    assert_match(/scraper exited/i, error.message)
  end
end
