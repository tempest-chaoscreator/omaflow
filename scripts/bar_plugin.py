#!/usr/bin/env python3
"""Show or hide the Omaflow bar chip.

status prints whether the chip is enabled.
enable installs https://github.com/tempest-chaoscreator/omaflow when the
plugin directory is missing, and otherwise only asks Omarchy to show it.
A 1.x install is left in place and reported as an error.
disable takes the chip off the bar and leaves the files in place.

This does not enable coolercontrold, and it does not run as root.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

PLUGIN_ID = "tempest-chaoscreator.omaflow"
REPO = "https://github.com/tempest-chaoscreator/omaflow.git"
DEST = Path.home() / ".config" / "omarchy" / "plugins" / PLUGIN_ID
BACKUP = Path.home() / ".config" / "omaflow" / "plugin-1.3.0"


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def plugin_rows() -> list:
    try:
        out = subprocess.run(
            ["omarchy", "plugin", "list", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        return []
    if out.returncode != 0:
        return []
    try:
        payload = json.loads(out.stdout)
    except json.JSONDecodeError:
        return []
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        rows = payload.get("plugins")
        return rows if isinstance(rows, list) else []
    return []


def plugin_state() -> dict:
    version = ""
    manifest = DEST / "manifest.json"
    if manifest.is_file():
        try:
            version = str(json.loads(manifest.read_text()).get("version") or "")
        except (OSError, json.JSONDecodeError):
            version = ""
    enabled = False
    for row in plugin_rows():
        if isinstance(row, dict) and row.get("id") == PLUGIN_ID:
            enabled = row.get("enabled") is True
            break
    return {"ok": True, "enabled": enabled, "version": version}


def backup_legacy() -> None:
    manifest = DEST / "manifest.json"
    if not manifest.is_file() or BACKUP.exists():
        return
    try:
        version = str(json.loads(manifest.read_text()).get("version") or "")
    except (OSError, json.JSONDecodeError):
        return
    if not version.startswith("1."):
        return
    BACKUP.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(
        DEST,
        BACKUP,
        ignore=shutil.ignore_patterns(".git", "__pycache__", "*.pyc"),
    )


def installed_version() -> str:
    manifest = DEST / "manifest.json"
    if not manifest.is_file():
        return ""
    try:
        return str(json.loads(manifest.read_text()).get("version") or "")
    except (OSError, json.JSONDecodeError):
        return ""


def omarchy(action: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["omarchy", "plugin", action, PLUGIN_ID],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def fail_state(detail: str) -> dict:
    state = plugin_state()
    state["ok"] = False
    state["error"] = (detail or "could not enable the plugin").splitlines()[-1][:180]
    return state


def enable() -> dict:
    version = installed_version()
    if version.startswith("1."):
        backup_legacy()
        return fail_state("Remove the old Omaflow plugin, then add the 0.1 repository")
    if not version:
        result = subprocess.run(
            ["omarchy", "plugin", "add", REPO, "--enable", "--yes"],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
        state = plugin_state()
        if result.returncode != 0 or not state.get("enabled"):
            detail = (result.stderr or result.stdout or "could not install the plugin").strip()
            return fail_state(detail)
        return state
    result = omarchy("enable")
    state = plugin_state()
    if result.returncode != 0 or not state.get("enabled"):
        detail = (result.stderr or result.stdout or "could not enable the plugin").strip()
        return fail_state(detail)
    return state


def disable() -> dict:
    result = omarchy("disable")
    state = plugin_state()
    if result.returncode != 0 or state.get("enabled"):
        detail = (result.stderr or result.stdout or "could not disable the plugin").strip()
        state["ok"] = False
        state["error"] = detail.splitlines()[-1][:180] if detail else "could not disable the plugin"
    return state


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    if action == "status":
        emit(plugin_state())
        return 0
    if action == "enable":
        emit(enable())
        return 0
    if action == "disable":
        emit(disable())
        return 0
    emit({"ok": False, "enabled": False, "error": "unknown action"})
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
