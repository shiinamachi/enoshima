#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
inventory="$repo_root/ansible/inventory/hosts.yml"
profile=${PROFILE:-}
conflict_policy=${CONFLICT_POLICY:-}
skip_local=${SKIP_LOCAL:-false}
skip_aur=${SKIP_AUR:-false}
skip_codex_desktop=${SKIP_CODEX_DESKTOP:-false}
apply_boot_artifacts=${APPLY_BOOT_ARTIFACTS:-false}
bootstrap_report_dir=${REPORT_DIR:-}
bootstrap_report_format=${REPORT_FORMAT:-text}
bootstrap_report_state_file=
bootstrap_last_step_status=0
sudo_keepalive_pid=
runtime_dir=
dotfile_preflight_complete=false
full_upgrade_complete=false
user_configuration_complete=false
vicinae_policy_transition_complete=false
vicinae_full_upgrade_hook_dir=
mise_config_source="$repo_root/home/dot_config/mise/config.toml"
mise_command=/usr/bin/mise
pacman_query_command=/usr/bin/pacman
vicinae_reviewed_guard_sha256=952bbd60b19af764d06fcc9833169b9b9f0e671c791b1b12d36ca3a27c2504c9
# shellcheck source=scripts/lib/bootstrap-failures.sh
source "$repo_root/scripts/lib/bootstrap-failures.sh"
# shellcheck source=scripts/lib/vicinae-service-policy.sh
source "$repo_root/scripts/lib/vicinae-service-policy.sh"

# Bootstrap is intentionally non-interactive after the explicit conflict-policy
# and sudo gates.  Do not let package helpers, Git, or systemd inherit a desktop
# editor or an interactive pager from the user's login shell.  An unexpected
# editor request fails visibly instead of silently accepting unreviewed input.
export EDITOR=/usr/bin/false
export VISUAL=/usr/bin/false
export GIT_EDITOR=/usr/bin/false
export GIT_SEQUENCE_EDITOR=/usr/bin/false
export GIT_MERGE_AUTOEDIT=no
export SYSTEMD_EDITOR=/usr/bin/false
export SUDO_EDITOR=/usr/bin/false
export PAGER=/usr/bin/cat
export GIT_PAGER=/usr/bin/cat
export SYSTEMD_PAGER=/usr/bin/cat
export MANPAGER=/usr/bin/cat
export BAT_PAGER=/usr/bin/cat
export PARU_PAGER=/usr/bin/cat
export GIT_TERMINAL_PROMPT=0

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [PROFILE] [OPTIONS]

Converge a new or existing Arch Linux installation to this repository.

Options:
  --profile HOST                Select an Ansible inventory host.
  --inventory PATH              Use an alternate Ansible inventory file or directory.
  --conflict-policy POLICY      User-file policy: backup, overwrite, keep, abort.
  --apply-boot-artifacts        Rebuild boot artifacts when managed boot files change.
  --report-dir PATH             Write per-stage logs and a machine-readable summary.
  --report-format text|json     Select the summary format (default: text).
  -h, --help                    Show this help.

Environment equivalents:
  PROFILE, CONFLICT_POLICY, APPLY_BOOT_ARTIFACTS, REPORT_DIR, REPORT_FORMAT,
  SKIP_LOCAL, SKIP_AUR, SKIP_CODEX_DESKTOP, MISE_INSTALL_MAX_ATTEMPTS,
  MISE_INSTALL_RETRY_DELAY_SECONDS, MISE_INSTALL_TIMEOUT_SECONDS
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

refresh_sudo_credentials() {
  if /usr/bin/sudo -n -v >/dev/null 2>&1; then
    return
  fi

  echo "Error: the run-wide sudo credential is no longer available" >&2
  return 1
}

