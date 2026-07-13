#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
local_package_names=(
  lenovo-wwan-unlock
  xembed-sni-proxy
)

if [[ $EUID -eq 0 ]]; then
  echo "Local packages must be built as an unprivileged user." >&2
  exit 1
fi

if [[ ! -t 0 ]]; then
  echo "Refusing to build local packages without an interactive review." >&2
  exit 1
fi

for package_name in "${local_package_names[@]}"; do
  pkgbuild="$repo_root/packages/local/$package_name/PKGBUILD"
  if [[ ! -r $pkgbuild ]]; then
    echo "Missing PKGBUILD: $pkgbuild" >&2
    exit 1
  fi

  printf '\n==> Review %s\n\n' "$pkgbuild"
  sed -n '1,320p' "$pkgbuild"
  printf '\n'
  read -r -p "Build and install $package_name after review? [y/N] " answer
  if [[ ! $answer =~ ^[Yy]$ ]]; then
    echo "Local package installation cancelled before making changes."
    exit 1
  fi
done

build_root=$(mktemp -d)
trap 'rm -rf -- "$build_root"' EXIT

for package_name in "${local_package_names[@]}"; do
  cp -a -- "$repo_root/packages/local/$package_name" "$build_root/$package_name"
  printf '\n==> Building reviewed local package: %s\n' "$package_name"
  (
    cd "$build_root/$package_name"
    makepkg \
      --clean \
      --cleanbuild \
      --install \
      --needed \
      --rmdeps \
      --syncdeps
  )
done
