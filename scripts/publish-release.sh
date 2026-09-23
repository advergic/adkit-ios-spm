#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 [--dry-run] <version>" >&2
  echo "Example: $0 0.1.0" >&2
}

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
  shift
fi

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

version="$1"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: '$version' is not a valid SemVer version." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ ! -d .git ]]; then
  echo "Error: this script must run inside the git repository." >&2
  exit 1
fi

branch="$(git symbolic-ref --quiet --short HEAD)" || {
  echo "Error: release must start from a named branch." >&2
  exit 1
}

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree is not clean. Commit or stash changes first." >&2
  exit 1
fi

tag="v$version"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
  echo "Error: local tag '$tag' already exists." >&2
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  echo "Error: remote tag '$tag' already exists." >&2
  exit 1
fi

constants_file="Sources/AdvergicAdKit/Internal/Constants.swift"
podspec_file="AdvergicAdKit.podspec"

if [[ "$dry_run" == true ]]; then
  echo "Would publish $tag from branch '$branch'."
  echo "Would update $constants_file and $podspec_file."
  echo "Would commit, tag, and push to origin."
  exit 0
fi

perl -0pi -e 's/(static let sdkVersion = )"[^"]+"/$1"'"$version"'"/' "$constants_file"
VERSION="$version" perl -0pi -e 's/(s\.version\s*=\s*)'"'"'[^'"'"']+'"'"'/$1'"'"'$ENV{VERSION}'"'"'/' "$podspec_file"

if ! grep -q "static let sdkVersion = \"$version\"" "$constants_file"; then
  echo "Error: failed to update $constants_file." >&2
  exit 1
fi

if ! grep -q "s.version.*'$version'" "$podspec_file"; then
  echo "Error: failed to update $podspec_file." >&2
  exit 1
fi

git diff --check
git add "$constants_file" "$podspec_file"
git commit -m "Release $version"
git tag "$tag"
git push origin "$branch" "$tag"

echo "Published $tag from branch '$branch'."