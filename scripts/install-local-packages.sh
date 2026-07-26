#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
local_package_build_attempts=${LOCAL_PACKAGE_BUILD_ATTEMPTS:-4}
local_package_retry_delay_seconds=${LOCAL_PACKAGE_BUILD_RETRY_DELAY_SECONDS:-10}

[[ $local_package_build_attempts =~ ^[1-9][0-9]*$ ]] || {
  echo "LOCAL_PACKAGE_BUILD_ATTEMPTS must be a positive integer." >&2
  exit 1
}
[[ $local_package_retry_delay_seconds =~ ^[0-9]+$ ]] || {
  echo "LOCAL_PACKAGE_BUILD_RETRY_DELAY_SECONDS must be zero or a positive integer." >&2
  exit 1
}

build_local_package() {
  local package_name=$1 package_dir=$2
  local attempt status

  for ((attempt = 1; attempt <= local_package_build_attempts; attempt++)); do
    if (
      cd "$package_dir"
      makepkg \
        --clean \
        --cleanbuild \
        --install \
        --needed \
        --noconfirm \
        --rmdeps \
        --syncdeps
    ); then
      return 0
    else
      status=$?
    fi

    if ((attempt == local_package_build_attempts)); then
      printf \
        'ERROR: local package %s exhausted %d build attempts (last status: %d).\n' \
        "$package_name" "$local_package_build_attempts" "$status" >&2
      return "$status"
    fi

    printf \
      'WARNING: local package %s build attempt %d/%d failed with status %d; retrying in %ss.\n' \
      "$package_name" "$attempt" "$local_package_build_attempts" "$status" \
      "$local_package_retry_delay_seconds" >&2
    sleep "$local_package_retry_delay_seconds"
  done
}

if [[ $EUID -eq 0 ]]; then
  echo "Local packages must be built as an unprivileged user." >&2
  exit 1
fi

mapfile -t local_package_names < <(
  find "$repo_root/packages/local" -mindepth 2 -maxdepth 2 -type f -name PKGBUILD \
    -printf '%h\n' 2>/dev/null |
    xargs -r -n1 basename |
    sort -u
)

if ((${#local_package_names[@]} == 0)); then
  echo "No local packages are declared."
  exit 0
fi

declare -a pending_packages=()
for package_name in "${local_package_names[@]}"; do
  package_dir="$repo_root/packages/local/$package_name"
  srcinfo=$(cd "$package_dir" && makepkg --printsrcinfo)
  pkgver=$(awk '$1 == "pkgver" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
  pkgrel=$(awk '$1 == "pkgrel" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
  epoch=$(awk '$1 == "epoch" && $2 == "=" { print $3; exit }' <<<"$srcinfo")

  [[ -n $pkgver && -n $pkgrel ]] || {
    echo "Could not determine the desired version for $package_name." >&2
    exit 1
  }

  desired_version="$pkgver-$pkgrel"
  if [[ -n $epoch && $epoch != 0 ]]; then
    desired_version="$epoch:$desired_version"
  fi

  installed_name=
  installed_version=
  installed_query=$(pacman -Q "$package_name" 2>/dev/null || true)
  read -r installed_name installed_version <<<"$installed_query"
  if [[ $installed_name != "$package_name" ]]; then
    installed_version=
  fi
  version_comparison=1
  if [[ -n $installed_version ]]; then
    version_comparison=$(vercmp "$installed_version" "$desired_version")
  fi
  if ((version_comparison == 0)); then
    echo "==> Local package is current: $package_name $desired_version"
  else
    if [[ -n $installed_version ]]; then
      echo "==> Local package update required: $package_name $installed_version -> $desired_version"
    else
      echo "==> Local package install required: $package_name $desired_version"
    fi
    pending_packages+=("$package_name")
  fi
done

if ((${#pending_packages[@]} == 0)); then
  echo "All local packages are already current."
  exit 0
fi

build_root=$(mktemp -d)
trap 'rm -rf -- "$build_root"' EXIT

for package_name in "${pending_packages[@]}"; do
  cp -a -- "$repo_root/packages/local/$package_name" "$build_root/$package_name"
  printf '\n==> Building declared local package: %s\n' "$package_name"
  build_local_package "$package_name" "$build_root/$package_name"
done
