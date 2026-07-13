#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
inventory="$repo_root/ansible/inventory/hosts.yml"
profile=${PROFILE:-}
conflict_policy=${CONFLICT_POLICY:-}
skip_local=${SKIP_LOCAL:-false}
skip_aur=${SKIP_AUR:-false}
apply_boot_artifacts=${APPLY_BOOT_ARTIFACTS:-false}
sudo_keepalive_pid=
runtime_dir=
dotfile_preflight_complete=false

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [PROFILE] [OPTIONS]

Converge a new or existing Arch Linux installation to this repository.

Options:
  --profile HOST                Select an Ansible inventory host.
  --conflict-policy POLICY      User-file policy: backup, overwrite, keep, abort.
  --apply-boot-artifacts        Rebuild boot artifacts when managed boot files change.
  -h, --help                    Show this help.

Environment equivalents:
  PROFILE, CONFLICT_POLICY, APPLY_BOOT_ARTIFACTS, SKIP_LOCAL, SKIP_AUR
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
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
    --conflict-policy)
      (($# >= 2)) || die "--conflict-policy requires a value"
      conflict_policy=$2
      shift 2
      ;;
    --apply-boot-artifacts)
      apply_boot_artifacts=true
      shift
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
  awk '
    /^  hosts:[[:space:]]*$/ { in_hosts = 1; next }
    in_hosts && /^[^[:space:]]/ { exit }
    in_hosts && /^    [[:alnum:]_.-]+:[[:space:]]*$/ {
      name = $1
      sub(/:$/, "", name)
      print name
    }
  ' "$inventory"
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
  echo "==> Checking user-file conflicts before privileged changes"
  "$repo_root/scripts/apply-dotfiles.sh" --check "$conflict_policy"
  dotfile_preflight_complete=true
fi

echo "==> Authenticating sudo once for the complete run"
/usr/bin/sudo -v
unset SUDO_REAL_COMMAND

runtime_dir=$(mktemp -d)
ln -s -- "$repo_root/scripts/sudo-noninteractive" "$runtime_dir/sudo"
export PATH="$runtime_dir:$PATH"
export SUDO_COMMAND_WRAPPER="$runtime_dir/sudo"

(
  while /usr/bin/sudo -n -v >/dev/null 2>&1; do
    sleep 30
  done
) &
sudo_keepalive_pid=$!

echo "==> Installing bootstrap dependencies with a full Arch upgrade"
sudo pacman --config "$repo_root/ansible/roles/packages/templates/pacman.conf.j2" \
  -Syu --needed --noconfirm \
  ansible-core \
  base-devel \
  chezmoi \
  git \
  jq \
  lua \
  ripgrep \
  rustup

echo "==> Installing the pinned Ansible collection"
ansible-galaxy collection install \
  --requirements-file "$repo_root/ansible/collections/requirements.yml"

echo "==> Validating repository and rendering Ansible templates"
"$repo_root/scripts/validate.sh"

if [[ $dotfile_preflight_complete != true ]]; then
  echo "==> Checking user-file conflicts after installing the required tools"
  "$repo_root/scripts/apply-dotfiles.sh" --check "$conflict_policy"
fi

if [[ $skip_local != true ]]; then
  echo "==> Preparing the Rust toolchain required by local packages"
  rustup toolchain install stable
  rustup default stable
  "$repo_root/scripts/install-local-packages.sh"
else
  echo "==> Skipping local packages because SKIP_LOCAL=true"
fi

echo "==> Applying Ansible desired state for $profile"
ANSIBLE_BECOME_ASK_PASS=false \
  ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
  ansible-playbook \
  --inventory "$inventory" \
  "$repo_root/ansible/site.yml" \
  --limit "$profile" \
  --extra-vars "ansible_become_exe=$SUDO_COMMAND_WRAPPER perform_full_upgrade=false apply_boot_artifacts=$apply_boot_artifacts"

echo "==> Re-running full validation with the desired toolset installed"
"$repo_root/scripts/validate.sh"

if [[ $skip_aur != true ]]; then
  "$repo_root/scripts/install-aur.sh"
else
  echo "==> Skipping AUR packages because SKIP_AUR=true"
fi

echo "==> Converging desktop expansion after the AUR phase"
ANSIBLE_BECOME_ASK_PASS=false \
  ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
  ansible-playbook \
  --inventory "$inventory" \
  "$repo_root/ansible/site.yml" \
  --limit "$profile" \
  --tags desktop-expansion \
  --extra-vars "ansible_become_exe=$SUDO_COMMAND_WRAPPER perform_full_upgrade=false apply_boot_artifacts=$apply_boot_artifacts"

echo "==> Applying user configuration with policy: $conflict_policy"
"$repo_root/scripts/apply-dotfiles.sh" --apply "$conflict_policy"

echo "==> Running integrated postflight checks"
"$repo_root/scripts/postflight.sh"

echo "==> Arch Linux configuration converged successfully"
