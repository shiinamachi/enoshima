#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0
warnings=0

pass() {
  printf '[PASS] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
  warnings=$((warnings + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
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

check_enabled_or_warn() {
  local unit=$1
  if systemctl --user is-enabled --quiet "$unit"; then
    pass "user unit enabled: $unit"
  else
    warn "user unit is not enabled yet: $unit"
  fi
}

echo "==> Base workstation postflight"
if "$repo_root/scripts/postflight.sh"; then
  pass 'base workstation postflight passed'
else
  fail 'base workstation postflight reported failures'
fi

echo "==> Desktop expansion packages and static state"
for package in \
  cloudflare-warp-bin fuse3 gimp libsecret onlyoffice-bin photogimp quickshell \
  rclone thunderbird ttf-caladea ttf-carlito ttf-jetendard ttf-liberation \
  protonmail-bridge rhwp-desktop; do
  check "package installed: $package" pacman -Q "$package"
done

check 'managed cyberpunk wallpaper is deployed' \
  test -f "$HOME/.local/share/backgrounds/cyberpunk-city.png"
check 'cyberpunk SDDM theme payload is installed' \
  test -f /usr/share/sddm/themes/cyberpunk/Main.qml

if [[ -f /etc/sddm.conf.d/20-cyberpunk-theme.conf ]]; then
  check 'gated cyberpunk SDDM theme is selected' \
    grep -Eq '^[[:space:]]*Current=cyberpunk[[:space:]]*$' \
    /etc/sddm.conf.d/20-cyberpunk-theme.conf
else
  warn 'cyberpunk SDDM selection is gated off pending manual acceptance'
fi

if [[ $(fc-match -f '%{family}\n' sans-serif 2>/dev/null) == Jetendard* ]]; then
  pass 'Jetendard is the first sans-serif match'
else
  fail 'Jetendard is not the first sans-serif match'
fi
if [[ $(fc-match -f '%{family}\n' monospace 2>/dev/null) == Jetendard* ]]; then
  pass 'Jetendard is the first monospace match'
else
  fail 'Jetendard is not the first monospace match'
fi

echo "==> Dock, titlebar, scaling, and input"
for unit in cyberdock.service hyprbars-check.service; do
  check_enabled_or_warn "$unit"
done

if systemctl --user is-active --quiet graphical-session.target; then
  check 'Cyberdock is active in the graphical session' \
    systemctl --user is-active --quiet cyberdock.service
else
  warn 'graphical session is inactive; live Dock and plugin checks are deferred'
fi

hyprbars_marker=${XDG_STATE_HOME:-$HOME/.local/state}/hyprbars/hyprland-abi
if [[ -f $hyprbars_marker ]]; then
  if hyprctl plugin list -j 2>/dev/null |
    jq -e 'any(.[]?; ((.name // "") | ascii_downcase) == "hyprbars")' \
      >/dev/null 2>&1; then
    pass 'Hyprbars is loaded for the running compositor'
  else
    fail 'Hyprbars onboarding marker exists but the plugin is not loaded'
  fi
else
  warn 'Hyprbars is not onboarded; run hyprbars-setup interactively'
fi

if command -v desktop-scaling-status >/dev/null 2>&1; then
  desktop-scaling-status
  scaling_status=$?
  case $scaling_status in
    0) pass 'all scaling acceptance clients have the intended backend' ;;
    2) warn 'some scaling acceptance clients are not running' ;;
    *) fail 'one or more live clients use the wrong display backend' ;;
  esac
else
  fail 'desktop-scaling-status is not deployed'
fi

