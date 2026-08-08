#!/usr/bin/env bash
# One-shot enhance pass against staging (ONLY_NEEDED). Used by systemd timer.
#
# Defaults match the daytime LAN GPU pool. Override via environment before
# invoking, or via Environment= in gallery-enhance-staging.service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG="${GALLERY_ENHANCE_LOG:-$ROOT/tmp/gallery_enhance_staging_timer.log}"
mkdir -p "$(dirname "$LOG")"

export GALLERY_ENHANCE="${GALLERY_ENHANCE:-1}"
export GALLERY_ENHANCE_ESRGAN="${GALLERY_ENHANCE_ESRGAN:-1}"
export ESRGAN_SCHEDULE="${ESRGAN_SCHEDULE:-speed}"
export ESRGAN_SLOTS="${ESRGAN_SLOTS:-bosgame:0,zephyrus:1,zephyrus:0,gpdwin:0,ayaneo:0,jays-mbp:0}"
slot_n="$(echo "$ESRGAN_SLOTS" | tr ',' '\n' | grep -c .)"
export CONCURRENT_PROPERTIES="${CONCURRENT_PROPERTIES:-$slot_n}"
export GALLERY_PREP_CONCURRENCY="${GALLERY_PREP_CONCURRENCY:-24}"
export GALLERY_UPLOAD_CONCURRENCY="${GALLERY_UPLOAD_CONCURRENCY:-6}"
export RAILS_MAX_THREADS="${RAILS_MAX_THREADS:-64}"
export INLINE=1
export ONLY_NEEDED="${ONLY_NEEDED:-1}"
unset FORCE || true

{
  printf '\n===== GALLERY ENHANCE TIMER %s — workers=%s prep=%s upload=%s schedule=%s slots=%s =====\n' \
    "$(date -Is)" "$CONCURRENT_PROPERTIES" "$GALLERY_PREP_CONCURRENCY" \
    "$GALLERY_UPLOAD_CONCURRENCY" "$ESRGAN_SCHEDULE" "$ESRGAN_SLOTS"
} >>"$LOG"

# flock lives inside gallery_backfill_staging.sh when GALLERY_ENHANCE=1
exec scripts/gallery_backfill_staging.sh >>"$LOG" 2>&1
