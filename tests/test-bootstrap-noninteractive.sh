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
grep -Fq '"$SUDO_COMMAND_WRAPPER" /usr/bin/pacman "${hook_args[@]}"' "$bootstrap" ||
  fail 'bootstrap does not perform a full upgrade with the active pacman policy'
grep -Fq -- '-Syu --needed --noconfirm' "$bootstrap" ||
  fail 'bootstrap does not preserve Arch full-upgrade semantics'
grep -Fq -- '--ignore hyprshell-bin --ignore vicinae-bin' "$bootstrap" ||
  fail 'the full upgrade can replace reviewed local packages before verified convergence'
grep -Fq 'BOOTSTRAP_PACKAGE_MAX_ATTEMPTS:-4' "$bootstrap" ||
  fail 'bootstrap package convergence has no bounded retry budget'
grep -Fq 'bootstrap package upgrade exhausted its retry budget' "$bootstrap" ||
  fail 'bootstrap package convergence does not report exhausted retries'
grep -Fq 'prepare_vicinae_for_initial_full_upgrade' "$bootstrap" ||
  fail 'bootstrap does not stop an installed Vicinae before its initial full upgrade'
reviewed_guard_digest=$(sha256sum \
  "$repo_root/packages/local/vicinae-bin/vicinae-qt-guard" | cut -d ' ' -f1)
grep -Fxq "vicinae_reviewed_guard_sha256=$reviewed_guard_digest" "$bootstrap" ||
  fail 'bootstrap does not authenticate the pre-upgrade Vicinae Qt guard'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$SUDO_COMMAND_WRAPPER" "$reviewed_stage" hold' "$bootstrap" ||
  fail 'bootstrap does not hold Vicinae before the initial full upgrade'
grep -Fq 'VICINAE_KEEP_HELD=true' "$bootstrap" ||
  fail 'bootstrap can release Vicinae during local package convergence'
vicinae_policy_prepare=$(
  sed -n '/^prepare_vicinae_for_user_policy()/,/^}/p' "$bootstrap"
)
vicinae_policy_enable=$(
  sed -n '/^enable_vicinae_after_user_policy_impl()/,/^}/p' "$bootstrap"
)
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
prepare_hold_line=$(grep -n -m1 '"$guard" hold' <<<"$vicinae_policy_prepare" | cut -d: -f1)
prepare_mask_line=$(grep -n -m1 'systemctl --user mask --now' \
  <<<"$vicinae_policy_prepare" | cut -d: -f1)
[[ -n $prepare_hold_line && -n $prepare_mask_line &&
  $prepare_hold_line -lt $prepare_mask_line ]] ||
  fail 'bootstrap does not establish the root hold before masking the current user'
