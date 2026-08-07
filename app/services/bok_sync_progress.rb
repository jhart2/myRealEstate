# Mirror sync progress to stdout so `journalctl --user -u bok-listings-sync -f`
# stays informative during long import / AI / geocode stretches.
#
# Quiet in test, or when BOK_SYNC_QUIET=1.
module BokSyncProgress
  module_function

  def say(message)
    return if quiet?

    line = "[bok:sync] #{message}"
    $stdout.puts(line)
    $stdout.flush
    Rails.logger.info(line) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
  rescue StandardError
    # Never break sync on logging failure.
  end

  def quiet?
    return true if ENV["BOK_SYNC_QUIET"].to_s == "1"
    return true if defined?(Rails) && Rails.env.test?

    false
  end

  def every
    Integer(ENV.fetch("BOK_SYNC_PROGRESS_EVERY", "25"))
  rescue ArgumentError, TypeError
    25
  end
end
