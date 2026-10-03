#!/bin/bash
# Focus the Omaflow window, or start one that is not part of the bar.
# The chip must not summon Standalone.qml inside the shell: that window
# shares the bar's scale and dies on `omarchy restart shell`.
set -euo pipefail

status=$(python3 - << 'PY'
import json, os, subprocess

def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            return handle.read().replace(b"\x00", b" ").decode("utf-8", "replace")
    except OSError:
        return ""

def is_app(cmd):
    return (
        "quickshell" in cmd
        and "OmaflowApp.qml" in cmd
        and "/usr/share/omarchy/shell" not in cmd
    )

running = False
for name in os.listdir("/proc"):
    if name.isdigit() and is_app(cmdline(int(name))):
        running = True
        break

try:
    clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True))
except Exception:
    clients = []

for client in clients:
    pid = client.get("pid")
    if not pid or not is_app(cmdline(pid)):
        continue
    addr = str(client.get("address") or "")
    if not addr:
        continue
    result = subprocess.run(
        ["hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{addr}" }})'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        print("focused")
        raise SystemExit
print("running" if running else "absent")
PY
)

if [[ "$status" == "focused" || "$status" == "running" ]]; then
  exit 0
fi

desk="${XDG_DATA_HOME:-$HOME/.local/share}/applications/omaflow-standalone.desktop"
if [[ -f "$desk" ]] && gtk-launch omaflow-standalone; then
  exit 0
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$root/scripts/qml_imports.sh"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
export QML_IMPORT_PATH="$(qml_import_path)${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
launcher="$root/app/omaflow-standalone"
# setsid -f leaves the window in its own session, so closing the bar does not close it.
if [[ -x "$launcher" ]]; then
  setsid -f "$launcher" </dev/null >/dev/null 2>&1
else
  setsid -f quickshell -n -p "$root/OmaflowApp.qml" </dev/null >/dev/null 2>&1
fi
