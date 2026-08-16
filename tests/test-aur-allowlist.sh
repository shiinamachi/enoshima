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

cat >"$work/bin/provenance-empty" <<'PROVENANCE'
#!/usr/bin/env bash
set -eu
case ${1:-} in
  validate)
    exit 0
    ;;
  list)
    :
    ;;
  install)
    printf 'empty provenance helper cannot install protected packages\n' >&2
    exit 90
    ;;
  *)
    exit 91
    ;;
esac
PROVENANCE
chmod +x "$work/bin/provenance-empty"
export AUR_PROVENANCE_HELPER=$work/bin/provenance-empty

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
printf '%s|%s\n' "${RUSTUP_TOOLCHAIN:-}" "$*" >>"$AUR_MAKEPKG_LOG"
MAKEPKG
chmod +x "$work/bin/makepkg"
cat >"$work/bin/mise" <<'MISE'
#!/usr/bin/env bash
set -eu
printf 'mise must not be consulted for the paru toolchain\n' >&2
exit 97
MISE
chmod +x "$work/bin/mise"
printf '[tools]\nrust = "0.0.1"\n' >"$work/untrusted-mise.toml"
printf 'paru\nbeta-bin\n' >"$work/aur.txt"
: >"$work/attempts.log"
env \
  PATH="$work/bin:$PATH" \
  MISE_CONFIG_FILE="$work/untrusted-mise.toml" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_PARU_URL="$work/paru-source" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  AUR_MAKEPKG_LOG="$work/makepkg.log" \
  "$installer" >"$work/paru.out"
[[ $(wc -l <"$work/makepkg.log") -eq 1 ]] ||
  fail 'the approved paru package was not converged exactly once by makepkg'
grep -Fq '1.97.0|--config ' "$work/makepkg.log" ||
  fail 'the approved paru build did not select the repository-pinned Rust toolchain'
[[ $(grep -c -- '--needed -S -- beta-bin' "$work/attempts.log") -eq 1 ]] ||
  fail 'a package after paru was not converged exactly once'
if grep -Fq -- '--needed -S -- paru' "$work/attempts.log"; then
  fail 'paru attempted to update itself through its own package loop'
fi
grep -Fq 'SUCCESS: approved AUR package base converged: paru' \
  "$work/paru.out" || fail 'the separately converged paru package was not reported'

cat >"$work/bin/provenance-protected" <<'PROVENANCE'
#!/usr/bin/env bash
set -eu
case ${1:-} in
  validate)
    exit 0
    ;;
  list)
    printf 'hyprshell-bin\n'
    ;;
  install)
    printf '%s\n' "$*" >>"$AUR_PROVENANCE_TEST_LOG"
    exit "${AUR_PROVENANCE_TEST_STATUS:-37}"
    ;;
  *)
    exit 91
    ;;
esac
PROVENANCE
chmod +x "$work/bin/provenance-protected"
printf 'hyprshell-bin\nbeta-bin\n' >"$work/aur.txt"
: >"$work/attempts.log"
if env \
  AUR_PROVENANCE_HELPER="$work/bin/provenance-protected" \
  AUR_PROVENANCE_TEST_LOG="$work/protected.log" \
  PATH="$work/bin:$PATH" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  "$installer" >"$work/protected.out" 2>&1; then
  fail 'a failed protected package did not produce a final failure status'
fi
[[ $(wc -l <"$work/protected.log") -eq 1 ]] ||
  fail 'the protected package did not use exactly one provenance installation attempt'
grep -Fq 'install --lock ' "$work/protected.log" ||
  fail 'the protected package did not use the provenance installation command'
if grep -Eq -- '--needed -S -- hyprshell-bin($|[[:space:]])' "$work/attempts.log"; then
  fail 'the protected package fell back to the unreviewed paru path'
fi
[[ $(grep -c -- '--needed -S -- beta-bin' "$work/attempts.log") -eq 1 ]] ||
  fail 'a failed protected package prevented later legacy convergence'
grep -Fq \
  'FAILURE: protected AUR package base hyprshell-bin exited with status 37; continuing.' \
  "$work/protected.out" || fail 'the protected provenance failure was not explicit'

: >"$work/attempts.log"
if env \
  AUR_PROVENANCE_HELPER="$work/bin/provenance-protected" \
  AUR_PROVENANCE_TEST_LOG="$work/protected-unsafe.log" \
  AUR_PROVENANCE_TEST_STATUS=70 \
  PATH="$work/bin:$PATH" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  "$installer" >"$work/protected-unsafe.out" 2>&1; then
  fail 'a residual unsafe protected state did not fail convergence'
fi
[[ ! -s $work/attempts.log ]] ||
  fail 'legacy convergence continued after a residual unsafe protected state'
grep -Fq \
  'FAILURE: unsafe installed state for protected AUR package base hyprshell-bin; stopping immediately.' \
  "$work/protected-unsafe.out" ||
  fail 'the residual unsafe-state hard stop was not explicit'

cat >"$work/bin/provenance-list-failure" <<'PROVENANCE'
#!/usr/bin/env bash
set -eu
case ${1:-} in
  validate)
    exit 0
    ;;
  list)
    exit 66
    ;;
  install)
    exit 67
    ;;
  *)
    exit 68
    ;;
esac
PROVENANCE
chmod +x "$work/bin/provenance-list-failure"
: >"$work/attempts.log"
if env \
  AUR_PROVENANCE_HELPER="$work/bin/provenance-list-failure" \
  PATH="$work/bin:$PATH" \
  AUR_MANIFEST="$work/aur.txt" \
  AUR_INSTALL_RETRY_DELAY_SECONDS=0 \
  AUR_TEST_LOG="$work/attempts.log" \
  "$installer" >"$work/protected-list-failure.out" 2>&1; then
  fail 'a failed protected package classification did not stop convergence'
fi
[[ ! -s $work/attempts.log ]] ||
  fail 'a failed protected classification fell through to paru'
grep -Fq \
  'Protected AUR package classification failed; refusing all AUR convergence.' \
  "$work/protected-list-failure.out" ||
  fail 'the protected classification failure was not explicit'

printf 'AUR allowlist tests passed.\n'
