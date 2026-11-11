#!/usr/bin/env bash
# Run from a terminal with access to your existing GitHub/SSH credentials.
set -euo pipefail
tag=${1:-ghosntty-v1.4.0-12}
[[ $tag =~ ^ghosntty-v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] || { echo 'Invalid release tag' >&2; exit 2; }
cd -- "$(dirname -- "$0")/../.."
[[ -z $(git status --porcelain) ]] || { echo 'Commit changes before publishing.' >&2; exit 1; }
branch=$(git branch --show-current)
[[ -n $branch ]] || { echo 'Check out the release branch first.' >&2; exit 1; }
if git show-ref --verify --quiet "refs/tags/$tag"; then
    [[ $(git rev-parse "$tag^{commit}") == $(git rev-parse HEAD) ]] || { echo 'Tag already points at another commit.' >&2; exit 1; }
else
    git tag -a "$tag" -m "GhosnTTy ${tag#ghosntty-v} for Arch and Ubuntu 26.04 x86-64"
fi
git -c core.sshCommand='ssh -F /dev/null' push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"
printf '\nBuild and release status: https://github.com/alilaa/ghostty/actions/workflows/ghosntty-release.yml\n'
printf 'The Arch package and Ubuntu .deb will appear at https://github.com/alilaa/ghostty/releases/tag/%s after both platform checks pass.\n' "$tag"