policy_files_line=$(grep -n -m1 'vicinae_user_policy_files_valid' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
search_masked_line=$(grep -n -m1 'vicinae_unit_search_path_clean masked' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
abi_line=$(grep -n -m1 'vicinae_installed_abi_compatible' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
release_line=$(grep -n -m1 'release-if-compatible' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
unmask_line=$(grep -n -m1 'systemctl --user unmask --runtime' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
search_unmasked_line=$(grep -n -m1 'vicinae_unit_search_path_clean unmasked' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
effective_line=$(grep -n -m1 'vicinae_effective_service_policy_valid' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
enable_line=$(grep -n -m1 'systemctl --user enable vicinae.service' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
start_line=$(grep -n -m1 'systemctl --user start vicinae.service' \
  <<<"$vicinae_policy_enable" | cut -d: -f1)
((policy_files_line < search_masked_line && search_masked_line < abi_line && \
abi_line < unmask_line && unmask_line < search_unmasked_line && \
search_unmasked_line < release_line && release_line < effective_line && \
effective_line < enable_line && enable_line < start_line)) ||
  fail 'bootstrap does not preserve policy/ABI validation before declarative enable/start'
grep -Fq 'systemctl --user show --no-pager -P UnitPath' "$bootstrap" ||
  fail 'Vicinae preflight does not inspect the actual user-manager unit search path'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$root/service.d"' "$bootstrap" ||
  fail 'Vicinae preflight ignores type-wide service drop-ins'
grep -Fq 'systemctl --user mask --now vicinae.service' "$bootstrap" ||
  fail 'bootstrap failures do not restore the current-user persistent mask'
grep -Fq 'prepare_hyprshell_hooks_for_initial_full_upgrade' "$bootstrap" ||
  fail 'bootstrap does not suppress installed Hyprshell hooks before its full upgrade'
grep -Fq 'prepare_verified_full_upgrade_hook_dir' "$bootstrap" ||
  fail 'bootstrap does not use a per-run root-owned ALPM hook overlay'
grep -Fq 'Reconciling local package ABIs after package changes' "$bootstrap" ||
  fail 'bootstrap does not reconcile Qt-private local packages after package changes'
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
grep -Fq 'enoshima-vm | enoshima-vm-boot)' "$bootstrap" ||
  fail 'a disposable VM profile can repeat host-only harness checks without Git metadata'
grep -Fq 'ENOSHIMA_SKIP_VM_HARNESS_CHECKS:-false' \
  "$repo_root/scripts/validate.sh" ||
  fail 'repository validation cannot skip host-only harness checks in a VM guest'

bootstrap_dependencies=$(
  sed -n '/^install_bootstrap_dependencies()/,/^}/p' "$bootstrap"
)
for package in \
  base-devel \
  bubblewrap \
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
# shellcheck disable=SC2030 # Retry controls are intentionally subshell-local.
(
  eval "$bootstrap_dependencies"
  # shellcheck disable=SC2329 # Invoked by the extracted production helper.
  enforce_protected_package_safety_after_upgrade() { :; }
  export BOOTSTRAP_PACMAN_ATTEMPT_FILE="$retry_work/attempts"
  # shellcheck disable=SC2030 # The wrapper override is intentionally subshell-local.
  export SUDO_COMMAND_WRAPPER="$retry_work/sudo-wrapper"
  export BOOTSTRAP_PACKAGE_MAX_ATTEMPTS=3
  export BOOTSTRAP_PACKAGE_RETRY_DELAY_SECONDS=0
  install_bootstrap_dependencies >/dev/null 2>&1
) || fail 'bootstrap package convergence did not recover within its retry budget'
[[ $(<"$retry_work/attempts") == 3 ]] ||
  fail 'bootstrap package convergence did not exercise the expected retries'

cat >"$retry_work/sudo-hard-stop" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f $BOOTSTRAP_PACMAN_ATTEMPT_FILE ]] ||
  read -r count <"$BOOTSTRAP_PACMAN_ATTEMPT_FILE"
printf '%s\n' "$((count + 1))" >"$BOOTSTRAP_PACMAN_ATTEMPT_FILE"
exit 70
SH
chmod +x "$retry_work/sudo-hard-stop"
rm -f "$retry_work/attempts"
set +e
# shellcheck disable=SC2031 # This independent retry fixture reuses the same names.
(
  eval "$bootstrap_dependencies"
  # shellcheck disable=SC2329 # Invoked by the extracted production helper.
  enforce_protected_package_safety_after_upgrade() { :; }
  export BOOTSTRAP_PACMAN_ATTEMPT_FILE="$retry_work/attempts"
  # shellcheck disable=SC2030 # The wrapper override is intentionally subshell-local.
  export SUDO_COMMAND_WRAPPER="$retry_work/sudo-hard-stop"
  export BOOTSTRAP_PACKAGE_MAX_ATTEMPTS=4
  export BOOTSTRAP_PACKAGE_RETRY_DELAY_SECONDS=0
  install_bootstrap_dependencies
) >/dev/null 2>&1
bootstrap_hard_stop_status=$?
set -e
[[ $bootstrap_hard_stop_status == 70 && $(<"$retry_work/attempts") == 1 ]] ||
  fail 'bootstrap retried or downgraded a pacman security hard-stop'

vicinae_prepare_impl=$(
  sed -n '/^prepare_vicinae_for_initial_full_upgrade_impl()/,/^}/p' "$bootstrap"
)
vicinae_prepare_impl=${vicinae_prepare_impl//\/usr\/bin\/stat/stat}
vicinae_prepare_impl=${vicinae_prepare_impl//\/usr\/bin\/readlink/readlink}
vicinae_combined_gate=$(
  sed -n '/^prepare_vicinae_and_install_bootstrap_dependencies()/,/^}/p' "$bootstrap"
)
full_upgrade_gate=$(
  sed -n '/^bootstrap_run_after_full_upgrade()/,/^}/p' "$bootstrap"
)
vicinae_gate_work=$retry_work/vicinae-upgrade-gate
mkdir -p "$vicinae_gate_work"
cp -- \
  "$repo_root/packages/local/vicinae-bin/vicinae-qt-guard" \
  "$vicinae_gate_work/repository-guard"
cp -- \
  "$repo_root/packages/local/vicinae-bin/40-vicinae-qt-pre.hook" \
  "$vicinae_gate_work/installed-pre.hook"
for hook_name in \
  40-vicinae-qt-pre.hook \
  40-vicinae-qt-post.hook \
  41-vicinae-package-pre.hook \
  vicinae.hook; do
  cp -- "$repo_root/packages/local/vicinae-bin/$hook_name" \
    "$vicinae_gate_work/$hook_name"
done
cat >"$vicinae_gate_work/sudo-wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' /usr/bin/install -d '*) mkdir -p -- "${@: -1}" ;;
  *' /usr/bin/tee '*) mkdir -p -- "$(dirname -- "${@: -1}")"; /usr/bin/tee "${@: -1}" >/dev/null ;;
  *' /usr/bin/ln -sfn '*) /usr/bin/ln -sfn -- /dev/null "${@: -1}" ;;
  *' /usr/bin/test -L '*) /usr/bin/test -L "${@: -1}" ;;
  *' readlink -- '*) /usr/bin/readlink -- "${@: -1}" ;;
  *' stat -c %U:%G -- '*) printf 'root:root\n' ;;
  *' /usr/bin/chown '* | *' /usr/bin/chmod '*) : ;;
  *'vicinae-qt-guard hold'*)
    printf 'hold\n' >>"$VICINAE_GATE_EVENTS"
    exit "${VICINAE_GATE_PRE_STATUS:-0}"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$vicinae_gate_work/sudo-wrapper"

run_vicinae_upgrade_gate_case() {
  local fixture=$1 expected_status=$2 expected_events=$3
  local case_root=$vicinae_gate_work/$fixture status

  rm -rf -- "$case_root"
  mkdir -p "$case_root"
  case $fixture in
    trusted | guard-hold-failure) ;;
    *) fail "unknown Vicinae upgrade-gate fixture: $fixture" ;;
  esac
  : >"$case_root/events"

  set +e
  (
    eval "$vicinae_prepare_impl"
    eval "$vicinae_combined_gate"
    # shellcheck disable=SC2329 # Invoked by the extracted production helper.
    pacman() {
      case ${1:-} in
        -Q) [[ ${2:-} == vicinae-bin ]] ;;
        -Qlq)
          printf '%s\n' \
            "$vicinae_gate_work/40-vicinae-qt-pre.hook" \
            "$vicinae_gate_work/40-vicinae-qt-post.hook" \
            "$vicinae_gate_work/41-vicinae-package-pre.hook" \
            "$vicinae_gate_work/vicinae.hook" \
            /opt/custom-hooks/99-unknown-vicinae.hook
          ;;
        *) return 1 ;;
      esac
    }
    # shellcheck disable=SC2034 # Consumed by the extracted production helper.
    pacman_query_command=pacman
    # shellcheck disable=SC2034 # Used by the dynamically evaluated production helper.
    vicinae_reviewed_guard_sha256=$(sha256sum \
      "$vicinae_gate_work/repository-guard" | cut -d ' ' -f1)
    # shellcheck disable=SC2329 # Invoked by the extracted production helper.
    stat() {
      if [[ ${2:-} == %U:%G ]]; then
        printf 'root:root\n'
        return
      fi
      case ${*: -1} in
        *.hook) printf 'root:root:644\n' ;;
        */hooks) printf 'root:root:700\n' ;;
        *) printf 'root:root:755\n' ;;
      esac
    }
    # shellcheck disable=SC2329 # Invoked by the extracted production helper.
    die() {
      printf 'fixture die: %s\n' "$*" >&2
      return 97
    }
    # shellcheck disable=SC2329 # Invoked by the extracted combined gate.
    prepare_vicinae_for_initial_full_upgrade() {
      prepare_vicinae_for_initial_full_upgrade_impl \
        "$vicinae_gate_work/repository-guard" \
        "$case_root/staged/vicinae-qt-guard"
    }
    # shellcheck disable=SC2329 # Invoked by the extracted combined gate.
    prepare_hyprshell_hooks_for_initial_full_upgrade() { :; }
    # shellcheck disable=SC2329 # Invoked by the extracted combined gate.
    install_bootstrap_dependencies() {
      [[ -d ${vicinae_full_upgrade_hook_dir:-} &&
        -f $case_root/staged/vicinae-qt-guard ]] || return 89
      for hook_name in \
        40-vicinae-qt-pre.hook \
        40-vicinae-qt-post.hook \
        41-vicinae-package-pre.hook \
        vicinae.hook \
        99-unknown-vicinae.hook; do
        [[ -L $vicinae_full_upgrade_hook_dir/$hook_name &&
          $(readlink -- "$vicinae_full_upgrade_hook_dir/$hook_name") == /dev/null ]] || return 90
      done
      printf 'upgrade\n' >>"$VICINAE_GATE_EVENTS"
    }
    # shellcheck disable=SC2031 # The wrapper override is intentionally subshell-local.
    export SUDO_COMMAND_WRAPPER=$vicinae_gate_work/sudo-wrapper
    export VICINAE_GATE_EVENTS=$case_root/events
    if [[ $fixture == guard-hold-failure ]]; then
      export VICINAE_GATE_PRE_STATUS=42
    else
      unset VICINAE_GATE_PRE_STATUS || true
    fi
    prepare_vicinae_and_install_bootstrap_dependencies
  ) >/dev/null 2>&1
  status=$?
  set -e

  [[ $status == "$expected_status" ]] ||
    fail "$fixture Vicinae upgrade gate returned $status, expected $expected_status"
  [[ $(cat "$case_root/events") == "$expected_events" ]] ||
    fail "$fixture Vicinae upgrade gate did not preserve stop/upgrade ordering"
}

