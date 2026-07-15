#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest=$repo_root/packages/aur.txt
native_manifest=$repo_root/packages/native.txt
lock_file=$repo_root/packages/aur-review.lock
postflight=$repo_root/scripts/postflight.sh

package=pear-desktop-bin
grep -Fxq "$package" "$manifest"
jq -e --arg package "$package" '
  .packages[] | select(
    .pkgbase == $package and
    (.aur_commit | test("^[0-9a-f]{40}$")) and
    (.pkgbuild_sha256 | test("^[0-9a-f]{64}$")) and
    (.srcinfo_sha256 | test("^[0-9a-f]{64}$"))
  )
' "$lock_file" >/dev/null

if grep -Fxq electerm-bin "$manifest"; then
  printf 'Electerm must not remain in the managed AUR manifest.\n' >&2
  exit 1
fi
jq -e '[.packages[] | select(.pkgbase == "electerm-bin")] | length == 0' \
  "$lock_file" >/dev/null
grep -Fxq filezilla "$native_manifest"
grep -Fq '/usr/share/applications/filezilla.desktop' "$postflight"
if grep -Fq '/usr/share/applications/electerm.desktop' "$postflight"; then
  printf 'Postflight must not require a user-managed Electerm installation.\n' >&2
  exit 1
fi
grep -Fq '/usr/share/applications/com.github.th-ch.youtube-music.desktop' "$postflight"

printf 'AUR desktop application tests passed.\n'
