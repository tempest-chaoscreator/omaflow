# Quickshell modules for the standalone window.
# The links stay in the cache. A symlink inside the plugin directory fails
# `omarchy plugin validate`, and `omarchy plugin update` runs that check
# after it fast-forwards.
qml_import_path() {
  local root="${OMARCHY_PATH:-/usr/share/omarchy}"
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/omaflow/qml"
  mkdir -p "$cache/qs"
  ln -sfn "$root/shell/Commons" "$cache/qs/Commons"
  ln -sfn "$root/shell/Ui" "$cache/qs/Ui"
  printf '%s\n' "$cache"
}
