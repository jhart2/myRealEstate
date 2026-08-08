#!/usr/bin/env bash
# Boot local Rails against staging Cloud SQL + staging GCS Active Storage.
#
# Usage:
#   scripts/dev_against_staging.sh              # starts bin/dev
#   scripts/dev_against_staging.sh bin/rails c  # any command
#   scripts/dev_against_staging.sh --env-only   # print exports, do not exec
#
# Requires: gcloud auth, cloud-sql-proxy, ADC for GCS
#   gcloud auth login
#   gcloud auth application-default login
#
# WARNING: This uses the live staging database. Local writes mutate staging.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Prefer project Ruby (mise) so gems match Gemfile.lock / vendor/bundle.
PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/share/google-cloud-sdk/bin:/opt/homebrew/bin:${HOME}/.local/bin:${PATH}"
if command -v mise >/dev/null 2>&1; then
  eval "$(cd "$ROOT" && mise activate bash)" 2>/dev/null || true
fi

PROJECT_ID="${STAGING_GCP_PROJECT:-tt-realty-staging}"
CONNECTION_NAME="${STAGING_CLOUDSQL_CONNECTION:-tt-realty-staging:us-east1:tt-realty-stg-db}"
SECRET_NAME="${STAGING_DATABASE_URL_SECRET:-database-url}"
PROXY_PORT="${STAGING_SQL_PROXY_PORT:-5433}"
PROXY_BIN="${CLOUD_SQL_PROXY_BIN:-}"
GCS_BUCKET="${GCS_BUCKET:-tt-realty-staging-activestorage}"

if [[ -z "$PROXY_BIN" ]]; then
  if command -v cloud-sql-proxy >/dev/null 2>&1; then
    PROXY_BIN="$(command -v cloud-sql-proxy)"
  elif [[ -x "$HOME/.local/bin/cloud-sql-proxy" ]]; then
    PROXY_BIN="$HOME/.local/bin/cloud-sql-proxy"
  else
    echo "cloud-sql-proxy not found. Install: brew install cloud-sql-proxy" >&2
    exit 1
  fi
fi

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

ENV_ONLY=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--env-only" ]]; then
    ENV_ONLY=1
  else
    ARGS+=("$arg")
  fi
done

start_proxy

echo "Fetching staging DATABASE_URL secret…"
RAW_URL="$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID")"
TCP_URL="$(rewrite_database_url "$RAW_URL")"
unset RAW_URL

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "WARNING: Application Default Credentials missing — GCS images will fail." >&2
  echo "  Run: gcloud auth application-default login" >&2
fi

export DATABASE_URL="$TCP_URL"
export ACTIVE_STORAGE_SERVICE=google
export GCS_PROJECT="$PROJECT_ID"
export GCS_BUCKET="$GCS_BUCKET"
export GALLERY_DISPLAY_MODE="${GALLERY_DISPLAY_MODE:-enhanced_or_cdn}"
# Keep BOK sync from pushing again while you're already on staging.
export BOK_SYNC_PUSH_STAGING="${BOK_SYNC_PUSH_STAGING:-0}"

echo ""
echo "════════════════════════════════════════════════════════"
echo "  LOCAL → STAGING (writes hit live staging Postgres)"
echo "  DB proxy: 127.0.0.1:${PROXY_PORT}"
echo "  Storage:  gs://${GCS_BUCKET}"
echo "  Gallery:  GALLERY_DISPLAY_MODE=${GALLERY_DISPLAY_MODE}"
echo "════════════════════════════════════════════════════════"
echo ""

if [[ "$ENV_ONLY" -eq 1 ]]; then
  cat <<EOF
export DATABASE_URL=$(printf '%q' "$DATABASE_URL")
export ACTIVE_STORAGE_SERVICE=google
export GCS_PROJECT=$(printf '%q' "$GCS_PROJECT")
export GCS_BUCKET=$(printf '%q' "$GCS_BUCKET")
export GALLERY_DISPLAY_MODE=$(printf '%q' "$GALLERY_DISPLAY_MODE")
export BOK_SYNC_PUSH_STAGING=$(printf '%q' "$BOK_SYNC_PUSH_STAGING")
EOF
  exit 0
fi

cd "$ROOT"
run_cmd() {
  if command -v mise >/dev/null 2>&1; then
    exec mise exec -- "$@"
  fi
  exec "$@"
}

if [[ ${#ARGS[@]} -eq 0 ]]; then
  run_cmd bin/dev
else
  run_cmd "${ARGS[@]}"
fi