run_vicinae_upgrade_gate_case trusted 0 $'hold\nupgrade'
run_vicinae_upgrade_gate_case guard-hold-failure 42 hold

full_upgrade_gate_work=$retry_work/full-upgrade-gate
mkdir -p "$full_upgrade_gate_work"
(
  eval "$full_upgrade_gate"
  # shellcheck disable=SC2329 # Invoked indirectly by the extracted gate.
  bootstrap_run_step() {
    printf '%s\n' "$1" >>"$FULL_UPGRADE_GATE_EVENTS"
    shift
    "$@"
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the extracted gate.
  package_mutation() {
    printf 'mutated\n' >>"$FULL_UPGRADE_GATE_MUTATIONS"
  }
  export FULL_UPGRADE_GATE_EVENTS=$full_upgrade_gate_work/events
  export FULL_UPGRADE_GATE_MUTATIONS=$full_upgrade_gate_work/mutations
  # shellcheck disable=SC2034 # Read by the extracted production helper.
  full_upgrade_complete=false
  bootstrap_run_after_full_upgrade 'blocked package mutation' package_mutation
  [[ ! -e $FULL_UPGRADE_GATE_EVENTS && ! -e $FULL_UPGRADE_GATE_MUTATIONS ]]
  # shellcheck disable=SC2034 # Read by the extracted production helper.
  full_upgrade_complete=true
  bootstrap_run_after_full_upgrade 'allowed package mutation' package_mutation
) >/dev/null 2>&1 ||
  fail 'the full-upgrade success gate did not block and release package mutation'
[[ $(cat "$full_upgrade_gate_work/events") == 'allowed package mutation' ]] ||
  fail 'the full-upgrade gate did not call the package step exactly once'
[[ $(cat "$full_upgrade_gate_work/mutations") == mutated ]] ||
  fail 'the full-upgrade gate allowed a mutation before the full upgrade succeeded'

main_workflow=$(sed -n '/^bootstrap_run_step \\/,$p' "$bootstrap")
for mutation in \
  install_ansible_collection \
  install_mise_runtimes \
  install_local_packages \
  apply_ansible_desired_state \
  'scripts/install-aur.sh' \
  install_codex_desktop \
  apply_desktop_expansion \
  converge_hyprland_plugins_step; do
  if grep -B2 -F "$mutation" <<<"$main_workflow" |
    tail -n 3 | grep -Fq 'bootstrap_run_step'; then
    fail "package-mutating stage bypasses the full-upgrade success gate: $mutation"
  fi
done

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

mise_once=$(
  sed -n '/^install_mise_runtimes_once()/,/^}/p' "$bootstrap"
)
mise_retry=$(
  sed -n '/^install_mise_runtimes()/,/^}/p' "$bootstrap"
)
mise_retry_work=$retry_work/mise
mkdir -p "$mise_retry_work/bin"
# shellcheck disable=SC2016 # The generated mock expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'count=0' \
  '[[ ! -f $MISE_RETRY_ATTEMPT_FILE ]] || read -r count <"$MISE_RETRY_ATTEMPT_FILE"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$MISE_RETRY_ATTEMPT_FILE"' \
  '((count >= 3))' >"$mise_retry_work/bin/mise"
chmod +x "$mise_retry_work/bin/mise"
(
  eval "$retry_helper"
  eval "$mise_once"
  eval "$mise_retry"
  # shellcheck disable=SC2030 # The PATH override is intentionally subshell-local.
  export PATH="$mise_retry_work/bin:$PATH"
  export MISE_RETRY_ATTEMPT_FILE=$mise_retry_work/attempts
  export MISE_INSTALL_MAX_ATTEMPTS=3
  export MISE_INSTALL_RETRY_DELAY_SECONDS=0
  export MISE_INSTALL_TIMEOUT_SECONDS=30
  # shellcheck disable=SC2034 # Consumed by the extracted helper.
  mise_config_source=$repo_root/home/dot_config/mise/config.toml
  # shellcheck disable=SC2034 # Consumed by the extracted helper.
  mise_command=$mise_retry_work/bin/mise
  install_mise_runtimes
) >/dev/null 2>&1 ||
  fail 'mise runtime installation did not recover within its retry budget'
[[ $(<"$mise_retry_work/attempts") == 3 ]] ||
  fail 'mise runtime installation did not exercise the expected retries'

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

local_package_cleanup_work=$retry_work/local-package-cleanup
mkdir -p "$local_package_cleanup_work/repository/packages/local/fixture"
printf 'pkgname=fixture\n' \
  >"$local_package_cleanup_work/repository/packages/local/fixture/PKGBUILD"
set +e
# shellcheck disable=SC2030 # The sourced installer consumes this subshell-local root.
(
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$local_package_cleanup_work/repository
  local_package_build_parent=$local_package_cleanup_work/cache/enoshima/local-package-builds
  local_package_build_root=
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  makepkg() {
    printf 'pkgver = 1\npkgrel = 1\n'
  }
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  pacman() {
    return 1
  }
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  build_local_package() {
    printf '%s\n' "$local_package_build_root" \
      >"$local_package_cleanup_work/build-root"
    touch "$local_package_build_root/partial-build"
    return 23
  }
  trap cleanup_local_package_build EXIT
  main
) >/dev/null 2>&1
local_package_cleanup_status=$?
set -e
[[ $local_package_cleanup_status == 23 ]] ||
  fail 'local package fixture did not preserve its failing build status'
local_package_cleaned_root=$(<"$local_package_cleanup_work/build-root")
[[ ! -e $local_package_cleaned_root && ! -L $local_package_cleaned_root ]] ||
  fail 'a failed local package build leaked its per-run directory'

mkdir -p "$local_package_cleanup_work/symlink-target"
ln -s -- "$local_package_cleanup_work/symlink-target" \
  "$local_package_cleanup_work/symlink-parent"
if (
  # shellcheck disable=SC1090
  source "$local_package_installer"
  # shellcheck disable=SC2034 # Read by the sourced production helper.
  local_package_build_parent=$local_package_cleanup_work/symlink-parent
  prepare_local_package_build_parent
) >/dev/null 2>&1; then
  fail 'local package builds accepted a symlinked managed parent'
fi
[[ -z $(find "$local_package_cleanup_work/symlink-target" -mindepth 1 -print -quit) ]] ||
  fail 'local package build-parent validation followed a symlink'

# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$package_name" "$archive_path" "$verification_root"' \
  "$local_package_installer" ||
  fail 'verified local package archives are not checked before installation'
grep -Fq -- '--noscriptlet' "$local_package_installer" ||
  fail 'verified local installation does not disable package scriptlets'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq -- '--hookdir "$hook_dir"' "$local_package_installer" ||
  fail 'verified Vicinae replacement does not override installed ALPM hooks'
grep -Fq '/usr/bin/ln -s -- /dev/null' "$local_package_installer" ||
  fail 'verified Vicinae replacement does not disable package-owned hooks'
if sed -n '/^build_verified_local_package()/,/^}/p' "$local_package_installer" |
  grep -Fq -- '--needed'; then
  fail 'a verified local replacement can be skipped by pacman --needed'
fi
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$staged_guard" hold' "$local_package_installer" ||
  fail 'Vicinae verified installation does not stop active instances first'
grep -Fq 'vicinae-build-compatible' "$local_package_installer" ||
  fail 'Vicinae verified installation does not validate its live Qt manifest'
if grep -Fq 'vicinae_policy_pending_state_safe' "$local_package_installer"; then
  fail 'Vicinae ABI checks still depend on persistent lifecycle state'
fi
grep -Fq 'vicinae_compatibility_helper_trusted' "$local_package_installer" ||
  fail 'Vicinae ABI deferral does not authenticate its compatibility helper'
# shellcheck disable=SC2016 # Assertions intentionally match literal source.
for sandbox_flag in \
  '--unshare-all' \
  '--unshare-user' \
  '--disable-userns' \
  '--ro-bind /usr /usr' \
  '/run/systemd/resolve/*)' \
  '--ro-bind "$resolver_source" "$resolver_source"' \
  '--tmpfs /var' \
  '--ro-bind /var/lib/pacman /var/lib/pacman'; do
  grep -Fq -- "$sandbox_flag" "$local_package_installer" ||
    fail "verified local build sandbox is missing $sandbox_flag"
done
if sed -n '/^run_verified_local_sandboxed_makepkg()/,/^}/p' \
  "$local_package_installer" | grep -Fq -- '--ro-bind / /'; then
  fail 'verified local build sandbox exposes the full host filesystem'
fi
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$sudo_command" /usr/bin/tee "$staged_archive" <"$archive_path"' \
  "$local_package_installer" ||
  fail 'Vicinae archive staging lets root reopen a user-controlled path'
grep -Fq -- '--strip-components 3' "$local_package_installer" ||
  fail 'Vicinae guard extraction does not preserve the helper filename'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq 'hyprshell-bin | vicinae-bin' "$local_package_installer" ||
  fail 'Hyprshell and Vicinae do not share the verified local-package path'
grep -Fq -- '--unshare-net' "$local_package_installer" ||
  fail 'verified local compile/check/package phase retains network access'
grep -Fq -- '--nobuild' "$local_package_installer" ||
  fail 'verified local source preparation phase is missing'
grep -Fq -- '--noprepare' "$local_package_installer" ||
  fail 'verified local offline build reruns the source preparation phase'
grep -Fq 'LOCAL_PACKAGE_RUST_TOOLCHAIN_ROOT' "$local_package_installer" ||
  fail 'Hyprshell sandbox does not receive the resolved managed Rust root'
if grep -Fq 'vicinae_policy_paths=(' "$local_package_installer"; then
  fail 'the Vicinae package build still imports user-home policy inputs'
fi
grep -Fq 'VICINAE_KEEP_HELD' "$local_package_installer" ||
  fail 'the local Vicinae installer cannot preserve bootstrap-owned holds'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '[[ $vicinae_keep_held != true ]] || return 0' \
  "$local_package_installer" ||
  fail 'VICINAE_KEEP_HELD=true does not prevent release after a compatible build'
grep -Fq 'stage_verified_local_attestation_helper' "$local_package_installer" ||
  fail 'verified local attestation code is not staged as authenticated root-owned bytes'
# shellcheck disable=SC2031 # The earlier sourced-installer override was subshell-local.
attestation_digest=$(sha256sum \
  "$repo_root/scripts/lib/verified-local-attestation" | cut -d ' ' -f 1)
grep -Fq "verified_local_attestation_sha256=$attestation_digest" \
  "$local_package_installer" ||
  fail 'verified local attestation staging digest is stale'
grep -Fq 'prepare_verified_local_dependency_hooks' "$local_package_installer" ||
  fail 'verified build dependencies can still trigger installed package hooks'
grep -Fxq "vicinae_reviewed_guard_sha256=$reviewed_guard_digest" \
  "$local_package_installer" ||
  fail 'local-package dependency staging does not pin the reviewed Vicinae guard'
grep -Fq 'stage_reviewed_vicinae_dependency_guard' "$local_package_installer" ||
  fail 'Vicinae dependency upgrades do not stage authenticated root-owned guard bytes'
dependency_install_function=$(
  sed -n '/^install_verified_local_build_dependencies()/,/^}/p' \
    "$local_package_installer"
)
dependency_hold_line=$(grep -n 'hold_vicinae_for_build_dependencies' \
  <<<"$dependency_install_function" | head -n1 | cut -d: -f1)
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
dependency_pacman_line=$(grep -n '"$sudo_command" /usr/bin/pacman' \
  <<<"$dependency_install_function" | head -n1 | cut -d: -f1)
[[ -n $dependency_hold_line && -n $dependency_pacman_line &&
  $dependency_hold_line -lt $dependency_pacman_line ]] ||
  fail 'Vicinae is not held before the hook-suppressed dependency transaction'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$sudo_command" /usr/bin/rm -rf -- "$stage" || return 70' \
  "$local_package_installer" ||
  fail 'verified install staging cleanup can hide a failed root removal'
# shellcheck disable=SC2016 # Assertion intentionally matches literal bootstrap source.
grep -Fq 'exec --fresh-env "rust@$rust_toolchain"' "$bootstrap" ||
  fail 'bootstrap does not resolve the actual mise-selected Rust compiler'

attestation_test_root=$retry_work/verified-local-attestation
mkdir -p "$attestation_test_root"
# shellcheck disable=SC2031 # The earlier sourced-installer override was subshell-local.
if ! /usr/bin/python - \
  "$repo_root/scripts/lib/verified-local-attestation" \
  "$attestation_test_root" <<'PY'; then
import gzip
import hashlib
import os
from pathlib import Path
import runpy
import shutil
import sys

module = runpy.run_path(sys.argv[1])
root = Path(sys.argv[2]) / "live"
payload = root / "usr/bin/demo"
payload.parent.mkdir(parents=True)
payload.write_bytes(b"safe-payload\n")
payload.chmod(0o644)
hook = root / "usr/share/libalpm/hooks/evil.hook"
hook.parent.mkdir(parents=True)
hook.write_bytes(b"safe-hook\n")
hook.chmod(0o644)
for directory in (
    root / "usr",
    root / "usr/bin",
    root / "usr/share",
    root / "usr/share/libalpm",
    root / "usr/share/libalpm/hooks",
):
    directory.chmod(0o755)
uid = os.getuid()
gid = os.getgid()
digest = hashlib.sha256(payload.read_bytes()).hexdigest()
hook_digest = hashlib.sha256(hook.read_bytes()).hexdigest()
mtree = gzip.compress(
    (
        "#mtree\n"
        f"/set type=file uid={uid} gid={gid} mode=644\n"
        "./usr type=dir mode=755\n"
        "./usr/bin type=dir mode=755\n"
        f"./usr/bin/demo size={payload.stat().st_size} sha256digest={digest}\n"
        "./usr/share type=dir mode=755\n"
        "./usr/share/libalpm type=dir mode=755\n"
        "./usr/share/libalpm/hooks type=dir mode=755\n"
        f"./usr/share/libalpm/hooks/evil.hook size={hook.stat().st_size} "
        f"sha256digest={hook_digest}\n"
    ).encode()
)
module["verify_live_mtree"](mtree, live_root=root)
timestamps = (payload.stat().st_atime_ns, payload.stat().st_mtime_ns)
payload.write_bytes(b"evil-payload\n")
os.utime(payload, ns=timestamps)
try:
    module["verify_live_mtree"](mtree, live_root=root)
except module["AttestationError"]:
    pass
else:
    raise AssertionError("same-size payload mutation passed the mtree attestation")
payload.write_bytes(b"safe-payload\n")
hook_timestamps = (hook.stat().st_atime_ns, hook.stat().st_mtime_ns)
hook.write_bytes(b"evil-hook\n")
os.utime(hook, ns=hook_timestamps)
try:
    module["verify_live_mtree"](mtree, live_root=root)
except module["AttestationError"]:
    pass
else:
    raise AssertionError("same-size hook mutation passed the mtree attestation")
hook.write_bytes(b"safe-hook\n")
shutil.rmtree(root / "usr/bin")
(root / "target").mkdir()
(root / "target/demo").write_bytes(b"safe-payload\n")
(root / "usr/bin").symlink_to(root / "target", target_is_directory=True)
try:
    module["verify_live_mtree"](mtree, live_root=root)
except module["AttestationError"]:
    pass
else:
    raise AssertionError("symlinked payload ancestor passed the mtree attestation")
unsafe_mtree = gzip.compress(
    f"/set type=file uid={uid} gid={gid} mode=644\n./usr/../escape size=0 sha256digest={'0' * 64}\n".encode()
)
try:
    module["parse_mtree"](unsafe_mtree)
except module["AttestationError"]:
    pass
else:
    raise AssertionError("mtree path traversal was accepted")
PY
  fail 'verified local attestation did not hash live payloads or reject symlink traversal'
fi

hook_override_helper=$(
  sed -n '/^prepare_verified_local_hook_overrides()/,/^}/p' \
    "$local_package_installer"
)
hook_override_helper=${hook_override_helper//\/usr\/bin\/pacman/pacman}
hook_override_helper=${hook_override_helper//root:root/$(id -un):$(id -gn)}
hook_override_work=$retry_work/verified-hook-overrides
mkdir -p "$hook_override_work"
: >"$hook_override_work/privileged-commands"
cat >"$hook_override_work-sudo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${HOOK_OVERRIDE_PRIVILEGED_LOG:-} ]]; then
  printf '%s\n' "${1:-}" >>"$HOOK_OVERRIDE_PRIVILEGED_LOG"
fi
case ${1:-} in
  /usr/bin/install)
    target=${*: -1}
    mkdir -p -- "$target"
    chmod 0700 -- "$target"
    ;;
  /usr/bin/ln) "$@" ;;
  /usr/bin/test | /usr/bin/readlink | /usr/bin/stat) "$@" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$hook_override_work-sudo"
