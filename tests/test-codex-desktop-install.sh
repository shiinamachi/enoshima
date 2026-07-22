#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer=$repo_root/scripts/install-codex-desktop.sh
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'Codex Desktop installer test failed: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$work/bin" "$work/upstream"

cat >"$work/bin/mise" <<'MISE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == exec && ${2:-} == -- ]] || exit 64
shift 2
exec "$@"
MISE

cat >"$work/bin/pacman" <<'PACMAN'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -Q && ${2:-} == codex-desktop && -f $TEST_INSTALLED ]]; then
  printf 'codex-desktop 1-1\n'
  exit 0
fi
exit 1
PACMAN
chmod +x "$work/bin/mise" "$work/bin/pacman"

cat >"$work/upstream/Makefile" <<'MAKEFILE'
.PHONY: install-native
install-native:
	@printf '%s\n' '$(PACKAGE_VERSION)|$(PACKAGE_WITH_UPDATER)|$(MAX_BUILD_THREADS)|$(DMG)' >>'$(TEST_BUILD_LOG)'
	@touch '$(TEST_INSTALLED)'
MAKEFILE

git -C "$work/upstream" init --quiet --initial-branch=main
git -C "$work/upstream" config user.name 'Codex Desktop Test'
git -C "$work/upstream" config user.email 'codex-desktop-test@example.invalid'
git -C "$work/upstream" add Makefile
GIT_AUTHOR_DATE=2026-07-17T00:00:00Z \
  GIT_COMMITTER_DATE=2026-07-17T00:00:00Z \
  git -C "$work/upstream" commit --quiet -m 'initial fixture'

export PATH="$work/bin:$PATH"
export TEST_BUILD_LOG=$work/build.log
export TEST_INSTALLED=$work/installed
export XDG_CACHE_HOME=$work/cache
export XDG_STATE_HOME=$work/state
export CODEX_DESKTOP_REPOSITORY=$work/upstream
export CODEX_DESKTOP_MAX_BUILD_THREADS=3

"$installer"
[[ $(wc -l <"$TEST_BUILD_LOG") -eq 1 ]] || fail 'first convergence did not build exactly once'
grep -Eq '^2026\.07\.17\.000000\+[0-9a-f]{12}\|1\|3\|$' "$TEST_BUILD_LOG" ||
  fail 'build did not receive deterministic version, updater, and thread settings'

source_checkout=$XDG_CACHE_HOME/enoshima/codex-desktop-linux/source
revision_marker=$XDG_STATE_HOME/enoshima/codex-desktop-linux/installed-source-revision
[[ -d $source_checkout/.git ]] || fail 'upstream source checkout was not cached'
[[ $(<"$revision_marker") == $(git -C "$work/upstream" rev-parse HEAD) ]] ||
  fail 'installed source revision was not recorded'

"$installer"
[[ $(wc -l <"$TEST_BUILD_LOG") -eq 1 ]] || fail 'current source revision rebuilt unnecessarily'

printf 'second fixture revision\n' >"$work/upstream/revision.txt"
git -C "$work/upstream" add revision.txt
GIT_AUTHOR_DATE=2026-07-17T00:01:00Z \
  GIT_COMMITTER_DATE=2026-07-17T00:01:00Z \
  git -C "$work/upstream" commit --quiet -m 'update fixture'

mkdir -p "$XDG_CACHE_HOME/codex-desktop"
truncate -s 512 "$XDG_CACHE_HOME/codex-desktop/Codex.dmg"
printf koly | dd of="$XDG_CACHE_HOME/codex-desktop/Codex.dmg" \
  bs=1 seek=0 conv=notrunc status=none
"$installer"
[[ $(wc -l <"$TEST_BUILD_LOG") -eq 2 ]] || fail 'new upstream source revision did not rebuild'
tail -n 1 "$TEST_BUILD_LOG" |
  grep -Eq "^2026\\.07\\.17\\.000100\\+[0-9a-f]{12}\\|1\\|3\\|$XDG_CACHE_HOME/codex-desktop/Codex\\.dmg$" ||
  fail 'updated build did not receive its source-derived version'
[[ $(<"$revision_marker") == $(git -C "$work/upstream" rev-parse HEAD) ]] ||
  fail 'updated source revision was not recorded'

grep -Fxq chatgpt-desktop-bin "$repo_root/packages/absent.txt" ||
  fail 'retired AUR package is not declared absent'
if grep -Fxq chatgpt-desktop-bin "$repo_root/packages/aur.txt"; then
  fail 'retired AUR package remains approved'
fi

printf 'Codex Desktop installer tests passed.\n'
