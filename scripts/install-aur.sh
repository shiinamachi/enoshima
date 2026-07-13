#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/packages/aur.txt"
sudo_command=${SUDO_COMMAND_WRAPPER:-sudo}

if [[ $EUID -eq 0 ]]; then
  echo "AUR packages must be built as an unprivileged user." >&2
  exit 1
fi

if ! command -v paru >/dev/null 2>&1 || ! paru --version >/dev/null 2>&1; then
  build_dir=$(mktemp -d)
  trap 'rm -rf -- "$build_dir"' EXIT

  echo "==> Bootstrapping paru from its declared AUR package base"
  GIT_TERMINAL_PROMPT=0 git clone https://aur.archlinux.org/paru.git "$build_dir/paru"
  (
    cd "$build_dir/paru"
    makepkg --install --noconfirm --syncdeps
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

echo "==> Converging declared AUR package bases"
printf '  %s\n' "${aur_packages[@]}"

# Resolve every target before allowing paru to start a partial installation.
echo "==> Resolving all declared AUR package bases"
paru -Si --aur -- "${aur_packages[@]}" >/dev/null

paru \
  --sudo "$sudo_command" \
  --skipreview \
  --noupgrademenu \
  --nosudoloop \
  --pgpfetch \
  -S \
  --needed \
  --noconfirm \
  -- "${aur_packages[@]}"
