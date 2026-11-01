#!/usr/bin/env bash
# Ubuntu 26.04 ships Blueprint 0.19; this checkout requires at least 0.20.
set -euo pipefail
destination=${1:?Pass a tool installation directory}
mkdir -p "$destination"
destination=$(realpath "$destination")
archive="$destination/blueprint-compiler-0.22.2.tar.xz"
if [[ ! -f $archive ]]; then
    curl --fail --location --retry 3 \
        https://download.gnome.org/sources/blueprint-compiler/0.22/blueprint-compiler-0.22.2.tar.xz \
        -o "$archive"
fi
echo '231d72efbac931c235ac3e022fe94982095c20d88721d9a8dcf60152f2017e07  '"$archive" | sha256sum --check
tar -xJf "$archive" -C "$destination"
# Use the distro Python, whose PyGObject modules were installed by apt.
export PATH="/usr/bin:/bin:$PATH"
meson setup "$destination/build" "$destination/blueprint-compiler-0.22.2" \
    --prefix="$destination/install" -Ddocs=false
meson compile -C "$destination/build"
meson install -C "$destination/build"
python_lib=$(/usr/bin/python3 - "$destination/install" <<'PY'
from pathlib import Path
import sys
modules = list(Path(sys.argv[1]).rglob("blueprintcompiler/main.py"))
assert len(modules) == 1, modules
print(modules[0].parents[1])
PY
)
export PYTHONPATH="$python_lib${PYTHONPATH:+:$PYTHONPATH}"
[[ $("$destination/install/bin/blueprint-compiler" --version) == 0.22.2 ]]
echo "$destination/install/bin" >> "${GITHUB_PATH:?}"
printf 'PYTHONPATH=%s\n' "$PYTHONPATH" >> "${GITHUB_ENV:?}"
