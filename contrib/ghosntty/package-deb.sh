#!/usr/bin/env bash
# Package an Ubuntu-native Zig install prefix; no Arch/private GTK libraries.
set -euo pipefail
if [[ $# != 3 || ! $3 =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
    echo "Usage: $0 INSTALL_PREFIX OUTPUT_DIRECTORY VERSION (e.g. 1.4.0-1)" >&2
    exit 2
fi
prefix=$(realpath "$1")
mkdir -p "$2"
output=$(realpath "$2")
version=$3
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
arch=$(dpkg --print-architecture)
[[ $arch == amd64 ]] || { echo 'This release targets amd64.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
bash "$source_dir/stage-package.sh" "$prefix" "$root"
mkdir -p "$root/DEBIAN"

# Generate ABI/version requirements from the binary linked on the target OS.
mkdir -p "$work/debian"
cat > "$work/debian/control" <<'CONTROL'
Source: ghosntty
Section: x11
Priority: optional
Maintainer: GhosnTTy contributors <alilaa@users.noreply.github.com>
Standards-Version: 4.7.0

Package: ghosntty
Architecture: amd64
Description: Terminal with project-colored tabs and Neovim navigation
CONTROL
dependencies=$(cd "$work" && dpkg-shlibdeps -O -e"$root/usr/lib/ghosntty/bin/ghostty")
dependencies=${dependencies#shlibs:Depends=}
cat > "$root/DEBIAN/control" <<CONTROL
Package: ghosntty
Version: $version
Section: x11
Priority: optional
Architecture: $arch
Maintainer: GhosnTTy contributors <alilaa@users.noreply.github.com>
Depends: $dependencies, python3, python3-gi
Recommends: fonts-jetbrains-mono, fonts-noto-color-emoji
Installed-Size: $(du -sk "$root/usr" | cut -f1)
Homepage: https://github.com/alilaa/ghostty
Description: Terminal with project-colored tabs and Neovim navigation
 GhosnTTy is a Ghostty fork with compact colored bottom tabs and
 pane-targeted smart-splits integration for Neovim.
CONTROL
dpkg-deb --root-owner-group --build "$root" "$output/ghosntty_${version}_ubuntu26.04_${arch}.deb"
