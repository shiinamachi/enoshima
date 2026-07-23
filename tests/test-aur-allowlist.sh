#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer=$repo_root/scripts/install-aur.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -- "$work/bin"

fail() {
  printf 'AUR allowlist test failed: %s\n' "$*" >&2
  exit 1
}

cat >"$work/bin/paru" <<'PARU'
#!/usr/bin/env bash
set -eu
if [[ ${1:-} == --version ]]; then
  printf 'paru test\n'
  exit 0
fi
printf '%s\n' "$*" >>"$AUR_TEST_LOG"
package=${!#}
if [[ $package == alpha-bin ]]; then
  exit 23
fi
PARU
chmod +x "$work/bin/paru"

printf 'alpha-bin\nbeta-bin\n' >"$work/aur.txt"
if env \
  PATH="$work/bin:$PATH" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  "$installer" >"$work/failure.out" 2>&1; then
  fail 'a failed approved package did not produce a final failure status'
fi

[[ $(grep -c -- '--needed -S -- alpha-bin' "$work/attempts.log") -eq 4 ]] ||
  fail 'the failed package did not exhaust its bounded retry budget'
[[ $(grep -c -- '--needed -S -- beta-bin' "$work/attempts.log") -eq 1 ]] ||
  fail 'one package failure prevented a later approved package attempt'
grep -Fq -- '--skipreview' "$work/attempts.log" ||
  fail 'approved package bases still stop for per-revision review'
grep -Fq -- '--needed -S -- alpha-bin' "$work/attempts.log" ||
  fail 'the first approved package was not installed from its current AUR base'
grep -Fq -- '--needed -S -- beta-bin' "$work/attempts.log" ||
  fail 'the later approved package was not attempted after a failure'
grep -Fq 'FAILURE: AUR package base alpha-bin exited with status 23; continuing.' \
  "$work/failure.out" || fail 'the package failure was not reported explicitly'
grep -Fq \
  'WARNING: approved AUR package base alpha-bin attempt 3/4 failed; retrying in 0s.' \
  "$work/failure.out" || fail 'the bounded retry progress was not reported'
grep -Fq 'SUCCESS: approved AUR package base converged: beta-bin' \
  "$work/failure.out" || fail 'the successful later package was not reported'

printf 'beta-bin\n' >"$work/aur.txt"
: >"$work/attempts.log"
env \
  PATH="$work/bin:$PATH" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  "$installer" >/dev/null
[[ $(wc -l <"$work/attempts.log") -eq 1 ]] ||
  fail 'the successful approval manifest did not converge exactly once'

mkdir -p "$work/paru-source"
git -C "$work/paru-source" init -q
printf 'pkgname=paru\npkgver=1\npkgrel=1\narch=(any)\n' >"$work/paru-source/PKGBUILD"
git -C "$work/paru-source" add PKGBUILD
git -C "$work/paru-source" \
  -c user.name='Enoshima Test' \
  -c user.email='test@localhost' \
  commit -qm 'test: seed paru source'
cat >"$work/bin/makepkg" <<'MAKEPKG'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$AUR_MAKEPKG_LOG"
MAKEPKG
chmod +x "$work/bin/makepkg"
printf 'paru\nbeta-bin\n' >"$work/aur.txt"
: >"$work/attempts.log"
env \
  PATH="$work/bin:$PATH" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_PARU_URL="$work/paru-source" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  AUR_MAKEPKG_LOG="$work/makepkg.log" \
  "$installer" >"$work/paru.out"
[[ $(wc -l <"$work/makepkg.log") -eq 1 ]] ||
  fail 'the approved paru package was not converged exactly once by makepkg'
[[ $(grep -c -- '--needed -S -- beta-bin' "$work/attempts.log") -eq 1 ]] ||
  fail 'a package after paru was not converged exactly once'
if grep -Fq -- '--needed -S -- paru' "$work/attempts.log"; then
  fail 'paru attempted to update itself through its own package loop'
fi
grep -Fq 'SUCCESS: approved AUR package base converged: paru' \
  "$work/paru.out" || fail 'the separately converged paru package was not reported'

if rg -q 'aur-review|review-aur|aur_commit|pkgbuild_sha256|srcinfo_sha256' \
  "$installer" "$repo_root/packages/aur.txt"; then
  fail 'the AUR installer still contains revision-level approval machinery'
fi

printf 'AUR allowlist tests passed.\n'