# shellcheck disable=SC2329 # The extracted helper invokes this pacman fixture.
(
  eval "$hook_override_helper"
  pacman() {
    case ${1:-} in
      -Qq) return 0 ;;
      -Qlq)
        case $HOOK_OVERRIDE_CASE in
          hyprshell) printf '%s\n' /opt/custom-hooks/99-unknown-hypr.hook ;;
          vicinae) printf '%s\n' /srv/review/hooks/77-unknown-vicinae.hook ;;
          unsafe) printf '%s\n' /opt/hooks/../escape.hook ;;
        esac
        ;;
      *) return 1 ;;
    esac
  }
  sudo_command=$hook_override_work-sudo
  export HOOK_OVERRIDE_PRIVILEGED_LOG=$hook_override_work/privileged-commands
  HOOK_OVERRIDE_CASE=hyprshell
  prepare_verified_local_hook_overrides hyprshell-bin "$hook_override_work/hypr"
  [[ -L $hook_override_work/hypr/99-unknown-hypr.hook ]]
  HOOK_OVERRIDE_CASE=vicinae
  prepare_verified_local_hook_overrides vicinae-bin "$hook_override_work/vicinae"
  for name in \
    77-unknown-vicinae.hook \
    40-vicinae-qt-pre.hook \
    40-vicinae-qt-post.hook \
    41-vicinae-package-pre.hook \
    vicinae.hook; do
    [[ -L $hook_override_work/vicinae/$name &&
      $(readlink -- "$hook_override_work/vicinae/$name") == /dev/null ]]
  done
  HOOK_OVERRIDE_CASE=unsafe
  set +e
  prepare_verified_local_hook_overrides hyprshell-bin "$hook_override_work/unsafe"
  unsafe_status=$?
  set -e
  [[ $unsafe_status == 70 ]]
) >/dev/null 2>&1 ||
  fail 'verified local hook overlays did not suppress unknown hooks or reject unsafe paths'
