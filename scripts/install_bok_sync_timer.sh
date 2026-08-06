#!/usr/bin/env bash
# Install the hourly BOK sync as a systemd --user timer (runs while this machine is on).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_SRC="$ROOT/config/systemd/bok-listings-sync.service"
TIMER_SRC="$ROOT/config/systemd/bok-listings-sync.timer"

# systemd needs spaces in paths escaped as \x20 for ExecStart argv[0].
ROOT_ESC="${ROOT// /\\x20}"

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/bok-listings-sync.service" <<EOF
[Unit]
Description=TT Realty BOK listings sync — scrape, import, and staging DB push
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$ROOT
Environment=RAILS_ENV=development
Environment=BOK_SYNC_DAYS=7
Environment=BOK_SYNC_MAX_DETAILS=250
Environment=BOK_SYNC_DELAY=4
Environment=BOK_SYNC_SKIP_SEARCH=1
Environment=BOK_SYNC_PUSH_STAGING=1
Environment=STAGING_GCP_PROJECT=tt-realty-staging
Environment=STAGING_CLOUDSQL_CONNECTION=tt-realty-staging:us-east1:tt-realty-stg-db
Environment=STAGING_SQL_PROXY_PORT=5433
Environment=PATH=$HOME/.local/share/google-cloud-sdk/bin:$HOME/.local/share/mise/shims:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
ExecStart=${ROOT_ESC}/bin/rails bok:sync
Nice=10
TimeoutStartSec=3h

[Install]
WantedBy=default.target
EOF

cp "$TIMER_SRC" "$UNIT_DIR/bok-listings-sync.timer"

systemctl --user daemon-reload
systemctl --user enable --now bok-listings-sync.timer

# Allow the timer to run without an interactive login while the machine is powered on.
if command -v loginctl >/dev/null 2>&1; then
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
    echo "Enabling systemd linger for $USER (so the timer runs without a GUI login)…"
    loginctl enable-linger "$USER"
  fi
fi

echo
systemctl --user status bok-listings-sync.timer --no-pager || true
echo
systemctl --user list-timers bok-listings-sync.timer --no-pager || true
echo
echo "Installed. Manual run: systemctl --user start bok-listings-sync.service"
echo "Logs:           journalctl --user -u bok-listings-sync.service -f"
echo "Disable:        systemctl --user disable --now bok-listings-sync.timer"
