#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap=$repo_root/bootstrap.sh
aur_installer=$repo_root/scripts/install-aur.sh
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

for flag in --noupgrademenu --nosudoloop --noconfirm; do
  grep -Fq -- "$flag" "$aur_installer" ||
    fail "AUR convergence does not enforce $flag"
done
if grep -Fq -- '--skipreview' "$aur_installer"; then
  fail 'AUR convergence bypasses the review lock'
fi
grep -Fq "\"\$review_helper\" verify --destination" "$aur_installer" ||
  fail 'AUR convergence does not materialize review-locked package bases'
grep -Fq "PACMAN_AUTH=(%q)" "$aur_installer" ||
  fail 'reviewed paru bootstrap does not preserve the single sudo session'

[[ $(git config --file "$git_config" --get core.editor) == 'zeditor --wait' ]] ||
  fail 'Git does not use the managed graphical editor outside bootstrap'
[[ $(git config --file "$git_config" --get sequence.editor) == 'zeditor --wait' ]] ||
  fail 'interactive rebases do not use the managed graphical editor'
[[ $(git config --file "$git_config" --get merge.autoEdit) == no ]] ||
  fail 'Git pulls may still open an editor for an automatic merge message'

printf 'Non-interactive bootstrap tests passed.\n'
