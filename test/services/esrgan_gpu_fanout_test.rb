require "test_helper"
require "tmpdir"
require "fileutils"

class EsrganGpuFanoutTest < ActiveSupport::TestCase
  test "parse_slots builds host gpu ids" do
    slots = EsrganGpuFanout.parse_slots("bosgame:0,zephyrus:1,zephyrus:0")
    assert_equal %w[bosgame_g0 zephyrus_g1 zephyrus_g0], slots.map(&:id)
    assert_equal [ 0, 1, 0 ], slots.map(&:gpu)
  end

  test "default slots include Windows GPUs plus jays-mbp Mac (Intel Mac opt-in)" do
    ClimateControlCompat.with("ESRGAN_SLOTS" => nil) do
      slots = EsrganGpuFanout.slots
      assert_equal 6, slots.size
      assert_equal %w[bosgame_g0 zephyrus_g1 zephyrus_g0 gpdwin_g0 ayaneo_g0 jays-mbp_g0], slots.map(&:id)
    end
  end

  test "ESRGAN_SLOTS env overrides defaults" do
    ClimateControlCompat.with("ESRGAN_SLOTS" => "ayaneo:0,gpdwin:0") do
      assert_equal %w[ayaneo_g0 gpdwin_g0], EsrganGpuFanout.slots.map(&:id)
    end
  end

  test "process_all fans work across slot workers using stubbed enhance" do
    slots = EsrganGpuFanout.parse_slots("host_a:0,host_b:0")
    fanout = EsrganGpuFanout.new(slots: slots, probe_ttl: 60)

    Dir.mktmpdir do |dir|
      inputs = 4.times.map do |i|
        path = File.join(dir, "in_#{i}.jpg")
        File.binwrite(path, "jpeg-#{i}")
        path
      end
      out_dir = File.join(dir, "out")

      calls = Queue.new
      fanout.define_singleton_method(:warmup_hosts!) { true }
      fanout.define_singleton_method(:ensure_host!) { |_host| true }
      fanout.define_singleton_method(:with_slot_flock) { |_slot, &blk| blk.call }
      fanout.define_singleton_method(:run_on_slot!) do |slot, src, dst, **_kwargs|
        calls << slot.id
        FileUtils.cp(src, dst)
        true
      end

      summary = fanout.process_all(inputs, out_dir: out_dir, concurrency: 2)
      assert_equal 4, summary[:ok_count]
      assert_equal 0, summary[:fail_count]
      assert summary[:imgs_per_min] > 0
      seen = []
      seen << calls.pop until calls.empty?
      assert_equal 4, seen.size
      assert_includes seen, "host_a_g0"
      assert_includes seen, "host_b_g0"
    end
  ensure
    fanout&.shutdown!
  end

  test "speed schedule prefers free slot with lower EWMA latency" do
    slots = EsrganGpuFanout.parse_slots("fast:0,slow:0")
    fanout = EsrganGpuFanout.new(slots: slots, probe_ttl: 60, schedule: "speed")
    fanout.instance_variable_get(:@latency_ewma)["fast_g0"] = 2.0
    fanout.instance_variable_get(:@latency_ewma)["slow_g0"] = 20.0

    chosen = 6.times.map do
      s = fanout.send(:acquire_live_slot, wait: false, job_cost: 1.0)
      fanout.send(:release_slot, s)
      s.id
    end
    assert_equal [ "fast_g0" ], chosen.uniq
  ensure
    fanout&.shutdown!
  end

  test "speed schedule uses slow slot when it is the only free worker" do
    slots = EsrganGpuFanout.parse_slots("fast:0,slow:0")
    fanout = EsrganGpuFanout.new(slots: slots, probe_ttl: 60, schedule: "speed")
    fanout.instance_variable_get(:@latency_ewma)["fast_g0"] = 2.0
    fanout.instance_variable_get(:@latency_ewma)["slow_g0"] = 20.0
    fast = fanout.send(:acquire_live_slot, wait: false, job_cost: 1.0)
    assert_equal "fast_g0", fast.id
    slow = fanout.send(:acquire_live_slot, wait: false, job_cost: 1.0)
    assert_equal "slow_g0", slow.id
    fanout.send(:release_slot, fast)
    fanout.send(:release_slot, slow)
  ensure
    fanout&.shutdown!
  end

  test "estimate_job_cost rises with file size" do
    Dir.mktmpdir do |dir|
      small = File.join(dir, "s.bin")
      big = File.join(dir, "b.bin")
      File.binwrite(small, "x" * 1_000)
      File.binwrite(big, "y" * 2_000_000)
      assert EsrganGpuFanout.estimate_job_cost(big) > EsrganGpuFanout.estimate_job_cost(small)
    end
  end

  test "any free slot can be grabbed without waiting on peers (FIFO pool)" do
    slots = EsrganGpuFanout.parse_slots("fast:0,slow:0")
    fanout = EsrganGpuFanout.new(slots: slots, probe_ttl: 60, schedule: "fifo")
    fanout.define_singleton_method(:ensure_host!) { |_h| true }
    fanout.define_singleton_method(:with_slot_flock) { |_s, &b| b.call }
    started = Queue.new
    release_slow = Queue.new
    fanout.define_singleton_method(:run_on_slot!) do |slot, src, dst, **_|
      started << slot.id
      release_slow.pop if slot.id == "slow_g0"
      FileUtils.cp(src, dst)
      true
    end

    Dir.mktmpdir do |dir|
      a = File.join(dir, "a.jpg")
      b = File.join(dir, "b.jpg")
      File.binwrite(a, "a")
      File.binwrite(b, "b")
      t1 = Thread.new { fanout.enhance!(a, File.join(dir, "a.png"), raise_on_error: false) }
      sleep 0.05
      t2 = Thread.new { fanout.enhance!(b, File.join(dir, "b.png"), raise_on_error: false) }
      ids = [ started.pop, started.pop ]
      assert_equal %w[fast_g0 slow_g0].sort, ids.sort
      release_slow << true
      assert t1.value.ok
      assert t2.value.ok
    end
  ensure
    fanout&.shutdown!
  end


  test "run_on_slot dispatches unix vs windows helpers" do
    slots = EsrganGpuFanout.parse_slots("mac:0,win:0")
    fanout = EsrganGpuFanout.new(slots: slots, probe_ttl: 60)
    seen = []
    fanout.define_singleton_method(:detect_host_kind!) do |host|
      host.to_s.start_with?("mac") ? :unix : :windows
    end
    fanout.define_singleton_method(:run_on_unix_slot!) do |slot, *_|
      seen << ["unix", slot.id]
      true
    end
    fanout.define_singleton_method(:run_on_windows_slot!) do |slot, *_|
      seen << ["win", slot.id]
      true
    end
    Dir.mktmpdir do |dir|
      src = File.join(dir, "in.jpg")
      File.binwrite(src, "x")
      dst = File.join(dir, "out.png")
      fanout.send(:run_on_slot!, slots[0], Pathname(src), Pathname(dst), model: nil, scale: nil, tile: nil)
      fanout.send(:run_on_slot!, slots[1], Pathname(src), Pathname(dst), model: nil, scale: nil, tile: nil)
    end
    assert_equal [["unix", "mac_g0"], ["win", "win_g0"]], seen
  ensure
    fanout&.shutdown!
  end

  test "unreachable hosts are quarantined and skip the free queue" do
    slots = EsrganGpuFanout.parse_slots("dead:0,live:0")
    fanout = EsrganGpuFanout.new(slots: slots, probe_ttl: 60)
    fanout.define_singleton_method(:quarantine_seconds) { 60.0 }
    fanout.define_singleton_method(:ensure_host!) do |host|
      raise EsrganGpuFanout::HostUnreachableError, "down" if host == "dead"

      true
    end
    fanout.define_singleton_method(:with_slot_flock) { |_s, &b| b.call }
    fanout.define_singleton_method(:run_on_slot!) do |_slot, src, dst, **_|
      FileUtils.cp(src, dst)
      true
    end

    Dir.mktmpdir do |dir|
      src = File.join(dir, "in.jpg")
      File.binwrite(src, "x")

      quarantined = false
      8.times do |i|
        out = File.join(dir, "t_#{i}.png")
        result = fanout.enhance!(src, out, raise_on_error: false)
        if !result.ok && result.error.to_s.include?("down")
          quarantined = true
          break
        end
      end
      assert quarantined, "expected dead host to fail once and quarantine"

      4.times do |i|
        out = File.join(dir, "ok_#{i}.png")
        ok = fanout.enhance!(src, out, raise_on_error: false)
        assert ok.ok, "expected live slot ok on attempt #{i}: #{ok.error}"
        assert_equal "live", ok.host
      end
    end
  ensure
    fanout&.shutdown!
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
