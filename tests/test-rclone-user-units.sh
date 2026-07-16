#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
password_helper=$repo_root/home/dot_local/bin/executable_rclone-cloud-password
setup_helper=$repo_root/home/dot_local/bin/executable_rclone-cloud-setup

grep -Fq -- "--label='enoshima rclone config'" "$setup_helper" || {
  printf 'FAIL: rclone setup does not use the enoshima Keyring label\n' >&2
  exit 1
}
for helper in "$password_helper" "$setup_helper"; do
  grep -Fq 'application enoshima' "$helper" || {
    printf 'FAIL: %s does not use the enoshima Keyring application\n' \
      "$(basename -- "$helper")" >&2
    exit 1
  }
done

for unit in \
  "$repo_root/home/dot_config/systemd/user/rclone-google-drive.service" \
  "$repo_root/home/dot_config/systemd/user/rclone-proton-drive.service"; do
  grep -Fxq 'PrivateTmp=false' "$unit" || {
    printf 'FAIL: %s isolates its FUSE mount from the desktop namespace\n' \
      "$(basename -- "$unit")" >&2
    exit 1
  }

  if grep -Eq '^(PrivateMounts|ProtectHome)=true$' "$unit"; then
    printf 'FAIL: %s enables a mount namespace incompatible with desktop FUSE mounts\n' \
      "$(basename -- "$unit")" >&2
    exit 1
  fi
done

grep -Fxq 'RestartSec=5min' \
  "$repo_root/home/dot_config/systemd/user/rclone-proton-drive.service" || {
  printf 'FAIL: Proton Drive retry cadence can trigger backend rate limiting\n' >&2
  exit 1
}

printf 'PASS: rclone user units preserve host-visible FUSE mounts\n'
