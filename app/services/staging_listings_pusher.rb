# Pushes a BOK listings JSON feed into the staging Cloud SQL database.
#
#   StagingListingsPusher.push!(path)
#
# Used by BokListingsSyncJob after a successful local import so hourly sync
# also lands on Cloud Run staging. Requires gcloud + cloud-sql-proxy.
#
# Env:
#   BOK_SYNC_PUSH_STAGING       "0" to disable (default: enabled outside test)
#   STAGING_GCP_PROJECT         default tt-realty-staging
#   STAGING_CLOUDSQL_CONNECTION default tt-realty-staging:us-east1:tt-realty-stg-db
#   STAGING_SQL_PROXY_PORT      default 5433
#
class StagingListingsPusher
  class PushError < StandardError; end

  def self.enabled?
    return false if Rails.env.test?

    raw = ENV["BOK_SYNC_PUSH_STAGING"]
    return true if raw.nil?

    !%w[0 false off no].include?(raw.to_s.strip.downcase)
  end

  def self.push!(json_path)
    new(json_path).push!
  end

  def initialize(json_path)
    @json_path = Pathname.new(json_path)
  end

  def push!
    raise PushError, "JSON not found: #{@json_path}" unless @json_path.exist?
    raise PushError, "Missing push script at #{script_path}" unless script_path.exist?

    cmd = [ "bash", script_path.to_s, @json_path.to_s ]
    Rails.logger.info("[StagingListingsPusher] #{cmd.join(" ")}")

    ok = system(
      {
        "PATH" => [
          "#{Dir.home}/.local/share/google-cloud-sdk/bin",
          "#{Dir.home}/.local/share/mise/shims",
          "#{Dir.home}/.local/bin",
          ENV.fetch("PATH", "/usr/bin:/bin")
        ].join(":")
      },
      *cmd,
      chdir: Rails.root.to_s
    )

    unless ok
      status = $?.respond_to?(:exitstatus) ? $?.exitstatus : "unknown"
      raise PushError, "Staging listings push failed (exit #{status})"
    end

    true
  end

  private

  def script_path
    Rails.root.join("scripts/push_bok_listings_to_staging.sh")
  end
end
