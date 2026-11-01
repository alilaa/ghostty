#!/usr/bin/env bash
set -euo pipefail
prefix=${1:?Pass a build installation prefix}
zig build -Doptimize=fast -Dcpu=baseline -Dsimd=true \
    -Dversion-string="${BUILD_VERSION:?}" -Demit-docs=false -Demit-themes=true -Di18n=false \
    -Dinstalled-exe-path=/usr/bin/ghosntty \
    -fsys=freetype -fsys=harfbuzz -fsys=fontconfig -fsys=libpng \
    -fsys=zlib -fsys=oniguruma -fsys=gtk4-layer-shell -p "$prefix" -j2
zig test src/apprt/gtk/control_request.zig
zig test src/apprt/gtk/project_colors.zig
/usr/bin/python3 -m unittest discover -s contrib/ghosntty/tests -p 'test_*.py' -v
GHOSTTY_TEST_BACKEND=v2 nvim --headless -u NONE -l contrib/ghosntty/tests/test_adapter.lua
GHOSTTY_TEST_BACKEND=v3 nvim --headless -u NONE -l contrib/ghosntty/tests/test_adapter.lua
GHOSTTY_RESOURCES_DIR="$prefix/share/ghostty" "$prefix/bin/ghostty" +validate-config \
    --config-file="$PWD/contrib/ghosntty/profile/config.ghostty"
desktop-file-validate contrib/ghosntty/com.ghosntty.GhosnTTy.desktop
