#!/usr/bin/env python3
"""Show or hide the Omaflow bar chip.

status prints whether the chip is enabled.
enable installs https://github.com/tempest-chaoscreator/omaflow when the
plugin directory is missing, and otherwise only asks Omarchy to show it.
An install from the previous major version is left in place and reported
as an error, so this switch does not replace that directory.
disable takes the chip off the bar and leaves the files in place.

This does not install coolercontrold, does not enable it, and does not run as root.
The chip has its own Install and Start buttons.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

PLUGIN_ID = "tempest-chaoscreator.omaflow"
REPO = "https://github.com/tempest-chaoscreator/omaflow.git"
DEST = Path.home() / ".config" / "omarchy" / "plugins" / PLUGIN_ID


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
    except (OSError, subprocess.TimeoutExpired):
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


def installed_version() -> str:
    manifest = DEST / "manifest.json"
    if not manifest.is_file():
        return ""
    try:
        return str(json.loads(manifest.read_text()).get("version") or "")
    except (OSError, json.JSONDecodeError):
        return ""


def plugin_state() -> dict:
    enabled = False
    for row in plugin_rows():
        if isinstance(row, dict) and row.get("id") == PLUGIN_ID:
            enabled = row.get("enabled") is True
            break
    return {"ok": True, "enabled": enabled, "version": installed_version()}


def omarchy(action: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["omarchy", "plugin", action, PLUGIN_ID],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )


def fail_state(detail: str, fallback: str = "could not enable the plugin", state: dict | None = None) -> dict:
    current = plugin_state() if state is None else state
    current["ok"] = False
    current["error"] = (detail or fallback).splitlines()[-1][:180]
    return current


def settle(result: subprocess.CompletedProcess[str], fallback: str, enabled: bool) -> dict:
    state = plugin_state()
    if result.returncode == 0 and state.get("enabled") is enabled:
        return state
    detail = (result.stderr or result.stdout or fallback).strip()
    return fail_state(detail, fallback, state)


def enable() -> dict:
    version = installed_version()
    if version.startswith("1."):
        return fail_state("An older Omaflow plugin is installed. Remove it, then turn this on again.")
    if not version:
        result = subprocess.run(
            ["omarchy", "plugin", "add", REPO, "--enable", "--yes"],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
        return settle(result, "could not install the plugin", True)
    return settle(omarchy("enable"), "could not enable the plugin", True)


def disable() -> dict:
    return settle(omarchy("disable"), "could not disable the plugin", False)


def main() -> int:
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    actions = {"status": plugin_state, "enable": enable, "disable": disable}
    fn = actions.get(action)
    if fn is None:
        emit({"ok": False, "enabled": False, "error": "unknown action"})
        return 1
    emit(fn())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
