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
require "open3"

class StagingListingsPusher
  class PushError < StandardError; end

  GCLOUD_BIN = "#{Dir.home}/.local/share/google-cloud-sdk/bin".freeze
  MISE_BIN = "#{Dir.home}/.local/share/mise/shims".freeze
  LOCAL_BIN = "#{Dir.home}/.local/bin".freeze

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
    json = safe_json_path!
    script = script_path
    raise PushError, "Missing push script at #{script}" unless script.exist?

    Rails.logger.info("[StagingListingsPusher] bash #{script} #{json}")

    _out, status = Open3.capture2e(
      path_env,
      "bash",
      script.to_s,
      json.to_s,
      chdir: Rails.root.to_s
    )

    unless status.success?
      raise PushError, "Staging listings push failed (exit #{status.exitstatus})"
    end

    true
  end

  private

  def script_path
    Rails.root.join("scripts/push_bok_listings_to_staging.sh")
  end

  # Only allow JSON under the app tree so the shell argv cannot escape the repo.
  def safe_json_path!
    json = @json_path.expand_path
    raise PushError, "JSON not found: #{json}" unless json.exist?

    root = Rails.root.expand_path.to_s
    unless json.to_s.start_with?("#{root}/") || json.to_s.start_with?("#{root}\\")
      raise PushError, "JSON path must be inside the application root"
    end

    json
  end

  def path_env
    {
      "PATH" => [ GCLOUD_BIN, MISE_BIN, LOCAL_BIN, ENV.fetch("PATH", "/usr/bin:/bin") ].join(":")
    }
  end
end