hyprpm_state() {
  LC_ALL=C hyprpm list 2>/dev/null |
    sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

hyprpm_repository_installed() {
  hyprpm_state | grep -Fq 'Repository hyprland-plugins '
}

hyprpm_plugin_enabled() {
  local plugin=$1
  hyprpm_state | awk -v plugin="$plugin" '
    index($0, "Plugin " plugin) > 0 { found = 1; next }
    found && index($0, "enabled:") > 0 {
      enabled = ($NF == "true")
      exit
    }
    END { exit !(found && enabled) }
  '
}

run_hyprpm_state_command() {
  if "$@"; then
    return
  fi

  # hyprpm changes its persistent state before attempting to contact the
  # compositor. A TTY/bootstrap run has no instance socket, so verify the
  # resulting cache and flags below instead of treating that deferred reload
  # as a build failure.
  if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    echo "==> Hyprland is not running; plugin load is deferred until login"
    return
  fi

  return 1
}

run_with_bounded_retries() {
  local label=$1 max_attempts=$2 retry_delay_seconds=$3
  local attempt status
  shift 3

  [[ $max_attempts =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: $label retry attempts must be a positive integer" >&2
    return 2
  }
  [[ $retry_delay_seconds =~ ^[0-9]+$ ]] || {
    echo "Error: $label retry delay must be zero or a positive integer" >&2
    return 2
  }

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    # Keep an attempt in a subshell so a command's die/exit only terminates
    # that attempt. This lets a transient DNS or transport failure recover
    # without weakening the final bounded failure.
    if ("$@"); then
      return 0
    else
      status=$?
    fi

    if ((attempt == max_attempts)); then
      printf 'Error: %s exhausted %d attempts (last status: %d)\n' \
        "$label" "$max_attempts" "$status" >&2
      return "$status"
    fi

    printf 'WARNING: %s attempt %d/%d failed; retrying in %ss.\n' \
      "$label" "$attempt" "$max_attempts" "$retry_delay_seconds" >&2
    sleep "$retry_delay_seconds"
  done
}

converge_hyprland_plugins() {
  local cache_root
  local official_repo=https://github.com/hyprwm/hyprland-plugins
  local installed_abi cached_abi

  cache_root=/var/cache/hyprpm/$(id -un)

  command -v hyprpm >/dev/null 2>&1 || die 'hyprpm is unavailable after installing Hyprland'

  if hyprpm_repository_installed; then
    # Prevent update from loading the retired titlebar plugin into a live
    # session before the desired plugin state is applied.
    run_hyprpm_state_command hyprpm disable hyprbars || true
    run_hyprpm_state_command hyprpm update
  else
    # A first add requires headers in hyprpm's global state. The official
    # repository prompt accepts an empty response as confirmation; feed that
    # reviewed answer so bootstrap remains one-shot and non-interactive.
    run_hyprpm_state_command hyprpm update
    [[ -f $cache_root/headersRoot/share/pkgconfig/hyprland.pc ]] ||
      die 'hyprpm did not install matching Hyprland headers'
    if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
      printf '\n' | hyprpm add "$official_repo"
    else
      # hyprpm 0.55 resolves commit pins through the live j/version IPC even
      # though the repository build itself is safe before login. Supply that
      # single response from the installed binary so first bootstrap remains
      # one-shot without starting a second compositor or weakening libseat.
      printf '\n' | "$repo_root/scripts/lib/hyprpm-version-socket" \
        hyprpm add "$official_repo"
    fi
  fi

  installed_abi=$(Hyprland --version | sed -n 's/^Version ABI string: //p')
  cached_abi=$(awk -F "'" '$1 ~ /^[[:space:]]*hash = / { print $2; exit }' \
    "$cache_root/state.toml")
  [[ -n $installed_abi && $cached_abi == "$installed_abi" ]] ||
    die 'hyprpm plugin cache does not match the installed Hyprland ABI'
  [[ -f $cache_root/hyprland-plugins/hyprfocus.so ]] ||
    die 'hyprpm did not build the official hyprfocus plugin'

  local decoration_config=$repo_root/home/dot_config/enoshima/window-interaction.yaml
  local decoration_enabled decoration_source decoration_root decoration_target decoration_state
  decoration_enabled=$(yq -r '.decoration.enabled // false' "$decoration_config")
  if [[ $decoration_enabled == true ]]; then
    decoration_source=$repo_root/native/enoshima-decoration
    decoration_root=${XDG_DATA_HOME:-$HOME/.local/share}/enoshima/plugins/$installed_abi
    decoration_target=$decoration_root/enoshima-decoration.so
    decoration_state=${XDG_STATE_HOME:-$HOME/.local/state}/enoshima-decoration
    make -B -C "$decoration_source" all
    install -Dm 0755 "$decoration_source/enoshima-decoration.so" "$decoration_target"
    install -d -m 0700 "$decoration_state"
    printf '%s\n' "$installed_abi" >"$decoration_state/hyprland-abi"
    chmod 0600 "$decoration_state/hyprland-abi"
    make -C "$decoration_source" clean
  fi

  run_hyprpm_state_command hyprpm disable hyprbars || true
  run_hyprpm_state_command hyprpm enable hyprfocus || true

  if hyprpm_plugin_enabled hyprbars; then
    die 'hyprbars remains enabled after plugin convergence'
  fi
  hyprpm_plugin_enabled hyprfocus ||
    die 'hyprfocus is not enabled after plugin convergence'

  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprpm reload
    if [[ $decoration_enabled == true ]]; then
      "$HOME/.local/bin/enoshima-decoration-load"
    else
      hyprctl reload config-only
    fi
  fi
}

validate_repository() {
  case $profile in
    enoshima-vm | enoshima-vm-boot)
      # The host already runs the VM harness unit suite before launching either
      # disposable guest profile. Uploaded guest sources intentionally omit Git
      # metadata, so repeating host-only selector tests there is also invalid.
      ENOSHIMA_SKIP_VM_HARNESS_CHECKS=true "$repo_root/scripts/validate.sh"
      ;;
    *)
      "$repo_root/scripts/validate.sh"
      ;;
  esac
}

