#!/bin/bash
# Publish the window launcher from the enabled plugin checkout.
# `omarchy plugin add` never runs ./install. The chip does, the first time
# it loads, and again when that checkout moves to a new commit.
# A source tree and the copy under ~/.local leave this script immediately.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
config="${XDG_CONFIG_HOME:-$HOME/.config}"
config="${config%/}"
plugin="$config/omarchy/plugins/tempest-chaoscreator.omaflow"
[[ "$root" == "$plugin" ]] || exit 0

bin="${HOME}/.local/bin/omaflow"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
share="$data/omaflow"
stamp="$share/.omaflow-source"

current=""
if current=$(git -C "$root" rev-parse HEAD 2>/dev/null); then
  :
else
  current=""
fi

same() {
  [[ -x "$bin" && -x "$share/app/omaflow-standalone" ]] || return 1
  if [[ -z "$current" ]]; then
    return 0
  fi
  [[ -f "$stamp" && "$(<"$stamp")" == "$current" ]]
}

same && exit 0

lock_dir="${XDG_RUNTIME_DIR:-$config/omaflow}"
mkdir -p "$lock_dir"
exec 9>"$lock_dir/omaflow-window-install.lock"
flock -w 60 9
same && exit 0
exec "$root/install"
