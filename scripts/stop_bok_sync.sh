#!/usr/bin/env bash
# Intentionally abort the user-systemd BOK sync oneshot.
#
# Requires CONFIRM=1 so a casual stop/kill during "reinstall units" or debugging
# does not silently truncate import + address-brain mid OpenAI call.
set -euo pipefail

if [[ "${CONFIRM:-}" != "1" ]]; then
  echo "Refusing to stop bok-listings-sync.service without CONFIRM=1." >&2
  echo "A stop mid-import usually surfaces as SignalException in ListingAddressBrain/OpenAI," >&2
  echo "even though the real cause is an external SIGTERM (systemctl stop/kill)." >&2
  echo >&2
  echo "Usage: CONFIRM=1 $0" >&2
  systemctl --user status bok-listings-sync.service --no-pager 2>&1 | head -16 || true
  exit 2
fi

echo "Stopping bok-listings-sync.service (CONFIRM=1)…"
systemctl --user stop bok-listings-sync.service 2>&1 || true
sleep 2
if systemctl --user is-active bok-listings-sync.service 2>/dev/null | grep -Eq 'activating|active'; then
  echo "Still active — sending SIGTERM via systemctl kill…"
  systemctl --user kill -s SIGTERM bok-listings-sync.service 2>&1 || true
  sleep 2
fi
systemctl --user status bok-listings-sync.service --no-pager 2>&1 | head -16 || true
pgrep -af 'bin/rails bok:sync' || echo "no bok:sync process"
