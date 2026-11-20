#!/bin/bash
# Install coolercontrold when the package is missing.
# The configured pacman repositories are used when they have it.
# Until they do, this installs one Arch extra file and checks its signature:
#   coolercontrold-5.1.1-2-x86_64.pkg.tar.zst
# --needed leaves an installed package alone.
# This does not install the CoolerControl desktop package.
# This does not enable or start the service.
set -euo pipefail

url="https://geo.mirror.pkgbuild.com/extra/os/x86_64/coolercontrold-5.1.1-2-x86_64.pkg.tar.zst"

if pacman -Q -- coolercontrold &>/dev/null; then
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Omaflow could not install coolercontrold. Approve the prompt, or run: sudo pacman -U --needed $url" >&2
  exit 1
fi

work=""
cleanup() {
  if [[ -n "$work" ]]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT

die() {
  echo "$1" >&2
  exit 1
}

work=$(mktemp -d /var/tmp/omaflow-coolercontrold.XXXXXX)
chmod 700 "$work"

if pacman -Si -- coolercontrold &>/dev/null; then
  if /usr/share/omarchy/bin/omarchy-pkg-add coolercontrold >"$work/pacman.out" 2>&1; then
    exit 0
  fi
  last=$(tail -n 1 "$work/pacman.out" 2>/dev/null | tr -d '\r')
  die "${last:-Omaflow could not install coolercontrold.}"
fi

# --noconfirm is the button form of the terminal command. pkexec has no
# prompt for pacman's own question. A remote file uses SigLevel = Required,
# so pacman downloads the matching .sig and checks it.
if ! pacman -U --noconfirm --needed -- "$url" >"$work/pacman.out" 2>&1; then
  last=$(tail -n 1 "$work/pacman.out" 2>/dev/null | tr -d '\r')
  die "${last:-Omaflow could not install coolercontrold.}"
fi

pacman -Q -- coolercontrold >/dev/null \
  || die "coolercontrold did not install."
