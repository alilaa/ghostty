#!/usr/bin/env bash
set -euo pipefail
printf 'GhosnTTy build: %s\nSource commit: %s\n' "${BUILD_VERSION:?}" "$(git rev-parse HEAD)"
cat /etc/os-release
zig version
ghosntty --version
if command -v pacman >/dev/null; then
    printf '\nArch repository snapshot: 2026/10/01\n'
    pacman -Q
else
    printf '\nUbuntu native library versions:\n'
    dpkg-query -W libc6 libgtk-4-1 libadwaita-1-0 libgtk4-layer-shell0 python3
fi