echo "==> Cloud mounts and mail"
rclone_config=${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf
if [[ -f $rclone_config ]]; then
  if grep -q '^RCLONE_ENCRYPT_V[0-9]\+:' "$rclone_config"; then
    pass 'rclone configuration is encrypted'
  else
    fail 'rclone configuration exists but is not encrypted'
  fi
  if [[ $(stat -c '%a' "$rclone_config" 2>/dev/null) == 600 ]]; then
    pass 'rclone configuration mode is 0600'
  else
    fail 'rclone configuration mode is not 0600'
  fi

  for remote in google-drive proton-drive; do
    unit=rclone-$remote.service
    check "cloud mount unit enabled: $unit" \
      systemctl --user is-enabled --quiet "$unit"
    check "cloud mount unit active: $unit" \
      systemctl --user is-active --quiet "$unit"
  done
  check 'Google Drive mount is present' mountpoint -q "$HOME/Cloud/GoogleDrive"
  check 'Proton Drive mount is present' mountpoint -q "$HOME/Cloud/ProtonDrive"
else
  warn 'cloud accounts are not onboarded; run rclone-cloud-setup all'
fi

bridge_marker=${XDG_STATE_HOME:-$HOME/.local/state}/protonmail-bridge/managed-service-enabled
if [[ -f $bridge_marker ]]; then
  if protonmail-bridge-status; then
    pass 'Proton Mail Bridge managed state is ready'
  else
    fail 'Proton Mail Bridge onboarding exists but managed state is unhealthy'
  fi
else
  warn 'Proton Mail Bridge is not onboarded; run protonmail-bridge-setup'
fi

echo "==> Cloudflare One, office, graphics, and KakaoTalk"
if systemctl is-enabled --quiet warp-svc.service &&
  systemctl is-active --quiet warp-svc.service; then
  pass 'Cloudflare One system daemon is enabled and active'
else
  warn 'Cloudflare One daemon awaits the post-AUR Ansible convergence'
fi
if systemctl --user is-enabled --quiet warp-taskbar.service; then
  pass 'Cloudflare One taskbar unit is enabled'
else
  warn 'Cloudflare One GUI enrollment is pending; run cloudflare-one-setup'
fi
if command -v cloudflare-one-status >/dev/null 2>&1; then
  cloudflare-one-status
fi

for mime_type in \
  application/vnd.openxmlformats-officedocument.wordprocessingml.document \
  application/vnd.openxmlformats-officedocument.spreadsheetml.sheet \
  application/vnd.openxmlformats-officedocument.presentationml.presentation; do
  if [[ $(xdg-mime query default "$mime_type" 2>/dev/null) == onlyoffice-desktopeditors.desktop ]]; then
    pass "ONLYOFFICE default: $mime_type"
  else
    fail "ONLYOFFICE is not the default for $mime_type"
  fi
done
if [[ $(xdg-mime query default application/pdf 2>/dev/null) == google-chrome.desktop ]]; then
  pass 'PDF default remains Google Chrome'
else
  fail 'PDF default changed from the approved existing policy'
fi

if [[ $(stat -c '%U:%G:%a' /opt/rhwp-desktop/chrome-sandbox 2>/dev/null) == root:root:4755 ]]; then
  pass 'RHWP Chromium sandbox has the reviewed root-owned 4755 mode'
else
  fail 'RHWP Chromium sandbox owner or mode is incorrect'
fi

if xdg-mime query default application/vnd.hancom.hwpx 2>/dev/null |
  grep -Fxq rhwp-desktop.desktop; then
  pass 'RHWP defaults were enabled after local acceptance'
else
  warn 'RHWP HWP/HWPX defaults remain gated pending sample acceptance'
fi

if command -v graphics-workflow-check >/dev/null 2>&1; then
  if graphics-workflow-check --status; then
    pass 'GIMP and PhotoGIMP profiles remain isolated'
  else
    fail 'graphics workflow status reported a managed-state failure'
  fi
else
  fail 'graphics-workflow-check is not deployed'
fi

if [[ -d $HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/KakaoTalk ]]; then
  pass 'KakaoTalk bottle exists'
else
  warn 'KakaoTalk onboarding is pending; run its connectivity check and setup'
fi

printf '\nDesktop expansion postflight: %d failure(s), %d warning(s).\n' \
  "$failures" "$warnings"
printf '%s\n' \
  'Manual visual, account, input, document round-trip, and reconnect checks remain required; see docs/DESKTOP-EXPANSION-OPERATIONS.md.'

((failures == 0))
