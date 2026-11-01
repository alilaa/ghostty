#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 || ! $3 =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$ ]]; then
    echo "Usage: $0 INSTALL_PREFIX OUTPUT_DIRECTORY VERSION (e.g. 1.4.0-2)" >&2
    exit 2
fi
export GHOSNTTY_PKGVER=${BASH_REMATCH[1]} GHOSNTTY_PKGREL=${BASH_REMATCH[2]}
GHOSNTTY_SOURCE_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
GHOSNTTY_PREFIX=$(realpath "$1")
mkdir -p "$2"
PKGDEST=$(realpath "$2")
export GHOSNTTY_SOURCE_DIR GHOSNTTY_PREFIX PKGDEST
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$GHOSNTTY_SOURCE_DIR/arch/PKGBUILD" "$work/PKGBUILD"
cd "$work"
makepkg --noconfirm