for privileged_hook_command in /usr/bin/test /usr/bin/readlink /usr/bin/stat; do
  grep -Fxq "$privileged_hook_command" "$hook_override_work/privileged-commands" ||
    fail "verified local hook validation bypassed $privileged_hook_command privilege"
done

hyprshell_update_work=$retry_work/hyprshell-local-update
mkdir -p "$hyprshell_update_work/packages/local/hyprshell-bin"
printf 'fixture\n' >"$hyprshell_update_work/packages/local/hyprshell-bin/PKGBUILD"
cat >"$hyprshell_update_work/packages/local/hyprshell-bin/provenance.json" <<'JSON'
{"package":{"version":"4.10.8-3"}}
JSON
(
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$hyprshell_update_work
  # shellcheck disable=SC2034 # Consumed by the sourced production main function.
  local_package_build_parent=$hyprshell_update_work/build-parent
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  verify_local_package_provenance() { printf 'verify\n' >>"$HYPRSHELL_UPDATE_EVENTS"; }
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  makepkg() {
    [[ ${1:-} == --printsrcinfo ]] || return 1
    printf 'pkgver = 4.10.8\npkgrel = 3\n'
  }
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  pacman() {
    [[ ${1:-} == -Q && ${2:-} == hyprshell-bin ]] || return 1
    printf 'hyprshell-bin 4.10.8-2\n'
  }
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  vercmp() {
    [[ $1 == 4.10.8-2 && $2 == 4.10.8-3 ]] || return 1
    printf '%s\n' -1
  }
  # shellcheck disable=SC2329 # Invoked by the sourced production main function.
  build_verified_local_package() {
    [[ $1 == hyprshell-bin ]]
    printf 'build\n' >>"$HYPRSHELL_UPDATE_EVENTS"
  }
  # shellcheck disable=SC2030 # Consumed by this sourced-main fixture.
  export HYPRSHELL_UPDATE_EVENTS=$hyprshell_update_work/events
  main
) >/dev/null 2>&1 ||
  fail 'Hyprshell 4.10.8-2 to local 4.10.8-3 migration was not selected'
