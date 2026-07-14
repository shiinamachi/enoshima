#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bootstrap=$repo_root/bootstrap.sh
validate=$repo_root/scripts/validate.sh
postflight=$repo_root/scripts/postflight.sh

line_number() {
  local path=$1
  local pattern=$2
  local match
  match=$(grep -nF -- "$pattern" "$path" | head -n 1)
  [[ -n $match ]] || {
    printf 'Missing expected bootstrap integration: %s\n' "$pattern" >&2
    exit 1
  }
  printf '%s\n' "${match%%:*}"
}

aur_line=$(line_number "$bootstrap" "\"\$repo_root/scripts/install-aur.sh\"")
converge_line=$(line_number "$bootstrap" '==> Converging desktop expansion after the AUR phase')
apply_line=$(line_number "$bootstrap" "\"\$repo_root/scripts/apply-dotfiles.sh\" --apply")
plugins_line=$(line_number "$bootstrap" '==> Converging official Hyprland plugins')
postflight_line=$(line_number "$bootstrap" "\"\$repo_root/scripts/postflight.sh\"")
((aur_line < converge_line && converge_line < apply_line)) || {
  printf 'Desktop expansion must converge after AUR and before dotfile apply.\n' >&2
  exit 1
}
((apply_line < plugins_line && plugins_line < postflight_line)) || {
  printf 'Hyprland plugins must converge after dotfiles and before postflight.\n' >&2
  exit 1
}

grep -Fq -- '--tags desktop-expansion' "$bootstrap"
grep -Fq 'perform_full_upgrade=false' "$bootstrap"
grep -Fq "ansible_become_exe=\$SUDO_COMMAND_WRAPPER" "$bootstrap"
if [[ $(grep -Fc 'ANSIBLE_WORKER_SESSION_ISOLATION=false' "$bootstrap") -ne 2 ]]; then
  printf 'Every Ansible convergence must retain the bootstrap TTY session.\n' >&2
  exit 1
fi
if [[ $(grep -Fc 'refresh_sudo_credentials' "$bootstrap") -ne 4 ]]; then
  printf 'Every privileged convergence phase must refresh sudo first.\n' >&2
  exit 1
fi
grep -Fq "hyprpm add \"\$official_repo\"" "$bootstrap"
grep -Fq 'hyprpm disable hyprbars' "$bootstrap"
grep -Fq 'hyprpm enable hyprfocus' "$bootstrap"
grep -Fq 'Version ABI string:' "$bootstrap"
grep -Fq 'tests/test-cyberdock-state.sh' "$validate"
grep -Fq 'tests/test-cyberpunk-library-theme.sh' "$validate"
grep -Fq 'tests/test-desktop-appearance.sh' "$validate"
grep -Fq 'env -u HYPRLAND_INSTANCE_SIGNATURE' "$validate"
grep -Fq 'Checking desktop expansion security invariants' "$validate"
grep -Fq 'Cloudflare One daemon did not converge after the AUR phase' "$postflight"
grep -Fq 'Cyberpunk Library session theme applied' "$bootstrap"
grep -Fq 'managed 16:10 cyberpunk wallpaper is deployed intact' "$postflight"

if rg -q 'validate-desktop-expansion|postflight-desktop-expansion|converge-desktop-expansion' \
  "$bootstrap" "$validate" "$postflight"; then
  printf 'A parallel desktop expansion entrypoint was reintroduced.\n' >&2
  exit 1
fi

printf 'Desktop expansion bootstrap integration tests passed.\n'
