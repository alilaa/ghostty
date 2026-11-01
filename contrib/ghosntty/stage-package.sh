#!/usr/bin/env bash
# Common filesystem layout for the native Arch and Ubuntu packages.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 INSTALL_PREFIX PACKAGE_ROOT" >&2; exit 2; }
prefix=$(realpath "$1")
mkdir -p "$2"
root=$(realpath "$2")
source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(git -C "$source_dir" rev-parse --show-toplevel)
mkdir -p "$root"/{usr/bin,usr/lib/ghosntty/bin,usr/share/ghosntty}
install -m755 "$prefix/bin/ghostty" "$root/usr/lib/ghosntty/bin/ghostty"
install -m755 "$source_dir/launch.sh" "$root/usr/bin/ghosntty"
for resource in ghostty terminfo; do
    cp -a --no-preserve=ownership "$prefix/share/$resource" "$root/usr/share/ghosntty/"
done
cp -a --no-preserve=ownership "$source_dir/nvim" "$source_dir/editor_bridge.py" "$source_dir/profile" "$root/usr/share/ghosntty/"
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
install -Dm644 "$repo/LICENSE" "$root/usr/share/licenses/ghosntty/LICENSE"
install -m644 "$source_dir/README.md" "$root/usr/share/doc/ghosntty/README.md"
if [[ -d $prefix/share/licenses ]]; then
    cp -a --no-preserve=ownership "$prefix/share/licenses" "$root/usr/share/doc/ghosntty/dependency-licenses"
fi