[[ $(cat "$hyprshell_update_work/events") == $'verify\nbuild' ]] ||
  fail 'Hyprshell local migration did not verify before selecting the replacement build'

rm -f "$hyprshell_update_work/events"
# shellcheck disable=SC2030,SC2031,SC2329 # Sourced main invokes these local fixtures.
(
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$hyprshell_update_work
  verify_local_package_provenance() { printf 'verify\n' >>"$HYPRSHELL_UPDATE_EVENTS"; }
  makepkg() { printf 'pkgver = 4.10.8\npkgrel = 3\n'; }
  pacman() { printf 'hyprshell-bin 4.10.8-3\n'; }
  vercmp() { printf '0\n'; }
  verify_verified_local_install_attestation() {
    printf 'attest-stale\n' >>"$HYPRSHELL_UPDATE_EVENTS"
    return 2
  }
  build_verified_local_package() { printf 'build\n' >>"$HYPRSHELL_UPDATE_EVENTS"; }
  export HYPRSHELL_UPDATE_EVENTS=$hyprshell_update_work/events
  main
) >/dev/null 2>&1 ||
  fail 'an unattested same-version Hyprshell installation was not replaced'
[[ $(tail -n 2 "$hyprshell_update_work/events") == $'attest-stale\nbuild' ]] ||
  fail 'same-version Hyprshell bypassed the attestation rebuild gate'

