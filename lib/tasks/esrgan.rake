# frozen_string_literal: true

namespace :esrgan do
  desc <<~DESC.gsub(/\s+/, " ").strip
    Benchmark EsrganGpuFanout across live GPU slots.
    N=20 COUNT=20 (images) SLOTS=bosgame:0,zephyrus:1,... CONCURRENCY=5
    INPUT=/path/to.jpg (copied N times) or generates a synthetic JPEG.
    OUT=tmp/esrgan_fanout_bench
  DESC
  task bench: :environment do
    $stdout.sync = true
    require "fileutils"

    n = Integer(ENV["N"].presence || ENV["COUNT"].presence || 20)
    slots_raw = ENV["ESRGAN_SLOTS"].presence || EsrganGpuFanout::DEFAULT_SLOTS
    concurrency = Integer(ENV["CONCURRENCY"].presence || slots_raw.to_s.split(/[,\s]+/).size)
    out_root = Pathname(ENV["OUT"].presence || Rails.root.join("tmp/esrgan_fanout_bench"))
    run_dir = out_root.join(Time.now.strftime("%Y%m%d_%H%M%S"))
    FileUtils.mkdir_p(run_dir)

    sample = ENV["INPUT"].presence
    unless sample && File.file?(sample)
      sample = run_dir.join("sample.jpg").to_s
      edge = Integer(ENV.fetch("EDGE", "960"))
      ok = system(
        "magick", "-size", "#{edge}x#{(edge * 0.75).to_i}", "plasma:fractal",
        "-quality", "90", sample,
        out: File::NULL, err: File::NULL
      )
      abort "magick failed to create sample (#{sample})" unless ok && File.size?(sample)
    end

    inputs_dir = run_dir.join("inputs")
    FileUtils.mkdir_p(inputs_dir)
    inputs = n.times.map do |i|
      dest = inputs_dir.join(format("img_%03d.jpg", i))
      FileUtils.cp(sample, dest)
      dest
    end

    slots = EsrganGpuFanout.parse_slots(slots_raw)
    fanout = EsrganGpuFanout.new(slots: slots)
    puts "ESRGAN fanout bench"
    puts "  slots=#{slots.map(&:id).join(",")}"
    puts "  concurrency=#{concurrency} n=#{n} sample=#{sample} (#{File.size(sample)} bytes)"
    puts "  out=#{run_dir}"

    begin
      t_warm = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fanout.send(:warmup_hosts!)
      warm_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_warm
      puts "  warmup_hosts=#{warm_s.round(2)}s hosts=#{fanout.stats_snapshot[:hosts_warm].join(",")}"

      summary = fanout.process_all(
        inputs,
        out_dir: run_dir.join("outputs"),
        concurrency: concurrency
      )
    ensure
      fanout.shutdown!
      EsrganGpuFanout.reset_shared!
    end

    lats = summary[:latencies_s].sort
    def pct(arr, p)
      return nil if arr.empty?

      arr[[ ((arr.size - 1) * p).round, arr.size - 1 ].min]
    end

    gaps = summary[:idle_gaps_s].sort
    puts
    puts "Results"
    puts "  ok=#{summary[:ok_count]} fail=#{summary[:fail_count]} wall=#{summary[:wall_s].round(2)}s"
    puts "  imgs/min=#{summary[:imgs_per_min].round(2)}"
    puts "  latency_s p50=#{pct(lats, 0.5)&.round(2)} p95=#{pct(lats, 0.95)&.round(2)} " \
         "mean=#{lats.empty? ? 0 : (lats.sum / lats.size).round(2)}"
    puts "  per_slot=#{summary[:per_slot].inspect}"
    puts "  schedule=#{summary[:schedule]} ewma=#{summary[:latency_ewma].inspect}" if summary[:schedule]
    puts "  idle_gap_s count=#{gaps.size} p50=#{pct(gaps, 0.5)&.round(3)} " \
         "max=#{gaps.last&.round(3)}"

    summary[:results].compact.reject(&:ok).first(5).each do |r|
      puts "  FAIL idx_src=#{r.src} slot=#{r.slot_id} err=#{r.error}"
    end

    report = {
      slots: slots.map(&:id),
      concurrency: concurrency,
      n: n,
      sample_bytes: File.size(sample),
      warmup_s: warm_s,
      imgs_per_min: summary[:imgs_per_min],
      wall_s: summary[:wall_s],
      ok_count: summary[:ok_count],
      fail_count: summary[:fail_count],
      per_slot: summary[:per_slot],
      schedule: summary[:schedule],
      latency_ewma: summary[:latency_ewma],
      latency_p50: pct(lats, 0.5),
      latency_p95: pct(lats, 0.95),
      idle_gap_p50: pct(gaps, 0.5),
      idle_gap_max: gaps.last
    }
    File.write(run_dir.join("report.json"), JSON.pretty_generate(report))
    puts "  wrote #{run_dir.join("report.json")}"
  end
end
