#!/usr/bin/env bash
set -euo pipefail
if [[ ${REF_TYPE:?} == tag ]]; then
    [[ ${RELEASE_REF:?} =~ ^ghosntty-v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$ ]] || { echo 'Invalid GhosnTTy release tag' >&2; exit 1; }
    package_version=${BASH_REMATCH[1]}-${BASH_REMATCH[2]}
    build_version=${BASH_REMATCH[1]}-ghosntty.${BASH_REMATCH[2]}
else
    package_version=1.4.0-3
    build_version=1.4.0-ghosntty.3
fi
printf 'PACKAGE_VERSION=%s\nBUILD_VERSION=%s\n' "$package_version" "$build_version" >> "${GITHUB_ENV:?}"