rm -f "$hyprshell_update_work/events"
# shellcheck disable=SC2031,SC2329 # Sourced main invokes these local fixtures.
(
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$hyprshell_update_work
  verify_local_package_provenance() { printf 'verify\n' >>"$HYPRSHELL_UPDATE_EVENTS"; }
  makepkg() { printf 'pkgver = 4.10.8\npkgrel = 3\n'; }
  pacman() { printf 'hyprshell-bin 4.10.8-3\n'; }
  vercmp() { printf '0\n'; }
  verify_verified_local_install_attestation() {
    printf 'attest-valid\n' >>"$HYPRSHELL_UPDATE_EVENTS"
  }
  enforce_verified_local_installed_safety() {
    printf 'safety\n' >>"$HYPRSHELL_UPDATE_EVENTS"
  }
  build_verified_local_package() { return 99; }
  export HYPRSHELL_UPDATE_EVENTS=$hyprshell_update_work/events
  main
) >/dev/null 2>&1 ||
  fail 'an exactly attested same-version Hyprshell installation was rebuilt'
[[ $(tail -n 2 "$hyprshell_update_work/events") == $'attest-valid\nsafety' ]] ||
  fail 'the attested Hyprshell fast path skipped live installed safety'

local_package_verified_work=$retry_work/verified-vicinae
mkdir -p \
  "$local_package_verified_work/package" \
  "$local_package_verified_work/bin" \
  "$local_package_verified_work/scripts" \
  "$local_package_verified_work/workspace/packages"
printf 'fixture\n' \
  >"$local_package_verified_work/workspace/packages/vicinae-bin-0.25.0-10-x86_64.pkg.tar.zst"
cat >"$local_package_verified_work/bin/makepkg" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ $argument == --packagelist ]]; then
    printf '%s\n' "$VICINAE_TEST_ARCHIVE"
    exit 0
  fi
done
count=$(cat "$VICINAE_TEST_BUILD_COUNT" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" >"$VICINAE_TEST_BUILD_COUNT"
printf 'build %s\n' "$count" >>"$VICINAE_TEST_EVENTS"
((count >= 3))
SH
cat >"$local_package_verified_work/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$local_package_verified_work/scripts/check-vicinae-provenance" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify\n' >>"$VICINAE_TEST_EVENTS"
exit "${VICINAE_TEST_VERIFY_STATUS:-0}"
SH
cat >"$local_package_verified_work/sudo-wrapper" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *'vicinae-qt-guard hold'*) printf 'hold\n' >>"$VICINAE_TEST_EVENTS" ;;
  *'/usr/bin/pacman '*) printf 'install\n' >>"$VICINAE_TEST_EVENTS" ;;
  *'vicinae-qt-guard release-if-compatible'*) printf 'release\n' >>"$VICINAE_TEST_EVENTS" ;;
  *'vicinae-build-compatible'*) printf 'compatible\n' >>"$VICINAE_TEST_EVENTS" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$local_package_verified_work/bin/makepkg" \
  "$local_package_verified_work/bin/sleep" \
  "$local_package_verified_work/scripts/check-vicinae-provenance" \
  "$local_package_verified_work/sudo-wrapper"
