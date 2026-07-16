#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest=$repo_root/packages/aur.txt
native_manifest=$repo_root/packages/native.txt
absent_manifest=$repo_root/packages/absent.txt
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

for electerm_package in \
  electerm \
  electerm-bin \
  electerm-git \
  electerm-live-bin; do
  for managed_manifest in \
    "$repo_root/packages/native.txt" \
    "$repo_root/packages/management.txt" \
    "$repo_root/packages/optional-deps.txt" \
    "$manifest"; do
    if grep -Fxq "$electerm_package" "$managed_manifest"; then
      printf 'Electerm must not remain in a managed package manifest: %s\n' \
        "$managed_manifest" >&2
      exit 1
    fi
  done

  if grep -Fxq "$electerm_package" "$absent_manifest"; then
    printf 'Electerm must remain user-managed rather than intentionally absent.\n' >&2
    exit 1
  fi

  jq -e --arg package "$electerm_package" \
    '[.packages[] | select(.pkgbase == $package)] | length == 0' \
    "$lock_file" >/dev/null
done
grep -Fxq filezilla "$native_manifest"
grep -Fq '/usr/share/applications/filezilla.desktop' "$postflight"
grep -Fq 'filezilla_version_reports' "$postflight"
if grep -Fq '/usr/share/applications/electerm.desktop' "$postflight"; then
  printf 'Postflight must not require a user-managed Electerm installation.\n' >&2
  exit 1
fi
grep -Fq '/usr/share/applications/com.github.th-ch.youtube-music.desktop' "$postflight"

printf 'AUR desktop application tests passed.\n'
