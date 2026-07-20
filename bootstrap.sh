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
sudo_keepalive_pid=
runtime_dir=
dotfile_preflight_complete=false
mise_config_source="$repo_root/home/dot_config/mise/config.toml"
# shellcheck source=scripts/lib/bootstrap-failures.sh
source "$repo_root/scripts/lib/bootstrap-failures.sh"

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
  SKIP_LOCAL, SKIP_AUR, SKIP_CODEX_DESKTOP
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
    printf '\n' | hyprpm add "$official_repo"
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

install_bootstrap_dependencies() {
  "$SUDO_COMMAND_WRAPPER" pacman \
    --config "$repo_root/ansible/roles/packages/templates/pacman.conf.j2" \
    -Syu --needed --noconfirm \
    ansible-core \
    base-devel \
    chezmoi \
    git \
    jq \
    lua \
    mise \
    ripgrep \
    rustup
}

install_ansible_collection() {
  ansible-galaxy collection install \
    --requirements-file "$repo_root/ansible/collections/requirements.yml"
}

install_mise_runtimes() {
  MISE_CONFIG_FILE="$mise_config_source" mise install --yes
}

install_local_packages() {
  local rust_toolchain

  rust_toolchain=$(
    MISE_CONFIG_FILE="$mise_config_source" mise ls --current --json |
      jq -r '.rust[0].version // empty'
  )
  if [[ ! $rust_toolchain =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: mise did not resolve the managed Rust toolchain" >&2
    return 1
  fi

  # Keep Arch's /usr/bin/python ahead of the global mise Python here: local
  # PKGBUILDs consume pacman-provided Python build modules. Select only the
  # Rust toolchain through rustup's standard environment contract.
  PATH="/usr/bin:/bin:$PATH" \
    RUSTUP_TOOLCHAIN="$rust_toolchain" \
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

run_integrated_postflight() {
  local -a args=(--profile "$profile" --inventory "$inventory")

  if [[ -n $bootstrap_report_dir && $bootstrap_report_format == json ]]; then
    args+=(--format json --output "$bootstrap_report_dir/postflight.json")
  fi
  "$repo_root/scripts/postflight.sh" "${args[@]}"
}

converge_hyprland_plugins_step() {
  refresh_sudo_credentials
  converge_hyprland_plugins
}

cleanup() {
  local status=$?
  trap - EXIT

  if [[ -n $sudo_keepalive_pid ]]; then
    kill "$sudo_keepalive_pid" 2>/dev/null || true
    wait "$sudo_keepalive_pid" 2>/dev/null || true
  fi
  if [[ -n $runtime_dir ]]; then
    rm -rf -- "$runtime_dir"
  fi

  if [[ -n $bootstrap_report_dir ]]; then
    bootstrap_write_report aborted || true
  fi

  exit "$status"
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
  "Installing bootstrap dependencies with a full Arch upgrade" \
  install_bootstrap_dependencies
bootstrap_run_step "Installing the pinned Ansible collection" install_ansible_collection
bootstrap_run_step \
  "Validating repository and rendering Ansible templates" \
  "$repo_root/scripts/validate.sh"

if [[ $dotfile_preflight_complete != true ]]; then
  bootstrap_run_step \
    "Checking user-file conflicts after installing the required tools" \
    "$repo_root/scripts/apply-dotfiles.sh" --check "$conflict_policy"
fi

bootstrap_run_step \
  "Installing the managed development runtimes with mise" \
  install_mise_runtimes

if [[ $skip_local != true ]]; then
  bootstrap_run_step \
    "Building local packages with the mise-managed Rust toolchain" \
    install_local_packages
else
  echo "==> Skipping local packages because SKIP_LOCAL=true"
fi

bootstrap_run_step "Applying Ansible desired state for $profile" apply_ansible_desired_state
bootstrap_run_step \
  "Re-running full validation with the desired toolset installed" \
  "$repo_root/scripts/validate.sh"

if [[ $skip_aur != true ]]; then
  bootstrap_run_step \
    "Installing approved AUR package bases" \
    "$repo_root/scripts/install-aur.sh"
else
  echo "==> Skipping AUR packages because SKIP_AUR=true"
fi

if [[ $skip_codex_desktop != true ]]; then
  bootstrap_run_step \
    "Building and installing Codex Desktop from ilysenko/codex-desktop-linux" \
    install_codex_desktop
else
  echo "==> Skipping Codex Desktop because SKIP_CODEX_DESKTOP=true"
fi

bootstrap_run_step \
  "Converging desktop expansion after the AUR phase" \
  apply_desktop_expansion
bootstrap_run_step \
  "Applying user configuration with policy: $conflict_policy" \
  apply_user_configuration
bootstrap_run_step \
  "Converging official Hyprland plugins" \
  converge_hyprland_plugins_step
bootstrap_run_step \
  "Running integrated postflight checks" \
  run_integrated_postflight

bootstrap_finish
