#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap=$repo_root/bootstrap.sh
aur_installer=$repo_root/scripts/install-aur.sh
codex_installer=$repo_root/scripts/install-codex-desktop.sh
codex_revision_lock=$repo_root/packages/codex-desktop-source-revision.txt
codex_dmg_lock=$repo_root/packages/codex-desktop-dmg-sha256.txt
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
grep -Fq 'CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS' "$codex_installer" ||
  fail 'Codex Desktop build has no bounded timeout'
grep -Fq 'CODEX_DESKTOP_BUILD_ATTEMPTS' "$codex_installer" ||
  fail 'Codex Desktop build has no bounded retry policy'
grep -Fq 'CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS' "$codex_installer" ||
  fail 'Codex Desktop build has no bounded retry delay'
grep -Eq '^[0-9a-f]{40}$' "$codex_revision_lock" ||
  fail 'Codex Desktop source revision is not locked to a full commit'
grep -Eq '^[0-9a-f]{64}$' "$codex_dmg_lock" ||
  fail 'Codex Desktop DMG is not locked to a SHA-256 digest'
grep -Fq 'checkout --quiet --detach' "$codex_installer" ||
  fail 'Codex Desktop source pin is not checked out detached'
# shellcheck disable=SC2016 # Assertion intentionally matches literal installer source.
grep -Fq 'sha256sum -- "$dmg_cache"' "$codex_installer" ||
  fail 'Codex Desktop cached DMG is not verified against its lock'
if grep -Fq 'make bootstrap-native' "$codex_installer"; then
  fail 'Codex Desktop installer bypasses the managed native dependency manifests'
fi
if grep -Fq 'pacman.conf.j2' "$bootstrap"; then
  fail 'bootstrap passes an unrendered Ansible pacman template to pacman'
fi
# shellcheck disable=SC2016 # Assertion intentionally matches literal bootstrap source.
grep -Fq '"$SUDO_COMMAND_WRAPPER" pacman -Syu --needed --noconfirm' "$bootstrap" ||
  fail 'bootstrap does not perform a full upgrade with the active pacman policy'
grep -Fq 'BOOTSTRAP_PACKAGE_MAX_ATTEMPTS:-4' "$bootstrap" ||
  fail 'bootstrap package convergence has no bounded retry budget'
grep -Fq 'bootstrap package upgrade exhausted its retry budget' "$bootstrap" ||
  fail 'bootstrap package convergence does not report exhausted retries'
grep -Fq 'register: pacman_configuration' \
  "$repo_root/ansible/roles/packages/tasks/main.yml" ||
  fail 'Ansible does not track pacman repository configuration changes'
grep -Fq 'or (pacman_configuration is changed)' \
  "$repo_root/ansible/roles/packages/tasks/main.yml" ||
  fail 'Ansible can enable repositories without a full upgrade'
# shellcheck disable=SC2016 # Assertion intentionally matches literal bootstrap source.
grep -Fq 'ENOSHIMA_SKIP_VM_HARNESS_CHECKS=true "$repo_root/scripts/validate.sh"' \
  "$bootstrap" ||
  fail 'the VM profile repeats host-only harness checks inside the guest'
grep -Fq 'ENOSHIMA_SKIP_VM_HARNESS_CHECKS:-false' \
  "$repo_root/scripts/validate.sh" ||
  fail 'repository validation cannot skip host-only harness checks in a VM guest'

bootstrap_dependencies=$(
  sed -n '/^install_bootstrap_dependencies()/,/^}/p' "$bootstrap"
)
for package in \
  base-devel \
  chezmoi \
  gtk4 \
  hyprland \
  imagemagick \
  json-glib \
  librsvg \
  lua \
  ripgrep \
  yq; do
  grep -Eq "^[[:space:]]+$package( \\\\|; then)?$" <<<"$bootstrap_dependencies" ||
    fail "bootstrap validation prerequisite is missing: $package"
done

retry_work=$(mktemp -d)
trap 'rm -rf -- "$retry_work"' EXIT
# shellcheck disable=SC2016 # The generated mock must expand these variables when it runs.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'count=0' \
  '[[ ! -f $BOOTSTRAP_PACMAN_ATTEMPT_FILE ]] || read -r count <"$BOOTSTRAP_PACMAN_ATTEMPT_FILE"' \
  'count=$((count + 1))' \
  'printf "%s\\n" "$count" >"$BOOTSTRAP_PACMAN_ATTEMPT_FILE"' \
  '((count >= 3))' >"$retry_work/sudo-wrapper"
