#!/bin/bash
# Focus the Omaflow window, or start one that is not part of the bar.
# The chip must not summon Standalone.qml inside the shell: that window
# shares the bar's scale and dies on `omarchy restart shell`.
set -euo pipefail

status=$(python3 - << 'PY'
import json, os, signal, subprocess, time

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

pids = []
for name in os.listdir("/proc"):
    if name.isdigit() and is_app(cmdline(int(name))):
        pids.append(int(name))

clients_ok = False
clients = []
try:
    parsed = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True))
    if isinstance(parsed, list):
        clients = parsed
        clients_ok = True
except Exception:
    clients_ok = False

# A failed client list must not be treated as "no window", or a mapped
# Omaflow gets signaled and a second copy starts.
if not clients_ok:
    print("unknown" if pids else "absent")
    raise SystemExit

mapped = []
for client in clients:
    pid = client.get("pid")
    if not pid or not is_app(cmdline(int(pid))):
        continue
    addr = str(client.get("address") or "")
    if not addr:
        continue
    mapped.append(int(pid))
    result = subprocess.run(
        ["hyprctl", "dispatch", f'hl.dsp.focus({{ window = "address:{addr}" }})'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        print("focused")
        raise SystemExit

if mapped:
    print("mapped")
    raise SystemExit

# A windowless OmaflowApp makes `quickshell -n` exit and leaves nothing to
# focus. Stop it before any launch path, including the raw quickshell fallback.
# The shell process is excluded by is_app. A listed window is not signaled.
for pid in pids:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
deadline = time.time() + 2
while time.time() < deadline and any(os.path.exists(f"/proc/{pid}") for pid in pids):
    time.sleep(0.05)
for pid in pids:
    if os.path.exists(f"/proc/{pid}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
print("running" if pids else "absent")
PY
)

# "running" has no window. Fall through so the launcher can replace it.
# Treating that as success is why the chip did nothing after Escape.
if [[ "$status" == "focused" || "$status" == "mapped" || "$status" == "unknown" ]]; then
  exit 0
fi

# The installed window lives in ~/.local. The plugin checkout is only the chip.
installed="${HOME}/.local/bin/omaflow"
if [[ -x "$installed" ]]; then
  setsid -f "$installed" </dev/null >/dev/null 2>&1
  exit 0
fi

# gtk-launch waits on StartupNotify, and StartupWMClass=org.quickshell is
# the bar. From the chip that focuses the shell and never starts Omaflow.
desk="${XDG_DATA_HOME:-$HOME/.local/share}/applications/omaflow-standalone.desktop"
if [[ -f "$desk" ]]; then
  exec_line=$(sed -n 's/^Exec=//p' "$desk" | head -n 1)
  if [[ -n "$exec_line" && -x "$exec_line" ]]; then
    setsid -f "$exec_line" </dev/null >/dev/null 2>&1
    exit 0
  fi
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck disable=SC1091
source "$root/scripts/qml_imports.sh"
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
export QML_IMPORT_PATH="$(qml_import_path)${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
export QS_APP_ID="${QS_APP_ID:-omaflow-standalone}"
launcher="$root/app/omaflow-standalone"
# setsid -f leaves the window in its own session, so closing the bar does not close it.
if [[ -x "$launcher" ]]; then
  setsid -f "$launcher" </dev/null >/dev/null 2>&1
else
  setsid -f quickshell -n -p "$root/qml/OmaflowApp.qml" </dev/null >/dev/null 2>&1
fi
