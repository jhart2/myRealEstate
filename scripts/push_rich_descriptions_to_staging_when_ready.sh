#!/usr/bin/env bash
# Wait for rich HTML local apply to finish, then overlay descriptions onto staging.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
eval "$(mise activate bash)"
export PATH="${HOME}/google-cloud-sdk/bin:${HOME}/.local/share/google-cloud-sdk/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${PATH}"

APPLY_LOG="${APPLY_LOG:-tmp/listing_copy_rich_html_apply_all.log}"
SUMMARY="${SUMMARY:-tmp/listing_copy_rich_html_apply_all.summary.log}"
EXPORT_JSON="${EXPORT_JSON:-tmp/local_descriptions_for_staging.json}"
PROJECT_ID="${STAGING_GCP_PROJECT:-tt-realty-staging}"
SECRET_NAME="${STAGING_DATABASE_URL_SECRET:-database-url}"
PROXY_PORT="${STAGING_SQL_PROXY_PORT:-5433}"
CONNECTION_NAME="${STAGING_CLOUDSQL_CONNECTION:-tt-realty-staging:us-east1:tt-realty-stg-db}"
PROXY_BIN="${CLOUD_SQL_PROXY_BIN:-$HOME/.local/bin/cloud-sql-proxy}"

echo "Waiting for rich HTML apply to finish…"
while true; do
  if grep -q '^Done\. applied=' "$APPLY_LOG" 2>/dev/null; then
    echo "Apply finished:"
    grep '^Done\. applied=' "$APPLY_LOG" | tail -1
    break
  fi
  if ! pgrep -f 'listing_copy:rich_html' >/dev/null 2>&1; then
    if grep -q '^Done\. applied=' "$APPLY_LOG" 2>/dev/null; then
      grep '^Done\. applied=' "$APPLY_LOG" | tail -1
      break
    fi
    echo "Apply process gone but no Done line — aborting" >&2
    tail -n 40 "$APPLY_LOG" >&2 || true
    exit 1
  fi
  # progress breadcrumbs
  grep -E '^\[|checkpoint' "$APPLY_LOG" 2>/dev/null | tail -1 || true
  sleep 30
done

echo "Exporting local description_html…"
bin/rails runner '
path = Rails.root.join("'"$EXPORT_JSON"'")
rows = Property.where.not(bok_id: [nil, ""]).find_each.filter_map { |p|
  html = p.description_html.to_s
  next if html.blank?
  next unless html.match?(/<h2\b/i)
  { "bok_id" => p.bok_id, "description_html" => html }
}
File.write(path, JSON.generate(rows))
puts "Exported #{rows.size} rich descriptions → #{path}"
'

proxy_running() {
  ss -ltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q LISTEN \
    || (command -v lsof >/dev/null && lsof -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1)
}

if ! proxy_running; then
  echo "Starting Cloud SQL Auth Proxy on 127.0.0.1:${PROXY_PORT}…"
  command -v cloud-sql-proxy >/dev/null 2>&1 && PROXY_BIN="$(command -v cloud-sql-proxy)"
  nohup "$PROXY_BIN" --gcloud-auth --address 127.0.0.1 --port "$PROXY_PORT" "$CONNECTION_NAME" \
    >tmp/cloud-sql-proxy-staging.log 2>&1 &
  echo $! >tmp/cloud-sql-proxy-staging.pid
  for _ in $(seq 1 40); do
    proxy_running && break
    sleep 0.25
  done
  proxy_running || { echo "Proxy failed"; tail -n 40 tmp/cloud-sql-proxy-staging.log; exit 1; }
fi

rewrite_database_url() {
  local raw_url="$1"
  STAGING_SQL_PROXY_PORT="$PROXY_PORT" python3 - "$raw_url" <<'PY'
import os, sys
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
raw = sys.argv[1].strip()
port = os.environ.get("STAGING_SQL_PROXY_PORT", "5433")
parts = urlsplit(raw)
qs = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k.lower() != "host"]
netloc = parts.netloc
if "@" in netloc:
    auth, _host = netloc.rsplit("@", 1)
    netloc = f"{auth}@127.0.0.1:{port}"
else:
    netloc = f"127.0.0.1:{port}"
print(urlunsplit((parts.scheme, netloc, parts.path, urlencode(qs), parts.fragment)))
PY
}

echo "Fetching staging DATABASE_URL…"
RAW_URL="$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID")"
TCP_URL="$(rewrite_database_url "$RAW_URL")"
unset RAW_URL

echo "Overlaying descriptions onto staging…"
env -u BOK_SYNC_PUSH_STAGING \
  RAILS_ENV=production \
  DATABASE_URL="$TCP_URL" \
  SECRET_KEY_BASE="${SECRET_KEY_BASE:-staging-push-$(printf 'x%.0s' {1..48})}" \
  BOK_SYNC_PUSH_STAGING=0 \
  bin/rails runner tmp/overlay_descriptions_on_staging.rb \
  | tee tmp/overlay_descriptions_on_staging.log

echo "Staging description overlay complete."