chmod +x "$retry_work/sudo-wrapper"
(
  eval "$bootstrap_dependencies"
  export BOOTSTRAP_PACMAN_ATTEMPT_FILE="$retry_work/attempts"
  export SUDO_COMMAND_WRAPPER="$retry_work/sudo-wrapper"
  export BOOTSTRAP_PACKAGE_MAX_ATTEMPTS=3
  export BOOTSTRAP_PACKAGE_RETRY_DELAY_SECONDS=0
  install_bootstrap_dependencies >/dev/null 2>&1
) || fail 'bootstrap package convergence did not recover within its retry budget'
[[ $(<"$retry_work/attempts") == 3 ]] ||
  fail 'bootstrap package convergence did not exercise the expected retries'

retry_helper=$(
  sed -n '/^run_with_bounded_retries()/,/^}/p' "$bootstrap"
)
hypr_retry_work=$retry_work/hyprpm
mkdir -p "$hypr_retry_work"
(
  eval "$retry_helper"
  # shellcheck disable=SC2329 # Invoked indirectly by run_with_bounded_retries.
  transient_hyprpm_convergence() {
    local count=0
    [[ ! -f $HYPRPM_RETRY_ATTEMPT_FILE ]] ||
      read -r count <"$HYPRPM_RETRY_ATTEMPT_FILE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$HYPRPM_RETRY_ATTEMPT_FILE"
    ((count >= 3))
  }
  export HYPRPM_RETRY_ATTEMPT_FILE=$hypr_retry_work/attempts
  run_with_bounded_retries \
    "Hyprland plugin convergence" 3 0 transient_hyprpm_convergence
) >/dev/null 2>&1 ||
  fail 'Hyprland plugin convergence did not recover within its retry budget'
[[ $(<"$hypr_retry_work/attempts") == 3 ]] ||
  fail 'Hyprland plugin convergence did not exercise the expected retries'
grep -Fq 'HYPRPM_CONVERGE_MAX_ATTEMPTS:-4' "$bootstrap" ||
  fail 'Hyprland plugin convergence has no bounded retry budget'

# shellcheck disable=SC2016 # Assertion intentionally matches literal bootstrap source.
grep -Fq 'PATH="/usr/bin:/bin:$PATH"' "$bootstrap" ||
  fail 'local package builds do not put Arch build tools ahead of mise shims'
if [[ $(grep -Fc '/usr/bin/python -m' "$font_package") -ne 2 ]]; then
  fail 'Jetendard build and test do not use the Arch Python dependency set'
fi
grep -Fq -- '--syncdeps' "$local_package_installer" ||
  fail 'local package convergence does not install declared build dependencies'
grep -Fq 'LOCAL_PACKAGE_BUILD_ATTEMPTS:-4' "$local_package_installer" ||
  fail 'local package convergence has no bounded build retry budget'
grep -Fq 'LOCAL_PACKAGE_BUILD_RETRY_DELAY_SECONDS:-10' "$local_package_installer" ||
  fail 'local package convergence has no bounded build retry delay'

local_package_retry_helper=$(
  sed -n '/^build_local_package()/,/^}/p' "$local_package_installer"
)
local_package_retry_work=$retry_work/local-package
mkdir -p "$local_package_retry_work/package"
(
  eval "$local_package_retry_helper"
  # shellcheck disable=SC2329 # Invoked indirectly by the extracted helper.
  makepkg() {
    local count=0
    [[ ! -f $LOCAL_PACKAGE_ATTEMPT_FILE ]] ||
      read -r count <"$LOCAL_PACKAGE_ATTEMPT_FILE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$LOCAL_PACKAGE_ATTEMPT_FILE"
    ((count >= 3))
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the extracted helper.
  sleep() {
    :
  }
  export LOCAL_PACKAGE_ATTEMPT_FILE=$local_package_retry_work/attempts
  # shellcheck disable=SC2034 # Read by the extracted helper evaluated above.
  local_package_build_attempts=3
  # shellcheck disable=SC2034 # Read by the extracted helper evaluated above.
  local_package_retry_delay_seconds=0
  build_local_package fixture "$local_package_retry_work/package"
) >/dev/null 2>&1 ||
  fail 'local package convergence did not recover within its retry budget'
[[ $(<"$local_package_retry_work/attempts") == 3 ]] ||
  fail 'local package convergence did not exercise the expected retries'

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
