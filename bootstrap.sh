#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
profile=${1:-$(hostnamectl --static 2>/dev/null || hostname)}
skip_local=${SKIP_LOCAL:-false}
skip_aur=${SKIP_AUR:-false}

if [[ $EUID -eq 0 ]]; then
  echo "Run bootstrap as the target desktop user, not root." >&2
  exit 1
fi

echo "==> Installing bootstrap dependencies with a full Arch upgrade"
sudo pacman -Syu --needed \
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

if [[ $skip_local != true ]]; then
  echo "==> Preparing the Rust toolchain required by reviewed local packages"
  rustup toolchain install stable
  rustup default stable
  "$repo_root/scripts/install-local-packages.sh"
else
  echo "==> Skipping local packages because SKIP_LOCAL=true"
fi

echo "==> Applying Ansible desired state for $profile"
ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
  ansible-playbook -K \
  --inventory "$repo_root/ansible/inventory/hosts.yml" \
  "$repo_root/ansible/site.yml" \
  --limit "$profile"

if [[ $skip_aur != true ]]; then
  "$repo_root/scripts/install-aur.sh"
else
  echo "==> Skipping AUR packages because SKIP_AUR=true"
fi

echo "==> Initializing chezmoi from this monorepo"
chezmoi init --source "$repo_root"
chezmoi --source "$repo_root" diff

if [[ ! -t 0 ]]; then
  echo "Refusing to apply dotfiles without an interactive review." >&2
  exit 1
fi

read -r -p "Apply the chezmoi diff above? [y/N] " answer
if [[ $answer =~ ^[Yy]$ ]]; then
  chezmoi --source "$repo_root" apply
else
  echo "Dotfiles were not applied. Run 'make chezmoi-diff' to review again."
fi
