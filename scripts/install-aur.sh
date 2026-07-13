#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/packages/aur.txt"

if [[ $EUID -eq 0 ]]; then
  echo "AUR packages must be built as an unprivileged user." >&2
  exit 1
fi

if ! command -v paru >/dev/null 2>&1; then
  build_dir=$(mktemp -d)
  trap 'rm -rf -- "$build_dir"' EXIT

  echo "==> Bootstrapping paru from the AUR"
  git clone https://aur.archlinux.org/paru.git "$build_dir/paru"
  echo "Review the PKGBUILD at: $build_dir/paru/PKGBUILD"

  if [[ ! -t 0 ]]; then
    echo "Refusing to build an unreviewed PKGBUILD non-interactively." >&2
    exit 1
  fi

  read -r -p "Continue building paru after review? [y/N] " answer
  if [[ ! $answer =~ ^[Yy]$ ]]; then
    echo "AUR installation cancelled."
    exit 1
  fi

  (
    cd "$build_dir/paru"
    makepkg -si
  )
fi

mapfile -t aur_packages < <(
  sed -E \
    -e 's/[[:space:]]+#.*$//' \
    -e '/^[[:space:]]*(#|$)/d' \
    "$manifest"
)

if ((${#aur_packages[@]} == 0)); then
  echo "No AUR packages are declared."
  exit 0
fi

echo "==> Installing reviewed AUR package bases"
printf '  %s\n' "${aur_packages[@]}"
paru -S --needed -- "${aur_packages[@]}"