(
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$local_package_verified_work
  local_package_build_attempts=3
  local_package_retry_delay_seconds=0
  sudo_command=$local_package_verified_work/sudo-wrapper
  # shellcheck disable=SC2030,SC2031 # The fake PATH is subshell-local by design.
  PATH="$local_package_verified_work/bin:$PATH"
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  install_verified_local_build_dependencies() { :; }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  verified_local_desired_version() { printf '0.25.0-10\n'; }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  fake_vicinae_sandboxed_makepkg() {
    [[ $4 == prepare ]] && return 0
    makepkg
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  install_verified_local_archive() {
    printf 'hold\ninstall\n' >>"$VICINAE_TEST_EVENTS"
    # shellcheck disable=SC2034 # Read by the sourced production helper.
    verified_local_install_attempted=true
    # shellcheck disable=SC2034 # Read by the sourced production helper.
    verified_local_staged_archive=$VICINAE_TEST_ARCHIVE
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  enforce_verified_local_installed_safety() {
    printf 'safety\n' >>"$VICINAE_TEST_EVENTS"
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  record_verified_local_install_attestation() {
    printf 'attest\n' >>"$VICINAE_TEST_EVENTS"
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced build helper.
  converge_vicinae_runtime_hold() {
    printf 'compatible\nrelease\n' >>"$VICINAE_TEST_EVENTS"
  }
  # shellcheck disable=SC2030 # Values are consumed by fake commands in this subshell.
  export VICINAE_TEST_ARCHIVE=$local_package_verified_work/workspace/packages/vicinae-bin-0.25.0-10-x86_64.pkg.tar.zst
  # shellcheck disable=SC2030 # Values are consumed by fake commands in this subshell.
  export VICINAE_TEST_BUILD_COUNT=$local_package_verified_work/build-count
  # shellcheck disable=SC2030 # Values are consumed by fake commands in this subshell.
  export VICINAE_TEST_EVENTS=$local_package_verified_work/events
  build_verified_local_package \
    vicinae-bin \
    "$local_package_verified_work/package" \
    "$local_package_verified_work/workspace" \
    "$local_package_verified_work" \
    fake_vicinae_sandboxed_makepkg
) >/dev/null 2>&1 ||
  fail 'verified Vicinae build did not recover and install after validation'
[[ $(cat "$local_package_verified_work/events") == $'verify\nbuild 1\nbuild 2\nbuild 3\nverify\nhold\ninstall\nsafety\nattest\ncompatible\nrelease' ]] ||
  fail 'verified Vicinae build did not preserve build/verify/install ordering'

: >"$local_package_verified_work/events"
printf '2\n' >"$local_package_verified_work/build-count"
set +e
# shellcheck disable=SC2030,SC2031,SC2329 # Sourced build helper invokes these fixtures.
(
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$local_package_verified_work
  local_package_build_attempts=1
  local_package_retry_delay_seconds=0
  PATH="$local_package_verified_work/bin:$PATH"
  install_verified_local_build_dependencies() { :; }
  verified_local_desired_version() { printf '0.25.0-10\n'; }
  fake_vicinae_sandboxed_makepkg() {
    [[ $4 == prepare ]] && return 0
    makepkg
  }
  install_verified_local_archive() {
    printf 'install-failed\n' >>"$VICINAE_TEST_EVENTS"
    # shellcheck disable=SC2034 # Read by the sourced production helper.
    verified_local_install_attempted=true
    # shellcheck disable=SC2034 # Read by the sourced production helper.
    verified_local_staged_archive=$VICINAE_TEST_ARCHIVE
    return 70
  }
  enforce_verified_local_installed_safety() {
    printf 'safety\n' >>"$VICINAE_TEST_EVENTS"
  }
  record_verified_local_install_attestation() {
    printf 'attest\n' >>"$VICINAE_TEST_EVENTS"
  }
  export VICINAE_TEST_ARCHIVE=$local_package_verified_work/workspace/packages/vicinae-bin-0.25.0-10-x86_64.pkg.tar.zst
  export VICINAE_TEST_BUILD_COUNT=$local_package_verified_work/build-count
  export VICINAE_TEST_EVENTS=$local_package_verified_work/events
  build_verified_local_package \
    vicinae-bin \
    "$local_package_verified_work/package" \
    "$local_package_verified_work/workspace" \
    "$local_package_verified_work" \
    fake_vicinae_sandboxed_makepkg
) >/dev/null 2>&1
partial_commit_status=$?
set -e
[[ $partial_commit_status == 70 &&
  $(tail -n 3 "$local_package_verified_work/events") == $'install-failed\nsafety\nattest' ]] ||
  fail 'local pacman partial-commit status or post-install attestation was lost'

: >"$local_package_verified_work/events"
printf '2\n' >"$local_package_verified_work/build-count"
if (
  # shellcheck disable=SC1090
  source "$local_package_installer"
  repo_root=$local_package_verified_work
  # shellcheck disable=SC2034 # Consumed by the dynamically sourced helper.
  local_package_build_attempts=1
  # shellcheck disable=SC2034 # Consumed by the dynamically sourced helper.
  local_package_retry_delay_seconds=0
  # shellcheck disable=SC2034 # Consumed by the dynamically sourced helper.
  sudo_command=$local_package_verified_work/sudo-wrapper
  # shellcheck disable=SC2031 # The fake PATH is subshell-local by design.
  PATH="$local_package_verified_work/bin:$PATH"
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  install_verified_local_build_dependencies() { :; }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  verified_local_desired_version() { printf '0.25.0-10\n'; }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  fake_vicinae_sandboxed_makepkg() {
    [[ $4 == prepare ]] && return 0
    makepkg
  }
  # shellcheck disable=SC2329,SC2031 # Indirect call writes the exported event log.
  install_verified_local_archive() {
    printf 'hold\ninstall\n' >>"$VICINAE_TEST_EVENTS"
    # shellcheck disable=SC2034 # Read by the sourced production helper.
    verified_local_install_attempted=true
    # shellcheck disable=SC2034 # Read by the sourced production helper.
    verified_local_staged_archive=$VICINAE_TEST_ARCHIVE
  }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  enforce_verified_local_installed_safety() { :; }
  # shellcheck disable=SC2329 # Invoked indirectly by the sourced production helper.
  record_verified_local_install_attestation() { :; }
  # shellcheck disable=SC2031 # Values are consumed by fake commands in this subshell.
  export VICINAE_TEST_ARCHIVE=$local_package_verified_work/workspace/packages/vicinae-bin-0.25.0-10-x86_64.pkg.tar.zst
  # shellcheck disable=SC2031 # Values are consumed by fake commands in this subshell.
  export VICINAE_TEST_BUILD_COUNT=$local_package_verified_work/build-count
  # shellcheck disable=SC2031 # Values are consumed by fake commands in this subshell.
  export VICINAE_TEST_EVENTS=$local_package_verified_work/events
  export VICINAE_TEST_VERIFY_STATUS=1
  build_verified_local_package \
    vicinae-bin \
    "$local_package_verified_work/package" \
    "$local_package_verified_work/workspace" \
    "$local_package_verified_work" \
    fake_vicinae_sandboxed_makepkg
) >/dev/null 2>&1; then
  fail 'verified Vicinae build accepted a rejected package archive'
fi
if grep -Fxq install "$local_package_verified_work/events"; then
  fail 'Vicinae archive verification failure still reached pacman'
fi
grep -Fxq verify "$local_package_verified_work/events" ||
  fail 'Vicinae negative archive test did not reach the verifier'

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
