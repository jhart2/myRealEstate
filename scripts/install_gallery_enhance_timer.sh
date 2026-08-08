#!/usr/bin/env bash
# Install/refresh the staging gallery enhance timer (systemd --user).
# Copies unit files from config/systemd. Does NOT kill a live enhance run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_SRC="$ROOT/config/systemd/gallery-enhance-staging.service"
TIMER_SRC="$ROOT/config/systemd/gallery-enhance-staging.timer"
ROOT_ESC="${ROOT// /\\x20}"

mkdir -p "$UNIT_DIR"

if [[ ! -f "$SERVICE_SRC" || ! -f "$TIMER_SRC" ]]; then
  echo "Missing unit sources under $ROOT/config/systemd" >&2
  exit 1
fi

STATE="$(systemctl --user is-active gallery-enhance-staging.service 2>/dev/null || true)"
if [[ "$STATE" == "activating" || "$STATE" == "active" ]]; then
  echo "NOTE: gallery-enhance-staging.service is currently ${STATE}."
  echo "      Unit files will update for the *next* run; this install will not kill it."
fi

if pgrep -f 'bin/rails gallery:backfill' >/dev/null 2>&1; then
  echo "NOTE: a gallery:backfill process is already running (likely catch-up)."
  echo "      Timer installs armed, but flock will skip until that process exits."
fi

python3 - "$SERVICE_SRC" "$UNIT_DIR/gallery-enhance-staging.service" "$ROOT" "$ROOT_ESC" "$HOME" <<'PY'
import pathlib, re, sys

src, dst, root, root_esc, home = sys.argv[1:6]
text = pathlib.Path(src).read_text()

def repl_line(pattern: str, line: str) -> None:
    global text
    if re.search(pattern, text, flags=re.M):
        text = re.sub(pattern, lambda _m: line, text, count=1, flags=re.M)
    else:
        raise SystemExit(f"missing required line matching {pattern}")

repl_line(r"(?m)^WorkingDirectory=.*$", f"WorkingDirectory={root}")
repl_line(r"(?m)^EnvironmentFile=.*$", f"EnvironmentFile=-{root_esc}/.env")
repl_line(
    r"(?m)^ExecStart=.*$",
    f"ExecStart={root_esc}/scripts/gallery_enhance_staging_once.sh",
)
repl_line(r"(?m)^Environment=HOME=.*$", f"Environment=HOME={home}")
path = (
    f"{home}/.local/share/google-cloud-sdk/bin:"
    f"{home}/.local/share/mise/shims:"
    f"{home}/.local/bin:/usr/local/bin:/usr/bin:/bin"
)
repl_line(r"(?m)^Environment=PATH=.*$", f"Environment=PATH={path}")

pathlib.Path(dst).write_text(text)
print(f"Wrote {dst}")
PY

cp "$TIMER_SRC" "$UNIT_DIR/gallery-enhance-staging.timer"
chmod +x "$ROOT/scripts/gallery_enhance_staging_once.sh"

systemctl --user daemon-reload
systemctl --user enable --now gallery-enhance-staging.timer
systemctl --user reset-failed gallery-enhance-staging.service 2>/dev/null || true

if command -v loginctl >/dev/null 2>&1; then
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
    echo "Enabling systemd linger for $USER…"
    loginctl enable-linger "$USER"
  fi
fi

echo
systemctl --user status gallery-enhance-staging.timer --no-pager || true
echo
systemctl --user list-timers gallery-enhance-staging.timer --no-pager || true
echo
echo "Manual run: systemctl --user start gallery-enhance-staging.service"
echo "Logs:       journalctl --user -u gallery-enhance-staging.service -f"
echo "            tail -f $ROOT/tmp/gallery_enhance_staging_timer.log"
echo "Disable:    systemctl --user disable --now gallery-enhance-staging.timer"
