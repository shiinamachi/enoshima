#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0
warnings=0

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
  warnings=$((warnings + 1))
}

check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

manifest_entries() {
  sed -E \
    -e 's/[[:space:]]+#.*$//' \
    -e '/^[[:space:]]*(#|$)/d' \
    "$1"
}

echo "==> Packages"
while IFS= read -r package; do
  check "pacman package installed: $package" pacman -Q "$package"
done < <(
  for manifest in \
    "$repo_root/packages/native.txt" \
    "$repo_root/packages/management.txt" \
    "$repo_root/packages/optional-deps.txt" \
    "$repo_root/packages/aur.txt"; do
    manifest_entries "$manifest"
  done | sort -u
)

while IFS= read -r package; do
  check "local package installed: $package" pacman -Q "$package"
done < <(find "$repo_root/packages/local" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

while IFS= read -r package; do
  if pacman -Q "$package" >/dev/null 2>&1; then
    fail "package is intentionally absent: $package"
  else
    pass "package is intentionally absent: $package"
  fi
done < <(manifest_entries "$repo_root/packages/absent.txt")

check "multilib repository enabled" bash -c \
  "pacman-conf --repo-list | grep -Fxq multilib"

echo "==> Power and sleep"
for unit in tlp.service tlp-pd.service rtkit-daemon.service; do
  check "$unit enabled" systemctl is-enabled --quiet "$unit"
done
check "tlp-pd active" systemctl is-active --quiet tlp-pd.service
check "RealtimeKit active" systemctl is-active --quiet rtkit-daemon.service
check "TLP reports an active profile" tlp-stat -s
check "TLP profile compatibility API is available" tlpctl get
check "s2idle is the selected suspend mode" bash -c \
  "grep -q '\[s2idle\]' /sys/power/mem_sleep"
check "no TLP charge threshold is configured" bash -c \
  "! grep -RqsE '^[[:space:]]*(START|STOP)_CHARGE_THRESH_' /etc/tlp.conf /etc/tlp.d"

echo "==> Authentication and login"
check "fingerprint enrolled for the current user" fprintd-list "$USER"
for pam_file in /etc/pam.d/sddm /etc/pam.d/sudo; do
  check "$pam_file has fingerprint authentication" grep -q pam_fprintd.so "$pam_file"
  check "$pam_file keeps password-first authentication" grep -q 'pam_unix.so.*try_first_pass.*likeauth' "$pam_file"
done
check "SDDM remains the boot display manager" systemctl is-enabled --quiet sddm.service
check "vi resolves to Vim" bash -c \
  "[[ \$(readlink -f /usr/local/bin/vi) == /usr/bin/vim ]]"

echo "==> ThinkPad hardware integration"
check "NetworkManager active" systemctl is-active --quiet NetworkManager.service
check "ModemManager active" systemctl is-active --quiet ModemManager.service
check "Lenovo WWAN configuration service enabled" systemctl is-enabled --quiet lenovo-cfgservice.service
check "Lenovo WWAN configuration service active" systemctl is-active --quiet lenovo-cfgservice.service
for regulatory_profile in 29619 30007; do
  check "Gen 13 RM520N-GL SAR profile installed: $regulatory_profile" bash -c \
    "compgen -G '/opt/fcc_lenovo/sar_config_files/cs25/*RM520NGL*ThinkPad-X1-Carbon-Gen-13*21NX*$regulatory_profile.bin' >/dev/null"
done
check "at least one GSM connection profile exists" bash -c \
  "nmcli -g TYPE connection show | grep -Fxq gsm"
check "WWAN fallback dispatcher installed" test -x /etc/NetworkManager/dispatcher.d/90-wwan-fallback
check "RGB UVC camera present" grep -qs '^Integrated Camera: Integrated C' /sys/class/video4linux/*/name
check "IR UVC camera present" grep -qs '^Integrated Camera: Integrated I' /sys/class/video4linux/*/name
check "fingerprint reader present" bash -c \
  "lsusb | grep -Fq '06cb:0123'"

if journalctl -b -u lenovo-cfgservice.service --no-pager 2>/dev/null |
  grep -Eqi '(No such file|SAR.*(fail|error)|failed to open.*\.bin)'; then
  warn "Lenovo WWAN service journal still contains a SAR-file error"
else
  pass "Lenovo WWAN service journal has no known SAR-file error"
fi

if mmcli -L -J 2>/dev/null |
  jq -e '."modem-list" | length > 0' >/dev/null 2>&1; then
  pass "ModemManager detects a modem"
else
  warn "no modem is currently visible (check BIOS, SIM, RF kill, and Lenovo service)"
fi

echo "==> Desktop session"
for unit in \
  pipewire.service \
  pipewire-pulse.service \
  wireplumber.service \
  xdg-desktop-portal-hyprland.service; do
  check "user unit active: $unit" systemctl --user is-active --quiet "$unit"
done

for unit in hyprlauncher.service xembed-sni-proxy.service; do
  check "custom user unit enabled: $unit" systemctl --user is-enabled --quiet "$unit"
  check "custom user unit active: $unit" systemctl --user is-active --quiet "$unit"
done

check "Hyprland session is managed by UWSM" \
  systemctl --user is-active --quiet wayland-wm@hyprland.desktop.service

check "Bottles Flatpak installed for the user" flatpak info --user com.usebottles.bottles
check "Fcitx daemon is reachable" fcitx5-remote
check "Fcitx XIM environment imported into user manager" bash -c \
  "systemctl --user show-environment | grep -Fxq 'XMODIFIERS=@im=fcitx'"
check "Secret Service is available for application credentials" \
  busctl --user --quiet status org.freedesktop.secrets

if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors -j >/dev/null 2>&1; then
  monitor_json=$(hyprctl monitors -j)
  if jq -e '.[] | select(.name == "eDP-1") | select(.width == 2880 and .height == 1800 and .refreshRate >= 119 and .scale == 1.5 and .x == 0 and .y == 240)' \
    <<<"$monitor_json" >/dev/null; then
    pass "internal display is 2880x1800@120, scale 1.5, at 0x240"
  else
    fail "internal display does not match the requested mode/scale/layout"
  fi

  if jq -e '.[] | select(.model | contains("U2725QE"))' <<<"$monitor_json" >/dev/null; then
    if jq -e '.[] | select(.model | contains("U2725QE")) | select(.width == 3840 and .height == 2160 and .refreshRate >= 119 and .scale == 1.5 and .x == 1920 and .y == 0)' \
      <<<"$monitor_json" >/dev/null; then
      pass "Dell U2725QE is 3840x2160@120, scale 1.5, at 1920x0"
    else
      fail "connected Dell U2725QE does not match the requested mode/scale/layout"
    fi
  else
    warn "Dell U2725QE is disconnected; its EDID selector and 120 Hz mode remain to be verified"
  fi

  if [[ -z $(hyprctl configerrors) ]]; then
    pass "Hyprland reports no configuration errors"
  else
    fail "Hyprland reports configuration errors"
  fi

  if hyprctl getoption input:kb_options -j 2>/dev/null |
    jq -e '.str == "korean:ralt_hangul"' >/dev/null; then
    pass "Right Alt is mapped to the Hangul keysym"
  else
    fail "Right Alt is not mapped to the Hangul keysym"
  fi

  if hyprctl getoption xwayland:force_zero_scaling -j 2>/dev/null |
    jq -e '.bool == true' >/dev/null; then
    pass "XWayland zero scaling is active"
  else
    fail "XWayland zero scaling is not active"
  fi

  if hyprctl getoption general:resize_on_border -j 2>/dev/null |
    jq -e '.bool == true' >/dev/null; then
    pass "direct pointer resizing on tiled borders is active"
  else
    fail "direct pointer resizing on tiled borders is not active"
  fi
else
  warn "Hyprland IPC is unavailable; display and live configuration checks were skipped"
fi

if [[ -d $HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/KakaoTalk ]]; then
  pass "KakaoTalk Bottles prefix exists"
else
  warn "KakaoTalk bottle is not provisioned; run kakaotalk-setup interactively"
fi

if [[ -z $(systemctl --failed --no-legend --plain 2>/dev/null) ]]; then
  pass "no failed system units"
else
  fail "one or more system units are failed"
fi

if [[ -z $(systemctl --user --failed --no-legend --plain 2>/dev/null) ]]; then
  pass "no failed user units"
else
  fail "one or more user units are failed"
fi

printf '\nPostflight result: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
printf 'Manual checks still required: sudo fingerprint, SDDM fingerprint, Hyprlock, Wi-Fi/WWAN handoff, Kakao login/files/clipboard/tray, and Parsec input/video.\n'

((failures == 0))
