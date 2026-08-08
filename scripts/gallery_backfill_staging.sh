#!/usr/bin/env bash
# Inline gallery ingest against staging Cloud SQL, uploading blobs to GCS.
#
# Usage:
#   scripts/gallery_backfill_staging.sh
#   LIMIT=5 scripts/gallery_backfill_staging.sh
#   BOK_ID=BOK-123 FORCE=1 scripts/gallery_backfill_staging.sh
#
# Requires: gcloud auth, cloud-sql-proxy, ADC with storage.objectAdmin on the bucket.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# One enhance/backfill process at a time (timer + manual restart share this lock).
if [[ "${GALLERY_ENHANCE:-0}" =~ ^(1|true|yes)$ && "${GALLERY_ENHANCE_LOCKED:-}" != "1" ]]; then
  LOCK="${GALLERY_ENHANCE_LOCK:-/tmp/gallery-enhance-staging.lock}"
  export GALLERY_ENHANCE_LOCKED=1
  if ! flock -n "$LOCK" "$0" "$@"; then
    echo "$(date -Is) gallery backfill skipped — another enhance holds $LOCK" >&2
    exit 0
  fi
  exit $?
fi

PROJECT_ID="${STAGING_GCP_PROJECT:-tt-realty-staging}"
CONNECTION_NAME="${STAGING_CLOUDSQL_CONNECTION:-tt-realty-staging:us-east1:tt-realty-stg-db}"
SECRET_NAME="${STAGING_DATABASE_URL_SECRET:-database-url}"
PROXY_PORT="${STAGING_SQL_PROXY_PORT:-5433}"
PROXY_BIN="${CLOUD_SQL_PROXY_BIN:-$HOME/.local/bin/cloud-sql-proxy}"
GCS_BUCKET="${GCS_BUCKET:-tt-realty-staging-activestorage}"
PATH="${HOME}/.local/share/google-cloud-sdk/bin:${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${PATH}"

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

start_proxy

echo "Fetching staging DATABASE_URL secret…"
RAW_URL="$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID")"
TCP_URL="$(rewrite_database_url "$RAW_URL")"
unset RAW_URL

echo "Gallery staging backfill → Cloud SQL + gs://${GCS_BUCKET} (INLINE=1, GALLERY_ENHANCE=${GALLERY_ENHANCE:-0})…"
cd "$ROOT"
# Pass through LIMIT / BOK_ID / FORCE / ONLY_NEEDED / CONCURRENT_PROPERTIES / ESRGAN_* from caller.
env \
  RAILS_ENV=production \
  DATABASE_URL="$TCP_URL" \
  SECRET_KEY_BASE="${SECRET_KEY_BASE:-staging-gallery-$(printf 'x%.0s' {1..48})}" \
  ACTIVE_STORAGE_SERVICE=google \
  GCS_PROJECT="$PROJECT_ID" \
  GCS_BUCKET="$GCS_BUCKET" \
  GALLERY_ENHANCE="${GALLERY_ENHANCE:-0}" \
  GALLERY_ENHANCE_ESRGAN="${GALLERY_ENHANCE_ESRGAN:-0}" \
  GALLERY_ENHANCE_CONCURRENCY="${GALLERY_ENHANCE_CONCURRENCY:-}" \
  GALLERY_PREP_CONCURRENCY="${GALLERY_PREP_CONCURRENCY:-}" \
  GALLERY_UPLOAD_CONCURRENCY="${GALLERY_UPLOAD_CONCURRENCY:-}" \
  CONCURRENT_PROPERTIES="${CONCURRENT_PROPERTIES:-}" \
  ESRGAN_SLOTS="${ESRGAN_SLOTS:-}" \
  RAILS_MAX_THREADS="${RAILS_MAX_THREADS:-24}" \
  INLINE=1 \
  bin/rails gallery:backfill
