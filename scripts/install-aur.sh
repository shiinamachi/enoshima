#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/packages/aur.txt"
review_helper="$repo_root/scripts/review-aur.sh"
sudo_command=${SUDO_COMMAND_WRAPPER:-sudo}

if [[ $EUID -eq 0 ]]; then
  echo "AUR packages must be built as an unprivileged user." >&2
  exit 1
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

review_dir=$(mktemp -d)
trap 'rm -rf -- "$review_dir"' EXIT
"$review_helper" verify --destination "$review_dir"

expected_version() {
  local directory=$1 epoch pkgver pkgrel
  epoch=$(awk -F ' = ' '$1 ~ /^[[:space:]]*epoch$/ {print $2; exit}' "$directory/.SRCINFO")
  pkgver=$(awk -F ' = ' '$1 ~ /^[[:space:]]*pkgver$/ {print $2; exit}' "$directory/.SRCINFO")
  pkgrel=$(awk -F ' = ' '$1 ~ /^[[:space:]]*pkgrel$/ {print $2; exit}' "$directory/.SRCINFO")
  [[ -n $pkgver && -n $pkgrel ]] || return 1
  if [[ -n $epoch ]]; then printf '%s:%s-%s\n' "$epoch" "$pkgver" "$pkgrel"; else printf '%s-%s\n' "$pkgver" "$pkgrel"; fi
}

package_base_is_current() {
  local directory=$1 version pkgname installed found=false
  version=$(expected_version "$directory") || return 1
  while IFS= read -r pkgname; do
    [[ -n $pkgname ]] || continue
    found=true
    installed=$(pacman -Q "$pkgname" 2>/dev/null | awk '{print $2}') || return 1
    [[ $installed == "$version" ]] || return 1
  done < <(awk -F ' = ' '$1 ~ /^[[:space:]]*pkgname$/ {print $2}' "$directory/.SRCINFO")
  [[ $found == true ]]
}

if ! command -v paru >/dev/null 2>&1 || ! paru --version >/dev/null 2>&1; then
  echo "==> Bootstrapping paru from its reviewed, exact AUR revision"
  makepkg_config=$review_dir/makepkg.conf
  cp -- /etc/makepkg.conf "$makepkg_config"
  printf '\nPACMAN_AUTH=(%q)\n' "$sudo_command" >>"$makepkg_config"
  (
    cd "$review_dir/paru"
    makepkg --config "$makepkg_config" --install --noconfirm --syncdeps
  )
fi

for package in "${aur_packages[@]}"; do
  if package_base_is_current "$review_dir/$package"; then
    printf '==> AUR package base is current: %s\n' "$package"
    continue
  fi
  printf '==> Building reviewed AUR package base: %s\n' "$package"
  paru \
    --sudo "$sudo_command" \
    --noupgrademenu \
    --nosudoloop \
    --pgpfetch \
    --noconfirm \
    --build \
    --install \
    -- "$review_dir/$package"
done
