#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
review_helper=$repo_root/scripts/review-aur.sh
installer=$repo_root/scripts/install-aur.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
remotes=$work/remotes
mkdir -- "$remotes"

create_remote() {
  local pkgbase=$1 seed
  seed=$work/$pkgbase
  mkdir -- "$seed"
  git -C "$seed" init --quiet
  git -C "$seed" config user.name Test
  git -C "$seed" config user.email test@example.invalid
  printf 'pkgname=%s\npkgver=1\npkgrel=1\n' "$pkgbase" >"$seed/PKGBUILD"
  printf 'pkgbase = %s\n\tpkgver = 1\n\tpkgrel = 1\n\npkgname = %s\n' \
    "$pkgbase" "$pkgbase" >"$seed/.SRCINFO"
  git -C "$seed" add PKGBUILD .SRCINFO
  git -C "$seed" commit --quiet -m initial
  git clone --quiet --bare "$seed" "$remotes/$pkgbase.git"
}

create_remote alpha-bin
create_remote beta-bin
printf 'alpha-bin\nbeta-bin\n' >"$work/aur.txt"

lock_entry() {
  local pkgbase=$1 seed
  seed=$work/$pkgbase
  jq -n \
    --arg pkgbase "$pkgbase" \
    --arg commit "$(git -C "$seed" rev-parse HEAD)" \
    --arg pkgbuild "$(sha256sum "$seed/PKGBUILD" | awk '{print $1}')" \
    --arg srcinfo "$(sha256sum "$seed/.SRCINFO" | awk '{print $1}')" '
      {pkgbase:$pkgbase,aur_commit:$commit,pkgbuild_sha256:$pkgbuild,
       srcinfo_sha256:$srcinfo,reviewed_at:"2026-07-15"}
    '
}

jq -n \
  --argjson alpha "$(lock_entry alpha-bin)" \
  --argjson beta "$(lock_entry beta-bin)" '
    {schema:1,reviewed_at:"2026-07-15",packages:[$alpha,$beta]}
  ' >"$work/aur-review.lock"

env \
  AUR_REVIEW_MANIFEST="$work/aur.txt" \
  AUR_REVIEW_LOCK="$work/aur-review.lock" \
  AUR_REVIEW_URL_TEMPLATE="file://$remotes/{pkgbase}.git" \
  "$review_helper" verify --destination "$work/verified" >/dev/null
[[ -f $work/verified/alpha-bin/PKGBUILD ]]
[[ -f $work/verified/beta-bin/.SRCINFO ]]

printf '\n# reviewed recipe changed\n' >>"$work/alpha-bin/PKGBUILD"
git -C "$work/alpha-bin" add PKGBUILD
git -C "$work/alpha-bin" commit --quiet -m changed
git -C "$work/alpha-bin" push --quiet "$remotes/alpha-bin.git" HEAD:master
if env \
  AUR_REVIEW_MANIFEST="$work/aur.txt" \
  AUR_REVIEW_LOCK="$work/aur-review.lock" \
  AUR_REVIEW_URL_TEMPLATE="file://$remotes/{pkgbase}.git" \
  "$review_helper" verify --destination "$work/changed" \
  >"$work/changed.out" 2>&1; then
  printf 'A changed AUR recipe passed the review lock.\n' >&2
  exit 1
fi
grep -Fq 'AUR package changed since review: alpha-bin' "$work/changed.out"

grep -Fq "\"\$review_helper\" verify --destination" "$installer"
grep -Fq -- '--build' "$installer"
grep -Fq -- '--install' "$installer"
if grep -Fq -- '--skipreview' "$installer"; then
  printf 'AUR installer still bypasses review.\n' >&2
  exit 1
fi
if grep -Fq -- ' -S ' "$installer"; then
  printf 'AUR installer fetches a second unverified recipe through paru -S.\n' >&2
  exit 1
fi

printf 'AUR review gate tests passed.\n'
