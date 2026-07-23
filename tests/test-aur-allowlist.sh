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

if rg -q 'aur-review|review-aur|aur_commit|pkgbuild_sha256|srcinfo_sha256' \
  "$installer" "$repo_root/packages/aur.txt"; then
  fail 'the AUR installer still contains revision-level approval machinery'
fi

printf 'AUR allowlist tests passed.\n'
