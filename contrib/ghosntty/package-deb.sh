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
repo=$(git -C "$source_dir" rev-parse --show-toplevel)
arch=$(dpkg --print-architecture)
[[ $arch == amd64 ]] || { echo 'This release targets amd64.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
mkdir -p "$root"/{DEBIAN,usr/bin,usr/lib/ghosntty/bin,usr/share/ghosntty}
install -m755 "$prefix/bin/ghostty" "$root/usr/lib/ghosntty/bin/ghostty"
install -m755 "$source_dir/launch.sh" "$root/usr/bin/ghosntty"
for resource in ghostty terminfo; do
    cp -a "$prefix/share/$resource" "$root/usr/share/ghosntty/"
done
cp -a "$source_dir/nvim" "$source_dir/editor_bridge.py" "$source_dir/profile" "$root/usr/share/ghosntty/"
find "$root/usr/share/ghosntty" -type d -name __pycache__ -prune -exec rm -rf {} +
install -Dm644 "$source_dir/com.ghosntty.GhosnTTy.desktop" "$root/usr/share/applications/com.ghosntty.GhosnTTy.desktop"
install -Dm644 "$source_dir/com.ghosntty.GhosnTTy.service" "$root/usr/share/dbus-1/services/com.ghosntty.GhosnTTy.service"
for size in 16 32 64 128 256 512 1024; do
    icon="$repo/images/gnome/$size.png"
    if [[ -f $icon ]]; then
        install -Dm644 "$icon" "$root/usr/share/icons/hicolor/${size}x${size}/apps/com.ghosntty.GhosnTTy.png"
    fi
done
install -Dm644 "$repo/LICENSE" "$root/usr/share/doc/ghosntty/copyright"
install -m644 "$source_dir/README.md" "$root/usr/share/doc/ghosntty/README.md"

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
