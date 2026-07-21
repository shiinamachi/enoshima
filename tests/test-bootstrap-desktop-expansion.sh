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

aur_line=$(line_number "$bootstrap" '"Installing approved AUR package bases"')
codex_line=$(line_number "$bootstrap" '"Building and installing Codex Desktop from ilysenko/codex-desktop-linux"')
converge_line=$(line_number "$bootstrap" '"Converging desktop expansion after the AUR phase"')
apply_line=$(line_number "$bootstrap" "\"Applying user configuration with policy: \$conflict_policy\"")
plugins_line=$(line_number "$bootstrap" '"Converging official Hyprland plugins"')
postflight_line=$(line_number "$bootstrap" '"Running integrated postflight checks"')
((aur_line < codex_line && codex_line < converge_line && converge_line < apply_line)) || {
  printf 'Codex build and desktop expansion must follow AUR before dotfile apply.\n' >&2
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
if [[ $(grep -Fc 'refresh_sudo_credentials' "$bootstrap") -ne 5 ]]; then
  printf 'Every privileged convergence phase must refresh sudo first.\n' >&2
  exit 1
fi
grep -Fq "hyprpm add \"\$official_repo\"" "$bootstrap"
grep -Fq 'scripts/lib/hyprpm-version-socket' "$bootstrap"
grep -Fq 'hyprpm disable hyprbars' "$bootstrap"
grep -Fq 'hyprpm enable hyprfocus' "$bootstrap"
grep -Fq 'native/enoshima-decoration' "$bootstrap"
grep -Fq 'enoshima-decoration.so' "$bootstrap"
grep -Fq 'enoshima-decoration-load' "$bootstrap"
grep -Fq 'hyprctl reload config-only' "$bootstrap"
grep -Fq 'Version ABI string:' "$bootstrap"
grep -Fq "source \"\$repo_root/scripts/lib/bootstrap-failures.sh\"" "$bootstrap"
grep -Fq 'bootstrap_finish' "$bootstrap"
grep -Fq 'tests/test-cyberdock-state.sh' "$validate"
grep -Fq 'tests/test-cyberdock-pins.sh' "$validate"
grep -Fq 'tests/test-desktop-display-mode.sh' "$validate"
grep -Fq 'tests/test-desktop-power.sh' "$validate"
grep -Fq 'tests/test-desktop-window-action.sh' "$validate"
grep -Fq 'tests/test-enoshima-snap-controller.sh' "$validate"
grep -Fq 'tests/test-enoshima-decoration.sh' "$validate"
grep -Fq 'tests/test-window-decoration-policy.sh' "$validate"
grep -Fq 'tests/test-hypr-mouse-binds.sh' "$validate"
grep -Fq 'tests/test-hyprlock-responsive.sh' "$validate"
grep -Fq 'tests/test-cyberpunk-library-theme.sh' "$validate"
grep -Fq 'tests/test-desktop-appearance.sh' "$validate"
grep -Fq 'tests/test-login-manager.sh' "$validate"
grep -Fq 'tests/test-swaync-quick-setting.sh' "$validate"
grep -Fq 'env -u HYPRLAND_INSTANCE_SIGNATURE' "$validate"
grep -Fq '/usr/lib/qt6/bin/qmllint --max-warnings 0' "$validate"
if grep -Fq 'command -v qmllint' "$validate"; then
  printf 'QML validation must not fall back to an incompatible Qt 5 qmllint.\n' >&2
  exit 1
fi
grep -Fq 'Checking desktop expansion security invariants' "$validate"
grep -Fq 'Cloudflare One daemon did not converge after the AUR phase' "$postflight"
grep -Fq 'Cyberpunk Library session theme applied' "$bootstrap"
grep -Fq 'managed 16:10 cyberpunk wallpaper is deployed intact' "$postflight"

socket_reply=$(PATH="$repo_root/tests/fixtures/hyprpm-bin:$PATH" \
  "$repo_root/scripts/lib/hyprpm-version-socket" python -c '
import os
import socket

path = os.path.join(
    os.environ["XDG_RUNTIME_DIR"],
    "hypr",
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"],
    ".socket.sock",
)
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(path)
client.sendall(b"j/version")
client.shutdown(socket.SHUT_WR)
data = b""
while True:
    chunk = client.recv(4096)
    if not chunk:
        break
    data += chunk
print(data.decode())
')
jq -e '
  .commit == "0123456789abcdef" and
  .abiHash == "test-abi"
' <<<"$socket_reply" >/dev/null || {
  printf 'Offline hyprpm version socket returned invalid data.\n' >&2
  exit 1
}

if rg -q 'validate-desktop-expansion|postflight-desktop-expansion|converge-desktop-expansion' \
  "$bootstrap" "$validate" "$postflight"; then
  printf 'A parallel desktop expansion entrypoint was reintroduced.\n' >&2
  exit 1
fi

printf 'Desktop expansion bootstrap integration tests passed.\n'
