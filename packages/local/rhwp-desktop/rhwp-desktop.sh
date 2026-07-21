#!/usr/bin/env bash
set -euo pipefail

# The extracted AppImage carries a real, root-owned Chromium sandbox helper.
# Upstream honors this variable and otherwise appends --no-sandbox on Linux.
export RHWP_ENABLE_CHROMIUM_SANDBOX=1

declare -a launch_args=()
staging_dir=

for argument in "$@"; do
  if [[ -f $argument && ${argument,,} =~ \.hwpx?$ ]]; then
    if [[ -z $staging_dir ]]; then
      documents_dir=$(xdg-user-dir DOCUMENTS 2>/dev/null || true)
      [[ -n $documents_dir ]] || documents_dir=$HOME/Documents
      staging_dir=$documents_dir/RHWP-Validation
      umask 077
      mkdir -p -- "$staging_dir"
      chmod 0700 -- "$staging_dir"
    fi

    source_path=$(realpath -e -- "$argument")
    staging_path=$(realpath -m -- "$staging_dir")
    if [[ $source_path == "$staging_path"/* ]]; then
      launch_args+=("$source_path")
      continue
    fi

    timestamp=$(date +%Y%m%d-%H%M%S)
    basename=${source_path##*/}
    copy_path=$staging_dir/${timestamp}-${basename}
    counter=1
    while [[ -e $copy_path ]]; do
      copy_path=$staging_dir/${timestamp}-${counter}-${basename}
      ((counter += 1))
    done
    cp --reflink=auto -- "$source_path" "$copy_path"
    chmod 0600 -- "$copy_path"
    printf 'RHWP rollout copy: %s\n' "$copy_path" >&2
    launch_args+=("$copy_path")
  else
    launch_args+=("$argument")
  fi
done

exec /opt/rhwp-desktop/rhwp-desktop \
  --ozone-platform=wayland \
  --enable-features=UseOzonePlatform \
  --disable-features=WaylandWindowDecorations \
  --enable-wayland-ime \
  --wayland-text-input-version=3 \
  "${launch_args[@]}"