install_bootstrap_dependencies() {
  local attempt pacman_status
  local max_attempts=${BOOTSTRAP_PACKAGE_MAX_ATTEMPTS:-4}
  local retry_delay_seconds=${BOOTSTRAP_PACKAGE_RETRY_DELAY_SECONDS:-10}
  local -a hook_args=()

  [[ $max_attempts =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: BOOTSTRAP_PACKAGE_MAX_ATTEMPTS must be a positive integer" >&2
    return 1
  }
  [[ $retry_delay_seconds =~ ^[0-9]+$ ]] || {
    echo "Error: BOOTSTRAP_PACKAGE_RETRY_DELAY_SECONDS must be a non-negative integer" >&2
    return 1
  }

  if [[ -n ${vicinae_full_upgrade_hook_dir:-} ]]; then
    hook_args=(--hookdir "$vicinae_full_upgrade_hook_dir")
  fi

  # Bootstrap must use the machine's current, valid pacman configuration.
  # The Ansible template is rendered only after Ansible is available; passing
  # that Jinja source directly to pacman breaks profile-specific values and
  # discards the VM snapshot archive's download policy.
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if "$SUDO_COMMAND_WRAPPER" /usr/bin/pacman "${hook_args[@]}" \
      --ignore hyprshell-bin --ignore vicinae-bin \
      -Syu --needed --noconfirm \
      ansible-core \
      base-devel \
      bubblewrap \
      chezmoi \
      git \
      gtk4 \
      hyprland \
      imagemagick \
      jq \
      json-glib \
      librsvg \
      lua \
      mise \
      ripgrep \
      rustup \
      yq; then
      pacman_status=0
    else
      pacman_status=$?
    fi
    enforce_protected_package_safety_after_upgrade || return 70
    if ((pacman_status == 70)); then
      return 70
    fi
    ((pacman_status != 0)) || return 0

    if ((attempt < max_attempts)); then
      printf \
        'WARNING: bootstrap package upgrade attempt %d/%d failed; retrying in %ss.\n' \
        "$attempt" "$max_attempts" "$retry_delay_seconds" >&2
      sleep "$retry_delay_seconds"
    fi
  done

  echo "Error: bootstrap package upgrade exhausted its retry budget" >&2
  return 1
}

bootstrap_root_owned_ancestor_safe() {
  local path=$1 uid gid mode

  [[ -d $path && ! -L $path ]] || return 1
  read -r uid gid mode < <(/usr/bin/stat -c '%u %g %a' -- "$path") || return 1
  [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  (((8#$mode & 8#022) == 0))
}

prepare_verified_full_upgrade_runtime_root() {
  local stage_root=/run/enoshima-vicinae-reviewed

  bootstrap_root_owned_ancestor_safe / || return 70
  bootstrap_root_owned_ancestor_safe /run || return 70
  if [[ -e $stage_root || -L $stage_root ]]; then
    [[ -d $stage_root && ! -L $stage_root &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$stage_root") == root:root:711 ]] ||
      return 70
  else
    "$SUDO_COMMAND_WRAPPER" /usr/bin/install -d -o root -g root -m 0711 -- \
      "$stage_root" || return 70
  fi
  [[ -d $stage_root && ! -L $stage_root &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$stage_root") == root:root:711 ]] ||
    return 70
}

prepare_verified_full_upgrade_hook_dir() {
  local stage_root=/run/enoshima-vicinae-reviewed

  [[ -z ${vicinae_full_upgrade_hook_dir:-} ]] || return 0
  prepare_verified_full_upgrade_runtime_root || return 70
  vicinae_full_upgrade_hook_dir=$(
    "$SUDO_COMMAND_WRAPPER" /usr/bin/mktemp -d \
      --tmpdir="$stage_root" hooks.XXXXXXXX
  ) || return 70
  [[ ${vicinae_full_upgrade_hook_dir%/*} == "$stage_root" &&
    ${vicinae_full_upgrade_hook_dir##*/} == hooks.* ]] || return 70
  "$SUDO_COMMAND_WRAPPER" /usr/bin/chown root:root "$vicinae_full_upgrade_hook_dir" ||
    return 70
  "$SUDO_COMMAND_WRAPPER" /usr/bin/chmod 0700 "$vicinae_full_upgrade_hook_dir" ||
    return 70
  [[ -d $vicinae_full_upgrade_hook_dir && ! -L $vicinae_full_upgrade_hook_dir &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$vicinae_full_upgrade_hook_dir") == root:root:700 ]] ||
    return 70
}

enforce_protected_package_safety_after_upgrade() {
  local package_name installed_name installed_version extra status

  for package_name in hyprshell-bin vicinae-bin; do
    if ! read -r installed_name installed_version extra < <(
      "$pacman_query_command" -Q -- "$package_name" 2>/dev/null
    ); then
      continue
    fi
    [[ $installed_name == "$package_name" && -n $installed_version && -z $extra ]] ||
      return 70
    if "$repo_root/scripts/lib/aur-provenance" enforce-installed-safety \
      --package "$package_name" \
      --version "$installed_version" \
      --sudo-command "$SUDO_COMMAND_WRAPPER"; then
      continue
    else
      status=$?
    fi
    printf 'Error: installed safety failed after the full upgrade for %s (status %d).\n' \
      "$package_name" "$status" >&2 || true
    return 70
  done
}

prepare_hyprshell_hooks_for_initial_full_upgrade() {
  local package_name=hyprshell-bin
  local hook_dir
  local owned_paths owned_path hook_name hook_target hook_owner
  local -a hook_names=()

  "$pacman_query_command" -Q -- "$package_name" >/dev/null 2>&1 || return 0
  owned_paths=$("$pacman_query_command" -Qlq -- "$package_name") || return 70
  while IFS= read -r owned_path; do
    [[ $owned_path == *.hook ]] || continue
    hook_name=${owned_path##*/}
    [[ $hook_name =~ ^[A-Za-z0-9._+-]+\.hook$ ]] || return 70
    [[ $owned_path == /* && $owned_path != *'//'* &&
      $owned_path != *'/./'* && $owned_path != *'/../'* ]] || return 70
    hook_names+=("$hook_name")
  done <<<"$owned_paths"
  ((${#hook_names[@]} > 0)) || return 0
  mapfile -t hook_names < <(printf '%s\n' "${hook_names[@]}" | LC_ALL=C sort -u)
  prepare_verified_full_upgrade_hook_dir || return 70
  hook_dir=$vicinae_full_upgrade_hook_dir
  for hook_name in "${hook_names[@]}"; do
    "$SUDO_COMMAND_WRAPPER" /usr/bin/ln -s -- /dev/null "$hook_dir/$hook_name" ||
      return 70
    "$SUDO_COMMAND_WRAPPER" /usr/bin/test -L "$hook_dir/$hook_name" || return 70
    hook_target=$("$SUDO_COMMAND_WRAPPER" /usr/bin/readlink -- \
      "$hook_dir/$hook_name") || return 70
    hook_owner=$("$SUDO_COMMAND_WRAPPER" /usr/bin/stat -c '%U:%G' -- \
      "$hook_dir/$hook_name") || return 70
    [[ $hook_target == /dev/null && $hook_owner == root:root ]] ||
      return 70
  done
  vicinae_full_upgrade_hook_dir=$hook_dir
}

prepare_vicinae_for_initial_full_upgrade() {
  prepare_vicinae_for_initial_full_upgrade_impl \
    "$repo_root/packages/local/vicinae-bin/vicinae-qt-guard"
}

prepare_vicinae_for_initial_full_upgrade_impl() {
  local guard=$1
  local reviewed_stage=${2:-/run/enoshima-vicinae-reviewed/vicinae-qt-guard}
  local hook_dir
  local hook_path hook_name owned_paths hook_target hook_owner
  local -a expected_hook_names=(
    40-vicinae-qt-pre.hook
    40-vicinae-qt-post.hook
    41-vicinae-package-pre.hook
    vicinae.hook
  )

  if [[ $reviewed_stage == /run/enoshima-vicinae-reviewed/vicinae-qt-guard ]]; then
    prepare_verified_full_upgrade_hook_dir || return 70
    hook_dir=$vicinae_full_upgrade_hook_dir
  else
    hook_dir=${reviewed_stage%/*}/hooks
  fi
  [[ -f $guard && ! -L $guard ]] ||
    die 'the reviewed Vicinae Qt guard is missing'
  [[ $(sha256sum -- "$guard" | awk '{ print $1 }') == "$vicinae_reviewed_guard_sha256" ]] ||
    die 'the reviewed Vicinae Qt guard checksum changed'

  owned_paths=
  if "$pacman_query_command" -Q vicinae-bin >/dev/null 2>&1; then
    owned_paths=$("$pacman_query_command" -Qlq vicinae-bin) || return 70
  fi

  # Hash and execute the same root-owned bytes. The repository copy is
  # user-writable, so executing it after a digest check would leave a TOCTOU
  # window at this privileged migration gate.
  if [[ $reviewed_stage != /run/enoshima-vicinae-reviewed/vicinae-qt-guard ]]; then
    "$SUDO_COMMAND_WRAPPER" /usr/bin/install -d -o root -g root -m 0711 -- \
      "${reviewed_stage%/*}" || return 70
  fi
  if [[ -e $reviewed_stage || -L $reviewed_stage ]]; then
    [[ -f $reviewed_stage && ! -L $reviewed_stage &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$reviewed_stage") == root:root:755 ]] ||
      return 70
  fi
  [[ -f $guard && ! -L $guard ]] ||
    die 'the reviewed Vicinae Qt guard changed before staging'
  if ! "$SUDO_COMMAND_WRAPPER" /usr/bin/tee "$reviewed_stage" \
    <"$guard" >/dev/null; then
    die 'the reviewed Vicinae Qt guard could not be staged'
  fi
  "$SUDO_COMMAND_WRAPPER" /usr/bin/chown root:root "$reviewed_stage" || return 70
  "$SUDO_COMMAND_WRAPPER" /usr/bin/chmod 0755 "$reviewed_stage" || return 70
  [[ -f $reviewed_stage && ! -L $reviewed_stage &&
    $(/usr/bin/stat -c '%U:%G:%a' "$reviewed_stage") == root:root:755 &&
    $(/usr/bin/sha256sum -- "$reviewed_stage" | awk '{ print $1 }') == "$vicinae_reviewed_guard_sha256" ]] ||
    die 'the staged Vicinae Qt guard is unsafe or changed'

  "$SUDO_COMMAND_WRAPPER" /usr/bin/install -d -o root -g root -m 0700 -- "$hook_dir" ||
    return 70
  [[ -d $hook_dir && ! -L $hook_dir &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$hook_dir") == root:root:700 ]] ||
    return 70
  while IFS= read -r hook_path; do
    [[ $hook_path == *.hook ]] || continue
    hook_name=${hook_path##*/}
    [[ $hook_name =~ ^[A-Za-z0-9._+-]+\.hook$ ]] || return 70
    [[ $hook_path == /* && $hook_path != *'//'* &&
      $hook_path != *'/./'* && $hook_path != *'/../'* ]] || return 70
    "$SUDO_COMMAND_WRAPPER" /usr/bin/ln -sfn -- /dev/null "$hook_dir/$hook_name" ||
      return 70
    "$SUDO_COMMAND_WRAPPER" /usr/bin/test -L "$hook_dir/$hook_name" || return 70
    hook_target=$("$SUDO_COMMAND_WRAPPER" /usr/bin/readlink -- \
      "$hook_dir/$hook_name") || return 70
    hook_owner=$("$SUDO_COMMAND_WRAPPER" /usr/bin/stat -c '%U:%G' -- \
      "$hook_dir/$hook_name") || return 70
    [[ $hook_target == /dev/null && $hook_owner == root:root ]] ||
      return 70
  done <<<"$owned_paths"
  for hook_name in "${expected_hook_names[@]}"; do
    "$SUDO_COMMAND_WRAPPER" /usr/bin/ln -sfn -- /dev/null "$hook_dir/$hook_name" ||
      return 70
  done
  for hook_name in "${expected_hook_names[@]}"; do
    "$SUDO_COMMAND_WRAPPER" /usr/bin/test -L "$hook_dir/$hook_name" || return 70
    hook_target=$("$SUDO_COMMAND_WRAPPER" /usr/bin/readlink -- \
      "$hook_dir/$hook_name") || return 70
    hook_owner=$("$SUDO_COMMAND_WRAPPER" /usr/bin/stat -c '%U:%G' -- \
      "$hook_dir/$hook_name") || return 70
    [[ $hook_target == /dev/null && $hook_owner == root:root ]] ||
      return 70
  done
  vicinae_full_upgrade_hook_dir=$hook_dir
  # The reviewed guard is staged before the first full upgrade and remains
  # held until bootstrap has deployed and validated the current user's policy.
  "$SUDO_COMMAND_WRAPPER" "$reviewed_stage" hold
}

prepare_vicinae_and_install_bootstrap_dependencies() {
  prepare_hyprshell_hooks_for_initial_full_upgrade || return
  prepare_vicinae_for_initial_full_upgrade || return
  install_bootstrap_dependencies
}

bootstrap_run_after_full_upgrade() {
  local label=$1
  shift

  if [[ $full_upgrade_complete != true ]]; then
    printf \
      'SKIP: %s because the initial full Arch upgrade did not complete successfully.\n' \
      "$label" >&2
    return 0
  fi
  bootstrap_run_step "$label" "$@"
}

install_ansible_collection() {
  ansible-galaxy collection install \
    --requirements-file "$repo_root/ansible/collections/requirements.yml"
}

install_mise_runtimes_once() {
  local timeout_seconds=${MISE_INSTALL_TIMEOUT_SECONDS:-600}
  local isolated_config_dir status=0

  [[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: MISE_INSTALL_TIMEOUT_SECONDS must be a positive integer" >&2
    return 2
  }
  isolated_config_dir=$(mktemp -d) || return 1
  if MISE_CONFIG_DIR="$isolated_config_dir" \
    MISE_CONFIG_FILE="$mise_config_source" timeout \
    --signal=TERM \
    --kill-after=30s \
    "${timeout_seconds}s" \
    "$mise_command" -C "$isolated_config_dir" install --yes; then
    status=0
  else
    status=$?
  fi
  rmdir -- "$isolated_config_dir" || {
    ((status != 0)) && return "$status"
    return 1
  }
  return "$status"
}

install_mise_runtimes() {
  run_with_bounded_retries \
    "mise runtime installation" \
    "${MISE_INSTALL_MAX_ATTEMPTS:-4}" \
    "${MISE_INSTALL_RETRY_DELAY_SECONDS:-10}" \
    install_mise_runtimes_once
}

install_local_packages() {
  local rust_toolchain rustc_path rust_toolchain_root rustup_home mise_config_dir
  local account_home account_user

  rust_toolchain=$(
    /usr/bin/python - "$mise_config_source" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    value = tomllib.load(handle)["tools"]["rust"]
print(value["version"] if isinstance(value, dict) else value)
PY
  ) || return 1
  if [[ ! $rust_toolchain =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: mise did not resolve the managed Rust toolchain" >&2
    return 1
  fi
  account_user=$(id -un) || return 1
  account_home=$(getent passwd "$EUID" | awk -F: 'NF == 7 { print $6; exit }') ||
    return 1
  [[ $account_home == /* && $account_home != / && $HOME == "$account_home" ]] || {
    echo 'Error: HOME does not match the invoking account home directory' >&2
    return 1
  }
  mise_config_dir=$(mktemp -d) || return 1
  rustc_path=$(
    /usr/bin/env -i \
      HOME="$account_home" USER="$account_user" LOGNAME="$account_user" \
      PATH=/usr/bin:/bin LANG=C.UTF-8 \
      MISE_CONFIG_DIR="$mise_config_dir" \
      MISE_CONFIG_FILE="$mise_config_source" \
      "$mise_command" -C "$mise_config_dir" \
      exec --fresh-env "rust@$rust_toolchain" -- \
      /usr/bin/rustup which rustc
  ) || {
    rmdir -- "$mise_config_dir" || true
    echo "Error: mise did not resolve the managed Rust compiler" >&2
    return 1
  }
  rmdir -- "$mise_config_dir" || return 1
  rustc_path=$(readlink -f -- "$rustc_path") || return 1
  rustup_home=${rustc_path%%/toolchains/*}
  rust_toolchain_root=${rustc_path%/bin/rustc}
  [[ $rustup_home == "$account_home/.rustup" && ! -L $rustup_home &&
    $rust_toolchain_root == "$rustup_home/toolchains/$rust_toolchain-x86_64-unknown-linux-gnu" &&
    $rustc_path == "$rust_toolchain_root/bin/rustc" &&
    -x $rustc_path && ! -L $rustc_path ]] || {
    echo "Error: mise resolved an unsafe Rust compiler path" >&2
    return 1
  }

  # Keep Arch's /usr/bin/python ahead of the global mise Python here: local
  # PKGBUILDs consume pacman-provided Python build modules. Select only the
  # Rust toolchain through rustup's standard environment contract.
  refresh_sudo_credentials
  PATH="/usr/bin:/bin:$PATH" \
    RUSTUP_TOOLCHAIN="$rust_toolchain" \
    LOCAL_PACKAGE_RUST_TOOLCHAIN_ROOT="$rust_toolchain_root" \
    VICINAE_KEEP_HELD=true \
    "$repo_root/scripts/install-local-packages.sh"
}

install_codex_desktop() {
  refresh_sudo_credentials
  "$repo_root/scripts/install-codex-desktop.sh"
}

apply_ansible_desired_state() {
  refresh_sudo_credentials
  # Ansible Core 2.21 isolates workers with setsid() by default. Keep workers
  # in this terminal session so sudo's TTY-scoped timestamp remains available.
  ANSIBLE_BECOME_ASK_PASS=false \
    ANSIBLE_WORKER_SESSION_ISOLATION=false \
    ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
    ansible-playbook \
    --inventory "$inventory" \
    "$repo_root/ansible/site.yml" \
    --limit "$profile" \
    --extra-vars "ansible_become_exe=$SUDO_COMMAND_WRAPPER perform_full_upgrade=false apply_boot_artifacts=$apply_boot_artifacts"
}

apply_desktop_expansion() {
  refresh_sudo_credentials
  # This second convergence needs the same TTY-scoped sudo credential behavior.
  ANSIBLE_BECOME_ASK_PASS=false \
    ANSIBLE_WORKER_SESSION_ISOLATION=false \
    ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
    ansible-playbook \
    --inventory "$inventory" \
    "$repo_root/ansible/site.yml" \
    --limit "$profile" \
    --tags desktop-expansion \
    --extra-vars "ansible_become_exe=$SUDO_COMMAND_WRAPPER perform_full_upgrade=false apply_boot_artifacts=$apply_boot_artifacts"
}

apply_user_configuration() {
  "$repo_root/scripts/apply-dotfiles.sh" --apply "$conflict_policy"
  echo "==> Cyberpunk Library session theme applied; SDDM selection remains acceptance-gated"
}

prepare_vicinae_for_user_policy() {
  local guard masked_state active_state

  pacman -Q vicinae-bin >/dev/null 2>&1 || {
    echo 'Error: Vicinae is unavailable; its user service remains fail-closed' >&2
    return 1
  }
  refresh_sudo_credentials
  guard=$(stage_reviewed_vicinae_guard) || return 1
  "$SUDO_COMMAND_WRAPPER" "$guard" hold || return 1
  timeout --signal=TERM --kill-after=2s 20s \
    systemctl --user mask --now vicinae.service || return 1
  masked_state=$(timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user is-enabled vicinae.service 2>/dev/null || true)
  active_state=$(timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user show vicinae.service -P ActiveState) || return 1
  [[ $masked_state =~ ^masked(-runtime)?$ &&
    $active_state =~ ^(inactive|failed)$ ]]
}

stage_reviewed_vicinae_guard() {
  local source=${1:-$repo_root/packages/local/vicinae-bin/vicinae-qt-guard}
  local stage_dir=/run/enoshima-vicinae-reviewed
  local staged=${2:-$stage_dir/vicinae-qt-guard}
  local actual

  [[ -f $source && ! -L $source ]] || return 1
  prepare_verified_full_upgrade_runtime_root || return 70
  if [[ -e $staged || -L $staged ]]; then
    [[ -f $staged && ! -L $staged &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$staged") == root:root:755 ]] ||
      return 70
  fi
  [[ -f $source && ! -L $source ]] || return 1
  "$SUDO_COMMAND_WRAPPER" /usr/bin/tee "$staged" <"$source" >/dev/null ||
    return 1
  "$SUDO_COMMAND_WRAPPER" /usr/bin/chown root:root "$staged" || return 1
  "$SUDO_COMMAND_WRAPPER" /usr/bin/chmod 0755 "$staged" || return 1
  [[ -f $staged && ! -L $staged &&
    $(/usr/bin/stat -c '%U:%G:%a' "$staged") == root:root:755 ]] || return 1
  actual=$(/usr/bin/sha256sum -- "$staged") || return 1
  [[ ${actual%% *} == "$vicinae_reviewed_guard_sha256" ]] || return 1
  printf '%s\n' "$staged"
}

trusted_vicinae_runtime_helpers() {
  local guard=/usr/libexec/vicinae/vicinae-qt-guard
  local compatibility=/usr/libexec/vicinae/vicinae-build-compatible
  local expected_guard expected_compatibility
  local actual_guard actual_compatibility

  expected_guard=$(sha256sum -- \
    "$repo_root/packages/local/vicinae-bin/vicinae-qt-guard") || return
  expected_guard=${expected_guard%% *}
  expected_compatibility=$(sha256sum -- \
    "$repo_root/packages/local/vicinae-bin/vicinae-build-compatible") || return
  expected_compatibility=${expected_compatibility%% *}
  [[ -f $guard && ! -L $guard &&
    -f $compatibility && ! -L $compatibility &&
    $(stat -c '%U:%G:%a' "$guard") == root:root:755 &&
    $(stat -c '%U:%G:%a' "$compatibility") == root:root:755 ]] || {
    echo 'Error: installed Vicinae guard helpers are missing or unsafe' >&2
    return 1
  }
  actual_guard=$(sha256sum -- "$guard") || return
  actual_guard=${actual_guard%% *}
  actual_compatibility=$(sha256sum -- "$compatibility") || return
  actual_compatibility=${actual_compatibility%% *}
  [[ $actual_guard == "$expected_guard" &&
    $actual_compatibility == "$expected_compatibility" ]] || {
    echo 'Error: installed Vicinae guard helpers do not match the reviewed package' >&2
    return 1
  }
}

vicinae_unit_search_path_clean() (
  local expected_user_mask=${1:-masked}
  local uid unit_path root main dropin_dir entry
  local user_mask=$HOME/.config/systemd/user/vicinae.service
  local global_mask=/run/systemd/user/vicinae.service
  local package_unit=/usr/lib/systemd/user/vicinae.service
  local user_dropin=$HOME/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf
  local package_dropin=/usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf
  local saw_user_mask=false saw_global_mask=false saw_package_unit=false
  local saw_user_dropin=false saw_package_dropin=false
  local -a roots=()
  local -A seen_roots=()

  [[ $expected_user_mask =~ ^(masked|unmasked)$ ]] || return 1
  uid=$(id -u) || return 1
  unit_path=$(timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user show --no-pager -P UnitPath) || return 1
  [[ -n $unit_path && $unit_path != *$'\n'* ]] || return 1
  read -r -a roots <<<"$unit_path"
  ((${#roots[@]} > 0)) || return 1

  for root in "${roots[@]}"; do
    [[ $root =~ ^/[A-Za-z0-9._@+/-]+$ &&
      $root != *'//'* && $root != *'/./'* && $root != *'/../'* &&
      $root != */. && $root != */.. && ! -v seen_roots["$root"] ]] ||
      return 1
    seen_roots["$root"]=1
    [[ -e $root || -L $root ]] || continue
    [[ -d $root && ! -L $root ]] || return 1

    main=$root/vicinae.service
    if [[ -e $main || -L $main ]]; then
      case $main in
        "$user_mask")
          [[ $expected_user_mask == masked && -L $main &&
            $(readlink -- "$main") == /dev/null &&
            $(stat -c '%u' -- "$main") == "$uid" ]] || return 1
          saw_user_mask=true
          ;;
        "$global_mask")
          [[ -L $main && $(readlink -- "$main") == /dev/null &&
          $(stat -c '%U:%G' -- "$main") == root:root ]] || return 1
          saw_global_mask=true
          ;;
        "$package_unit")
          [[ -f $main && ! -L $main &&
            $(stat -c '%U:%G:%a' -- "$main") == root:root:644 ]] || return 1
          saw_package_unit=true
          ;;
        *) return 1 ;;
      esac
    fi

    for dropin_dir in "$root/vicinae.service.d" "$root/service.d"; do
      [[ -e $dropin_dir || -L $dropin_dir ]] || continue
      [[ -d $dropin_dir && ! -L $dropin_dir ]] || return 1
      for entry in \
        "$dropin_dir"/* \
        "$dropin_dir"/.[!.]* \
        "$dropin_dir"/..?*; do
        [[ -e $entry || -L $entry ]] || continue
        case $entry in
          "$user_dropin")
            [[ -f $entry && ! -L $entry &&
              $(stat -c '%u:%a' -- "$entry") == "$uid:644" ]] || return 1
            saw_user_dropin=true
            ;;
          "$package_dropin")
            [[ -f $entry && ! -L $entry &&
              $(stat -c '%U:%G:%a' -- "$entry") == root:root:644 ]] || return 1
            saw_package_dropin=true
            ;;
          *) return 1 ;;
        esac
      done
    done
  done

  [[ $saw_global_mask == true && $saw_package_unit == true &&
    $saw_user_dropin == true && $saw_package_dropin == true ]] || return 1
  if [[ $expected_user_mask == masked ]]; then
    [[ $saw_user_mask == true ]]
  else
    [[ $saw_user_mask == false ]]
  fi
)

vicinae_installed_abi_compatible() {
  trusted_vicinae_runtime_helpers &&
    timeout --signal=TERM --kill-after=2s 60s \
      /usr/libexec/vicinae/vicinae-build-compatible
}

vicinae_user_policy_files_valid() {
  local uid

  uid=$(id -u) || return 1
  [[ -f /usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf &&
    ! -L /usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf &&
    $(stat -c '%U:%G:%a' \
      /usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf) == root:root:644 ]] || return 1
  cmp -- "$repo_root/packages/local/vicinae-bin/20-enoshima-qt-compatibility.conf" \
    /usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf ||
    return 1
  [[ -f $HOME/.config/vicinae/settings.json &&
    ! -L $HOME/.config/vicinae/settings.json &&
    $(stat -c '%u:%a' "$HOME/.config/vicinae/settings.json") == "$uid:644" &&
    -f $HOME/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf &&
    ! -L $HOME/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf &&
    $(stat -c '%u:%a' \
      "$HOME/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf") == "$uid:644" &&
    -f $HOME/.local/libexec/vicinae-keyring-ready &&
    ! -L $HOME/.local/libexec/vicinae-keyring-ready &&
    $(stat -c '%u:%a' "$HOME/.local/libexec/vicinae-keyring-ready") == "$uid:755" &&
    -f $HOME/.local/libexec/vicinae-server-ready &&
    ! -L $HOME/.local/libexec/vicinae-server-ready &&
    $(stat -c '%u:%a' "$HOME/.local/libexec/vicinae-server-ready") == "$uid:755" ]] || return 1
  cmp -- "$repo_root/home/dot_config/vicinae/settings.json" \
    "$HOME/.config/vicinae/settings.json" &&
    cmp -- \
      "$repo_root/home/dot_config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf" \
      "$HOME/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf" &&
    cmp -- "$repo_root/home/dot_local/libexec/executable_vicinae-keyring-ready" \
      "$HOME/.local/libexec/vicinae-keyring-ready" &&
    cmp -- "$repo_root/home/dot_local/libexec/executable_vicinae-server-ready" \
      "$HOME/.local/libexec/vicinae-server-ready"
}

vicinae_service_properties() {
  timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user show vicinae.service --no-pager \
    --property=Environment \
    --property=EnvironmentFiles \
    --property=UnsetEnvironment \
    --property=ExecCondition \
    --property=ExecStart \
    --property=ExecStartPre \
    --property=ExecStartPost \
    --property=ExecReload \
    --property=ExecStop \
    --property=ExecStopPost \
    --property=ExecSearchPath \
    --property=FragmentPath \
    --property=DropInPaths \
    --property=KillMode \
    --property=Restart \
    --property=RestartUSec \
    --property=TimeoutStartUSec \
    --property=TimeoutStopUSec \
    --property=StartLimitIntervalUSec \
    --property=StartLimitBurst
}

enable_vicinae_after_user_policy_impl() {
  local graphical_state properties enabled_state active_state

  trusted_vicinae_runtime_helpers || return 1
  vicinae_user_policy_files_valid || return 1
  vicinae_unit_search_path_clean masked || return 1
  vicinae_installed_abi_compatible || return 1
  refresh_sudo_credentials
  timeout --signal=TERM --kill-after=2s 20s \
    systemctl --user unmask --runtime vicinae.service || return 1
  timeout --signal=TERM --kill-after=2s 20s \
    systemctl --user unmask vicinae.service || return 1
  timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user daemon-reload || return 1
  vicinae_unit_search_path_clean unmasked || return 1
  "$SUDO_COMMAND_WRAPPER" /usr/libexec/vicinae/vicinae-qt-guard \
    release-if-compatible || return 1
  timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user daemon-reload || return 1
  properties=$(vicinae_service_properties) || return 1
  vicinae_effective_service_policy_valid \
    "$properties" \
    "$HOME/.local/libexec/vicinae-keyring-ready" \
    "$HOME/.local/libexec/vicinae-server-ready" || return 1
  timeout --signal=TERM --kill-after=2s 20s \
    systemctl --user enable vicinae.service || return 1
  graphical_state=$(timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user show graphical-session.target -P ActiveState) || return 1
  case $graphical_state in
    active)
      timeout --signal=TERM --kill-after=5s 45s \
        systemctl --user start vicinae.service || return 1
      ;;
    inactive | failed) ;;
    *) return 1 ;;
  esac
  enabled_state=$(timeout --signal=TERM --kill-after=1s 10s \
    systemctl --user is-enabled vicinae.service) || return 1
  [[ $enabled_state == enabled ]] || return 1
  if [[ $graphical_state == active ]]; then
    active_state=$(timeout --signal=TERM --kill-after=1s 10s \
      systemctl --user show vicinae.service -P ActiveState) || return 1
    [[ $active_state == active ]] || return 1
  fi
}

resume_vicinae_after_user_policy() {
  local status guard

  if enable_vicinae_after_user_policy_impl; then
    return 0
  else
    status=$?
  fi
  timeout --signal=TERM --kill-after=2s 20s \
    systemctl --user mask --now vicinae.service 2>/dev/null || true
  refresh_sudo_credentials
  if guard=$(stage_reviewed_vicinae_guard); then
    "$SUDO_COMMAND_WRAPPER" "$guard" hold || true
  fi
  echo 'Error: Vicinae policy validation failed; the service remains masked and held' >&2
  return "$status"
}

run_integrated_postflight() {
  local -a args=(--profile "$profile" --inventory "$inventory")

  if [[ -n $bootstrap_report_dir && $bootstrap_report_format == json ]]; then
    args+=(--format json --output "$bootstrap_report_dir/postflight.json")
  fi
  "$repo_root/scripts/postflight.sh" "${args[@]}"
}

converge_hyprland_plugins_step() {
  local max_attempts=${HYPRPM_CONVERGE_MAX_ATTEMPTS:-4}
  local retry_delay_seconds=${HYPRPM_CONVERGE_RETRY_DELAY_SECONDS:-15}

  refresh_sudo_credentials
  run_with_bounded_retries \
    "Hyprland plugin convergence" \
    "$max_attempts" \
    "$retry_delay_seconds" \
    converge_hyprland_plugins
}

cleanup() {
  local status=$? cleanup_status=0
  trap - EXIT

  if [[ -n $sudo_keepalive_pid ]]; then
    kill "$sudo_keepalive_pid" 2>/dev/null || true
    wait "$sudo_keepalive_pid" 2>/dev/null || true
  fi
  if [[ -n $runtime_dir ]]; then
    rm -rf -- "$runtime_dir" || cleanup_status=1
  fi

  if [[ -n $bootstrap_report_dir ]]; then
    bootstrap_write_report aborted || true
  fi

  # Preserve every original failure, especially the security hard-stop 70.
  # Cleanup failure matters only when the main bootstrap otherwise succeeded.
  if ((status != 0)); then
    exit "$status"
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT

while (($# > 0)); do
  case $1 in
    --profile)
      (($# >= 2)) || die "--profile requires a value"
      profile=$2
      shift 2
      ;;
    --inventory)
      (($# >= 2)) || die "--inventory requires a value"
      inventory=$2
      shift 2
      ;;
    --conflict-policy)
      (($# >= 2)) || die "--conflict-policy requires a value"
      conflict_policy=$2
      shift 2
      ;;
    --apply-boot-artifacts)
      apply_boot_artifacts=true
      shift
      ;;
    --report-dir)
      (($# >= 2)) || die "--report-dir requires a value"
      bootstrap_report_dir=$2
      shift 2
      ;;
    --report-format)
      (($# >= 2)) || die "--report-format requires a value"
      bootstrap_report_format=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z $profile ]] || die "only one profile may be selected"
      profile=$1
      shift
      ;;
  esac
done

[[ -e $inventory ]] || die "inventory does not exist: $inventory"
case $bootstrap_report_format in
  text | json) ;;
  *) die "invalid report format '$bootstrap_report_format' (use text or json)" ;;
esac
if [[ -n $bootstrap_report_dir ]]; then
  install -d -m 0700 "$bootstrap_report_dir"
  bootstrap_report_state_file=$bootstrap_report_dir/.bootstrap-steps.tsv
  : >"$bootstrap_report_state_file"
fi

if [[ $EUID -eq 0 ]]; then
  die "run this command as the target desktop user, not root"
fi

command -v pacman >/dev/null 2>&1 || die "pacman was not found; this command supports Arch Linux only"
[[ -x /usr/bin/sudo ]] || die "/usr/bin/sudo is required"

target_user=$(awk '$1 == "target_user:" { print $2; exit }' \
  "$repo_root/ansible/inventory/group_vars/all.yml")
target_user_home=$(awk '$1 == "target_user_home:" { print $2; exit }' \
  "$repo_root/ansible/inventory/group_vars/all.yml")
[[ -n $target_user && -n $target_user_home ]] || die "target user defaults are missing from the inventory"
[[ $(id -un) == "$target_user" ]] || die "run as inventory target_user '$target_user', not '$(id -un)'"
[[ $HOME == "$target_user_home" ]] || die "HOME is '$HOME', but target_user_home is '$target_user_home'"

mapfile -t inventory_profiles < <(
  if command -v ansible-inventory >/dev/null 2>&1; then
    ansible-inventory --inventory "$inventory" --list 2>/dev/null |
      jq -r '._meta.hostvars | keys[]' 2>/dev/null
  elif [[ -f $inventory ]]; then
    awk '
      /^  hosts:[[:space:]]*$/ { in_hosts = 1; next }
      in_hosts && /^[^[:space:]]/ { exit }
      in_hosts && /^    [[:alnum:]_.-]+:[[:space:]]*$/ {
        name = $1
        sub(/:$/, "", name)
        print name
      }
    ' "$inventory"
  fi
)
((${#inventory_profiles[@]} > 0)) || die "no hosts were found in $inventory"

if [[ -z $profile ]]; then
  current_hostname=$(hostnamectl --static 2>/dev/null || hostname)
  for candidate in "${inventory_profiles[@]}"; do
    if [[ $candidate == "$current_hostname" ]]; then
      profile=$candidate
      break
    fi
  done

  if [[ -z $profile && ${#inventory_profiles[@]} -eq 1 ]]; then
    profile=${inventory_profiles[0]}
  fi
fi

[[ -n $profile ]] || die "multiple inventory hosts exist; select one with --profile"
profile_found=false
for candidate in "${inventory_profiles[@]}"; do
  if [[ $candidate == "$profile" ]]; then
    profile_found=true
    break
  fi
done
[[ $profile_found == true ]] || die "profile '$profile' is not present in $inventory"

case $conflict_policy in
  backup | overwrite | keep | abort)
    ;;
  "")
    [[ -t 0 ]] || die "a terminal or --conflict-policy is required before making changes"
    cat <<'EOF'
Choose one policy for every conflicting chezmoi-managed user file in this run:
  1) Back up local files, then apply the repository version (recommended)
  2) Overwrite local files with the repository version
  3) Keep conflicting local files and apply everything else
  4) Abort if any conflict is found
EOF
    read -r -p "Conflict policy [1]: " answer
    case $answer in
      "" | 1) conflict_policy=backup ;;
      2) conflict_policy=overwrite ;;
      3) conflict_policy=keep ;;
      4) conflict_policy=abort ;;
      *) die "invalid conflict policy selection" ;;
    esac
    ;;
  *)
    die "invalid conflict policy '$conflict_policy' (use backup, overwrite, keep, or abort)"
    ;;
esac

case $apply_boot_artifacts in
  true | false) ;;
  *) die "APPLY_BOOT_ARTIFACTS must be true or false" ;;
esac

if command -v chezmoi >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  bootstrap_run_step \
    "Checking user-file conflicts before privileged changes" \
    "$repo_root/scripts/apply-dotfiles.sh" --check "$conflict_policy"
  if ((bootstrap_last_step_status == 0)); then
    dotfile_preflight_complete=true
  fi
fi

bootstrap_run_step "Authenticating sudo once for the complete run" /usr/bin/sudo -v
unset SUDO_REAL_COMMAND

echo "==> Preparing non-interactive sudo execution"
sudo_wrapper_status=0
if runtime_dir=$(mktemp -d) &&
  ln -s -- "$repo_root/scripts/sudo-noninteractive" "$runtime_dir/sudo"; then
  export PATH="$runtime_dir:$PATH"
  export SUDO_COMMAND_WRAPPER="$runtime_dir/sudo"
  echo "SUCCESS: Preparing non-interactive sudo execution"
else
  sudo_wrapper_status=$?
  export SUDO_COMMAND_WRAPPER=/usr/bin/false
  bootstrap_record_failure \
    "Preparing non-interactive sudo execution" "$sudo_wrapper_status"
fi

if ((sudo_wrapper_status == 0)); then
  (
    while /usr/bin/sudo -n -v >/dev/null 2>&1; do
      sleep 30
    done
  ) &
  sudo_keepalive_pid=$!
fi

bootstrap_run_step \
  "Holding Vicinae and installing bootstrap dependencies with a full Arch upgrade" \
  prepare_vicinae_and_install_bootstrap_dependencies
if ((bootstrap_last_step_status == 0)); then
  full_upgrade_complete=true
fi
bootstrap_run_after_full_upgrade \
  "Installing the pinned Ansible collection" install_ansible_collection
bootstrap_run_step \
  "Validating repository and rendering Ansible templates" \
  validate_repository

if [[ $dotfile_preflight_complete != true ]]; then
  bootstrap_run_step \
    "Checking user-file conflicts after installing the required tools" \
    "$repo_root/scripts/apply-dotfiles.sh" --check "$conflict_policy"
fi

bootstrap_run_after_full_upgrade \
  "Installing the managed development runtimes with mise" \
  install_mise_runtimes

if [[ $skip_local != true ]]; then
  bootstrap_run_after_full_upgrade \
    "Building local packages with the mise-managed Rust toolchain" \
    install_local_packages
else
  echo "==> Skipping local packages because SKIP_LOCAL=true"
fi

bootstrap_run_after_full_upgrade \
  "Applying Ansible desired state for $profile" apply_ansible_desired_state
bootstrap_run_step \
  "Re-running full validation with the desired toolset installed" \
  validate_repository

if [[ $skip_aur != true ]]; then
  bootstrap_run_after_full_upgrade \
    "Installing approved AUR package bases" \
    "$repo_root/scripts/install-aur.sh"
else
  echo "==> Skipping AUR packages because SKIP_AUR=true"
fi

if [[ $skip_codex_desktop != true ]]; then
  bootstrap_run_after_full_upgrade \
    "Building and installing Codex Desktop from ilysenko/codex-desktop-linux" \
    install_codex_desktop
else
  echo "==> Skipping Codex Desktop because SKIP_CODEX_DESKTOP=true"
fi

if [[ $skip_local != true ]]; then
  bootstrap_run_after_full_upgrade \
    "Reconciling local package ABIs after package changes" \
    install_local_packages
elif [[ $full_upgrade_complete == true ]] &&
  ! vicinae_installed_abi_compatible; then
  bootstrap_record_failure \
    "Reconciling local package ABIs after package changes" 1
  echo "Error: SKIP_LOCAL=true left Vicinae incompatible with the live Qt ABI" >&2
fi

bootstrap_run_after_full_upgrade \
  "Converging desktop expansion after the AUR phase" \
  apply_desktop_expansion
if [[ $full_upgrade_complete == true ]]; then
  bootstrap_run_step \
    "Stopping Vicinae before applying its managed user policy" \
    prepare_vicinae_for_user_policy
  if ((bootstrap_last_step_status == 0)); then
    vicinae_policy_transition_complete=true
  fi
else
  echo \
    'SKIP: Stopping Vicinae for user-policy deployment because the full upgrade did not complete successfully.' \
    >&2
fi
if [[ $full_upgrade_complete == true &&
  $vicinae_policy_transition_complete == true ]]; then
  bootstrap_run_step \
    "Applying user configuration with policy: $conflict_policy" \
    apply_user_configuration
  if ((bootstrap_last_step_status == 0)); then
    user_configuration_complete=true
  fi
else
  bootstrap_record_failure \
    "Applying user configuration with policy: $conflict_policy" 1
  echo \
    'SKIP: Applying user configuration because Vicinae could not be safely quiesced.' \
    >&2
fi
if [[ $full_upgrade_complete == true &&
  $vicinae_policy_transition_complete == true &&
  $user_configuration_complete == true ]]; then
  bootstrap_run_step \
    "Enabling Vicinae after validating its managed user policy and Qt ABI" \
    resume_vicinae_after_user_policy
else
  echo \
    'SKIP: Enabling Vicinae because the full upgrade or user configuration did not complete successfully.' \
    >&2
fi
bootstrap_run_after_full_upgrade \
  "Converging official Hyprland plugins" \
  converge_hyprland_plugins_step
bootstrap_run_step \
  "Running integrated postflight checks" \
  run_integrated_postflight

bootstrap_finish
