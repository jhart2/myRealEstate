#!/usr/bin/env bash
# Push a BOK listings JSON file into the staging Cloud SQL database.
#
# Usage:
#   scripts/push_bok_listings_to_staging.sh path/to/houses_last_month_….json
#
# Requires: gcloud auth, cloud-sql-proxy, network access to Cloud SQL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JSON_PATH="${1:-}"
PROJECT_ID="${STAGING_GCP_PROJECT:-tt-realty-staging}"
CONNECTION_NAME="${STAGING_CLOUDSQL_CONNECTION:-tt-realty-staging:us-east1:tt-realty-stg-db}"
SECRET_NAME="${STAGING_DATABASE_URL_SECRET:-database-url}"
PROXY_PORT="${STAGING_SQL_PROXY_PORT:-5433}"
PROXY_BIN="${CLOUD_SQL_PROXY_BIN:-$HOME/.local/bin/cloud-sql-proxy}"
PATH="${HOME}/.local/share/google-cloud-sdk/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${PATH}"

if [[ -z "$JSON_PATH" ]]; then
  echo "Usage: $0 path/to/listings.json" >&2
  exit 2
fi
if [[ ! -f "$JSON_PATH" ]]; then
  echo "JSON not found: $JSON_PATH" >&2
  exit 2
fi
if [[ ! -x "$PROXY_BIN" ]] && ! command -v cloud-sql-proxy >/dev/null 2>&1; then
  echo "cloud-sql-proxy not found (expected $PROXY_BIN)" >&2
  exit 1
fi
command -v cloud-sql-proxy >/dev/null 2>&1 && PROXY_BIN="$(command -v cloud-sql-proxy)"

proxy_running() {
  ss -ltn "sport = :${PROXY_PORT}" 2>/dev/null | grep -q LISTEN \
    || (command -v lsof >/dev/null && lsof -iTCP:"$PROXY_PORT" -sTCP:LISTEN >/dev/null 2>&1)
}

start_proxy() {
  if proxy_running; then
    echo "Cloud SQL proxy already listening on :${PROXY_PORT}"
    return 0
  fi

  mkdir -p "$ROOT/tmp"
  local log="$ROOT/tmp/cloud-sql-proxy-staging.log"
  echo "Starting Cloud SQL Auth Proxy on 127.0.0.1:${PROXY_PORT}…"
  nohup "$PROXY_BIN" --gcloud-auth --address 127.0.0.1 --port "$PROXY_PORT" "$CONNECTION_NAME" \
    >"$log" 2>&1 &
  local pid=$!
  echo "$pid" >"$ROOT/tmp/cloud-sql-proxy-staging.pid"

  for _ in $(seq 1 40); do
    if proxy_running; then
      echo "Proxy ready (pid $pid)"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Proxy exited early. Log:" >&2
      tail -n 40 "$log" >&2 || true
      return 1
    fi
    sleep 0.25
  done

  echo "Timed out waiting for proxy on :${PROXY_PORT}" >&2
  tail -n 40 "$log" >&2 || true
  return 1
}

rewrite_database_url() {
  local raw_url="$1"
  STAGING_SQL_PROXY_PORT="$PROXY_PORT" python3 - "$raw_url" <<'PY'
import os, sys
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

raw = sys.argv[1].strip()
port = os.environ.get("STAGING_SQL_PROXY_PORT", "5433")
parts = urlsplit(raw)
# Drop unix-socket host= query used on Cloud Run; talk TCP via local proxy.
qs = [(k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k.lower() != "host"]
netloc = parts.netloc
# Force TCP host/port while preserving user:password.
if "@" in netloc:
    auth, _host = netloc.rsplit("@", 1)
    netloc = f"{auth}@127.0.0.1:{port}"
else:
    netloc = f"127.0.0.1:{port}"
print(urlunsplit((parts.scheme, netloc, parts.path, urlencode(qs), parts.fragment)))
PY
}

start_proxy

echo "Fetching staging DATABASE_URL secret…"
RAW_URL="$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID")"
TCP_URL="$(rewrite_database_url "$RAW_URL")"
unset RAW_URL

echo "Importing $(basename "$JSON_PATH") into staging Postgres…"
cd "$ROOT"
# Isolated Rails boot against staging DB (do not recurse into another staging push).
env -u BOK_SYNC_PUSH_STAGING \
  RAILS_ENV=production \
  DATABASE_URL="$TCP_URL" \
  SECRET_KEY_BASE="${SECRET_KEY_BASE:-staging-push-$(printf 'x%.0s' {1..48})}" \
  BOK_SYNC_PUSH_STAGING=0 \
  bin/rails "bok:import[${JSON_PATH}]"

echo "Staging DB push complete."
