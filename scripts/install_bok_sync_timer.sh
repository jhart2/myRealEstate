#!/usr/bin/env bash
# Install/refresh the hourly BOK sync as a systemd --user timer.
# Copies unit files from config/systemd so reconciliation flags stay in sync.
#
# SAFE WHILE A RUN IS IN PROGRESS: this script only rewrites unit files and
# daemon-reloads. It does NOT stop/kill bok-listings-sync.service. A live run
# keeps its old process env until it finishes; the next start picks up changes.
#
# Never pair this with `systemctl --user stop/kill` unless you intentionally
# abort a sync (use scripts/stop_bok_sync.sh). Stopping mid-import often lands
# as SignalException inside ListingAddressBrain/OpenAI and looks like an AI fault.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_SRC="$ROOT/config/systemd/bok-listings-sync.service"
TIMER_SRC="$ROOT/config/systemd/bok-listings-sync.timer"

# systemd needs spaces in paths escaped as \x20 for ExecStart argv[0].
ROOT_ESC="${ROOT// /\\x20}"

mkdir -p "$UNIT_DIR"

if [[ ! -f "$SERVICE_SRC" || ! -f "$TIMER_SRC" ]]; then
  echo "Missing unit sources under $ROOT/config/systemd" >&2
  exit 1
fi

SYNC_STATE="$(systemctl --user is-active bok-listings-sync.service 2>/dev/null || true)"
if [[ "$SYNC_STATE" == "activating" || "$SYNC_STATE" == "active" ]]; then
  echo "NOTE: bok-listings-sync.service is currently ${SYNC_STATE}."
  echo "      Unit files will update for the *next* run; this install will not kill the live sync."
  echo "      To abort intentionally: CONFIRM=1 $ROOT/scripts/stop_bok_sync.sh"
fi

# Rewrite WorkingDirectory / EnvironmentFile / ExecStart / HOME / PATH for this machine.
python3 - "$SERVICE_SRC" "$UNIT_DIR/bok-listings-sync.service" "$ROOT" "$ROOT_ESC" "$HOME" <<'PY'
import pathlib, re, sys

src, dst, root, root_esc, home = sys.argv[1:6]
text = pathlib.Path(src).read_text()

def repl_line(pattern: str, line: str) -> None:
    global text
    if re.search(pattern, text, flags=re.M):
        text = re.sub(pattern, lambda _m: line, text, count=1, flags=re.M)
    else:
        text = re.sub(r"(?m)^(Environment=PATH=)", lambda m: line + "\n" + m.group(1), text, count=1)

repl_line(r"(?m)^WorkingDirectory=.*$", f"WorkingDirectory={root}")
repl_line(r"(?m)^EnvironmentFile=.*$", f"EnvironmentFile=-{root_esc}/.env")
repl_line(r"(?m)^ExecStart=.*$", f"ExecStart={root_esc}/bin/rails bok:sync")
repl_line(r"(?m)^Environment=HOME=.*$", f"Environment=HOME={home}")
path = (
    f"{home}/.local/share/google-cloud-sdk/bin:"
    f"{home}/.local/share/mise/shims:"
    f"{home}/.local/bin:/usr/local/bin:/usr/bin:/bin"
)
repl_line(r"(?m)^Environment=PATH=.*$", f"Environment=PATH={path}")

required = {
    "BOK_APPLY_LISTING_COPY": "1",
    "BOK_ADDRESS_BRAIN": "1",
    "ADDRESS_BRAIN_BATCH": "12",
    "BOK_COORD_RECONCILE": "1",
    "BOK_COORD_RECONCILE_SOURCES": "deep",
    "BOK_COORD_RECONCILE_CITY_ONLY": "1",
    "BOK_COORD_RECONCILE_RESIDUAL": "20",
    "BOK_OFFER_RECONCILE": "1",
}
for key, value in required.items():
    repl_line(rf"(?m)^Environment={re.escape(key)}=.*$", f"Environment={key}={value}")

pathlib.Path(dst).write_text(text)
print(f"Wrote {dst}")
PY

cp "$TIMER_SRC" "$UNIT_DIR/bok-listings-sync.timer"

systemctl --user daemon-reload
systemctl --user enable --now bok-listings-sync.timer
systemctl --user reset-failed bok-listings-sync.service 2>/dev/null || true

# Allow the timer to run without an interactive login while the machine is powered on.
if command -v loginctl >/dev/null 2>&1; then
  if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
    echo "Enabling systemd linger for $USER (so the timer runs without a GUI login)…"
    loginctl enable-linger "$USER"
  fi
fi

echo
echo "Installed sync unit with:"
grep -E 'Environment=(BOK_|ADDRESS_)' "$UNIT_DIR/bok-listings-sync.service" || true
echo
systemctl --user status bok-listings-sync.timer --no-pager || true
echo
systemctl --user list-timers bok-listings-sync.timer --no-pager || true
echo
echo "Manual run: systemctl --user start bok-listings-sync.service"
echo "Logs:       journalctl --user -u bok-listings-sync.service -f"
echo "Disable:    systemctl --user disable --now bok-listings-sync.timer"
