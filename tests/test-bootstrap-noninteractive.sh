#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap=$repo_root/bootstrap.sh
aur_installer=$repo_root/scripts/install-aur.sh
codex_installer=$repo_root/scripts/install-codex-desktop.sh
local_package_installer=$repo_root/scripts/install-local-packages.sh
font_package=$repo_root/packages/local/ttf-jetendard/PKGBUILD
git_config=$repo_root/home/dot_gitconfig

fail() {
  printf 'Non-interactive bootstrap test failed: %s\n' "$*" >&2
  exit 1
}

for assignment in \
  EDITOR=/usr/bin/false \
  VISUAL=/usr/bin/false \
  GIT_EDITOR=/usr/bin/false \
  GIT_SEQUENCE_EDITOR=/usr/bin/false \
  GIT_MERGE_AUTOEDIT=no \
  SYSTEMD_EDITOR=/usr/bin/false \
  SUDO_EDITOR=/usr/bin/false \
  PAGER=/usr/bin/cat \
  GIT_PAGER=/usr/bin/cat \
  SYSTEMD_PAGER=/usr/bin/cat \
  MANPAGER=/usr/bin/cat \
  BAT_PAGER=/usr/bin/cat \
  PARU_PAGER=/usr/bin/cat \
  GIT_TERMINAL_PROMPT=0; do
  grep -Fxq "export $assignment" "$bootstrap" ||
    fail "bootstrap does not enforce $assignment"
done

for flag in --noupgrademenu --nosudoloop --skipreview --noconfirm; do
  grep -Fq -- "$flag" "$aur_installer" ||
    fail "AUR convergence does not enforce $flag"
done
grep -Fq -- '--needed' "$aur_installer" ||
  fail 'AUR convergence does not preserve already-current approved packages'
grep -Fq -- '-S' "$aur_installer" ||
  fail 'AUR convergence does not install the current approved package base'
grep -Fq "PACMAN_AUTH=(%q)" "$aur_installer" ||
  fail 'paru bootstrap does not preserve the single sudo session'

grep -Fq 'mise exec --' "$codex_installer" ||
  fail 'Codex Desktop build does not use the managed development runtimes'
grep -Fq 'PACKAGE_WITH_UPDATER=1' "$codex_installer" ||
  fail 'Codex Desktop build does not include the upstream update manager'
if grep -Fq 'make bootstrap-native' "$codex_installer"; then
  fail 'Codex Desktop installer bypasses the managed native dependency manifests'
fi

# shellcheck disable=SC2016 # Assertion intentionally matches literal bootstrap source.
grep -Fq 'PATH="/usr/bin:/bin:$PATH"' "$bootstrap" ||
  fail 'local package builds do not put Arch build tools ahead of mise shims'
if [[ $(grep -Fc '/usr/bin/python -m' "$font_package") -ne 2 ]]; then
  fail 'Jetendard build and test do not use the Arch Python dependency set'
fi
grep -Fq -- '--syncdeps' "$local_package_installer" ||
  fail 'local package convergence does not install declared build dependencies'

[[ $(git config --file "$git_config" --get core.editor) == 'zeditor --wait' ]] ||
  fail 'Git does not use the managed graphical editor outside bootstrap'
[[ $(git config --file "$git_config" --get sequence.editor) == 'zeditor --wait' ]] ||
  fail 'interactive rebases do not use the managed graphical editor'
[[ $(git config --file "$git_config" --get merge.autoEdit) == no ]] ||
  fail 'Git pulls may still open an editor for an automatic merge message'
mapfile -t credential_helpers < <(
  git config --file "$git_config" --get-all credential.helper || true
)
if ((${#credential_helpers[@]} != 1)) || [[ ${credential_helpers[0]:-} != store ]]; then
  fail 'the managed global Git credential helper is not exactly store'
fi

printf 'Non-interactive bootstrap tests passed.\n'
