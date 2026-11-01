#!/usr/bin/env bash
set -euo pipefail
destination=${1:?Pass a tool installation directory}
mkdir -p "$destination"
curl --fail --location --retry 3 https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz -o "$destination/zig.tar.xz"
echo '1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026  '"$destination/zig.tar.xz" | sha256sum --check
tar -xJf "$destination/zig.tar.xz" -C "$destination"
echo "$destination/zig-x86_64-linux-0.17.0" >> "${GITHUB_PATH:?}"
