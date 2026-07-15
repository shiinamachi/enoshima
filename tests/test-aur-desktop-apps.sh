#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest=$repo_root/packages/aur.txt
lock_file=$repo_root/packages/aur-review.lock
postflight=$repo_root/scripts/postflight.sh

for package in electerm-bin pear-desktop-bin; do
  grep -Fxq "$package" "$manifest"
  jq -e --arg package "$package" '
    .packages[] | select(
      .pkgbase == $package and
      (.aur_commit | test("^[0-9a-f]{40}$")) and
      (.pkgbuild_sha256 | test("^[0-9a-f]{64}$")) and
      (.srcinfo_sha256 | test("^[0-9a-f]{64}$"))
    )
  ' "$lock_file" >/dev/null
done

grep -Fq '/usr/share/applications/electerm.desktop' "$postflight"
grep -Fq '/usr/share/applications/com.github.th-ch.youtube-music.desktop' "$postflight"

printf 'AUR desktop application tests passed.\n'
