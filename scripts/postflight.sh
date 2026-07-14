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

check_or_warn() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    warn "$description"
  fi
}

sha256_matches() {
  local path=$1
  local expected=$2
  local actual
  actual=$(sha256sum -- "$path") || return 1
  [[ ${actual%% *} == "$expected" ]]
}

lenovo_sar_run_succeeded() {
  local invocation result exit_status
  invocation=$(systemctl show lenovo-cfgservice.service \
    --property InvocationID --value 2>/dev/null) || return 1
  result=$(systemctl show lenovo-cfgservice.service \
    --property Result --value 2>/dev/null) || return 1
  exit_status=$(systemctl show lenovo-cfgservice.service \
    --property ExecMainStatus --value 2>/dev/null) || return 1
  [[ -n $invocation && $result == success && $exit_status == 0 ]]
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
  # pacman -Q <name> accepts providers, so it would report tlp-pd as an
  # installed power-profiles-daemon. Compare against actual database names.
  if pacman -Qq | grep -Fxq -- "$package"; then
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
check_or_warn "fingerprint enrolled for the current user (manual enrollment if absent)" \
  fprintd-list "${USER:-$(id -un)}"
for pam_file in /etc/pam.d/sddm /etc/pam.d/sudo; do
  check "$pam_file has fingerprint authentication" grep -q pam_fprintd.so "$pam_file"
  check "$pam_file keeps password-first authentication" grep -q 'pam_unix.so.*try_first_pass.*likeauth' "$pam_file"
done
check "SDDM remains the boot display manager" systemctl is-enabled --quiet sddm.service
check "vi resolves to Vim" bash -c \
  "[[ \$(readlink -f /usr/local/bin/vi) == /usr/bin/vim ]]"
# The inner expression is intentionally evaluated by bash -c.
# shellcheck disable=SC2016
check "login shell is Zsh" bash -c \
  '[[ $(getent passwd "${USER:-$(id -un)}" | cut -d: -f7) == /bin/zsh ]]'
check "Oh My Zsh is installed from the managed package" \
  test -r /usr/share/oh-my-zsh/oh-my-zsh.sh
check "fastfetch configuration deployed" \
  test -f "$HOME/.config/fastfetch/config.jsonc"

echo "==> Development runtimes"
mise_config=$HOME/.config/mise/config.toml
check "mise global runtime configuration deployed" test -f "$mise_config"
runtime_names=(Node.js Python Go Rust)
runtime_bins=(node python go rustc)
for index in "${!runtime_names[@]}"; do
  check "mise runtime active: ${runtime_names[$index]}" env \
    MISE_CONFIG_FILE="$mise_config" mise which "${runtime_bins[$index]}"
done

echo "==> ThinkPad hardware integration"
check "NetworkManager active" systemctl is-active --quiet NetworkManager.service
check "ModemManager active" systemctl is-active --quiet ModemManager.service
check "Lenovo WWAN configuration service enabled" systemctl is-enabled --quiet lenovo-cfgservice.service
check "Lenovo WWAN SAR configuration completed successfully" lenovo_sar_run_succeeded
for regulatory_profile in 29619 30007; do
  check "Gen 13 RM520N-GL SAR profile installed: $regulatory_profile" bash -c \
    "compgen -G '/opt/fcc_lenovo/sar_config_files/cs25/*RM520NGL*ThinkPad-X1-Carbon-Gen-13*21NX*$regulatory_profile.bin' >/dev/null"
done
check_or_warn "at least one GSM connection profile exists (manual APN credentials if absent)" bash -c \
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
  cyberdock.service \
  hyprlauncher.service \
  xembed-sni-proxy.service; do
  check "custom user unit enabled: $unit" systemctl --user is-enabled --quiet "$unit"
done

check "Bottles Flatpak installed for the user" flatpak info --user com.usebottles.bottles

if systemctl --user is-active --quiet graphical-session.target; then
  hyprland_config_errors=$(hyprctl configerrors 2>/dev/null || true)
  if [[ -z $hyprland_config_errors ]]; then
    pass "Hyprland reports no live configuration errors"
  else
    fail "Hyprland reports one or more live configuration errors"
    printf '%s\n' "$hyprland_config_errors" >&2
  fi

  for unit in \
    pipewire.service \
    pipewire-pulse.service \
    wireplumber.service \
    xdg-desktop-portal-hyprland.service \
    hyprlauncher.service \
    xembed-sni-proxy.service; do
    check_or_warn "user unit active after login: $unit" systemctl --user is-active --quiet "$unit"
  done

  check_or_warn "Hyprland session is managed by UWSM (select it at the next login if absent)" \
    systemctl --user is-active --quiet wayland-wm@hyprland.desktop.service
  check_or_warn "Fcitx daemon is reachable after login" fcitx5-remote
  check_or_warn "Fcitx XIM environment imported into user manager (new login if absent)" bash -c \
    "systemctl --user show-environment | grep -Fxq 'XMODIFIERS=@im=fcitx'"
  check_or_warn "Secret Service is available for application credentials after login" \
    busctl --user --quiet status org.freedesktop.secrets
  check_or_warn "graphical session imports mise shims (log out once if absent)" bash -c \
    "systemctl --user show-environment | grep -Eq '^PATH=.*/\.local/share/mise/shims'"
else
  warn "no graphical session is active; live user-service, UWSM, Fcitx, and Secret Service checks are deferred until login"
fi

if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors -j >/dev/null 2>&1; then
  monitor_json=$(hyprctl monitors -j)
  if jq -e '.[] | select(.name == "eDP-1") | select(.width == 2880 and .height == 1800 and .refreshRate >= 119 and .scale == 1.5 and .x == 0 and .y == 240)' \
    <<<"$monitor_json" >/dev/null; then
    pass "internal display is 2880x1800@120, scale 1.5, at 0x240"
  else
    fail "internal display does not match the requested mode/scale/layout"
  fi

  if jq -e '.[] | select((.model // "") | contains("U2725QE"))' <<<"$monitor_json" >/dev/null; then
    if jq -e '.[] | select(.model | contains("U2725QE")) | select(.width == 3840 and .height == 2160 and .refreshRate >= 119 and .scale == 1.5 and .x == 1920 and .y == 0)' \
      <<<"$monitor_json" >/dev/null; then
      pass "Dell U2725QE is 3840x2160@120, scale 1.5, at 1920x0"
    else
      fail "connected Dell U2725QE does not match the requested mode/scale/layout"
    fi
  fi

  workspace_json=$(hyprctl workspaces -j)
  mapfile -t external_outputs < <(
    jq -r '
      map(select(
        .name != "eDP-1"
        and (.disabled // false) == false
        and (.mirrorOf // "none") == "none"
      ))
      | sort_by(.x // 0, .y // 0, .name)
      | .[].name
    ' <<<"$monitor_json"
  )
  if ((${#external_outputs[@]} > 0)); then
    pass "${#external_outputs[@]} external display(s) are active in extended mode"
  else
    warn "no external display is currently active; extended output routing was checked statically"
  fi
  workspace_layout_ok=true
  external_workspace_ids=(1 2 4)
  for index in "${!external_workspace_ids[@]}"; do
    workspace_id=${external_workspace_ids[$index]}
    expected_output=eDP-1
    if ((${#external_outputs[@]} > 0)); then
      expected_output=${external_outputs[$((index % ${#external_outputs[@]}))]}
    fi
    actual_output=$(
      jq -r --argjson id "$workspace_id" \
        'map(select(.id == $id))[0].monitor // empty' <<<"$workspace_json"
    )
    [[ $actual_output == "$expected_output" ]] || workspace_layout_ok=false
  done
  for workspace_id in 3 5; do
    actual_output=$(
      jq -r --argjson id "$workspace_id" \
        'map(select(.id == $id))[0].monitor // empty' <<<"$workspace_json"
    )
    [[ $actual_output == eDP-1 ]] || workspace_layout_ok=false
  done
  if [[ $workspace_layout_ok == true ]]; then
    pass "five workspaces match the requested external/internal output map"
  else
    fail "workspaces do not match the requested external/internal output map"
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

echo "==> Desktop expansion"
check "managed 16:9 cyberpunk wallpaper is deployed intact" \
  sha256_matches \
  "$HOME/.local/share/backgrounds/cyberpunk-library-16x9.jpg" \
  5b96bdca2bfc912164e2dec3ec5aec6f360e3c7ba6dabc7136afe39b618ce1cc
check "managed 16:10 cyberpunk wallpaper is deployed intact" \
  sha256_matches \
  "$HOME/.local/share/backgrounds/cyberpunk-library-16x10.jpg" \
  784c66002966e57a2ab0e5ae2413c3faee7b93a8c656d203899d41b25faffafb
check "Hyprpaper routes the 16:10 composition to eDP-1" \
  grep -Fq 'cyberpunk-library-16x10.jpg' "$HOME/.config/hypr/hyprpaper.conf"
check "Hyprlock keeps password and fingerprint authentication" \
  grep -Fq 'fingerprint {' "$HOME/.config/hypr/hyprlock.conf"
check "Waybar uses 40-pixel targets and the connectivity drawer" \
  jq -e '
    .height == 48 and
    ."margin-top" == 14 and
    (."modules-right" | index("group/connectivity") != null)
  ' \
  "$HOME/.config/waybar/config.jsonc"
check "Cyberdock exposes a six-pixel reveal target" \
  grep -Fq 'height: 6' "$HOME/.config/quickshell/cyberdock/shell.qml"
check "SwayNC exposes notifications and functional quick settings" \
  jq -e '
    ."widget-config".title.text == "Notifications" and
    (.widgets | index("buttons-grid#quick-settings") != null)
  ' \
  "$HOME/.config/swaync/config.json"
check "desktop GTK surfaces share the semantic palette" \
  test -f "$HOME/.config/cyberpunk-library/palette.css"
check "Ghostty enforces WCAG contrast" \
  grep -Fq 'minimum-contrast = 4.5' "$HOME/.config/ghostty/config.ghostty"
check "Zed applies the One Dark wallpaper-derived override" \
  jq -e '.theme_overrides["One Dark"]["editor.background"] == "#050623"' \
  "$HOME/.config/zed/settings.json"
check "GTK 3 uses the managed dark theme" \
  grep -Fq 'gtk-theme-name=Adwaita-dark' "$HOME/.config/gtk-3.0/settings.ini"
check "GTK 4 uses the managed dark theme" \
  grep -Fq 'gtk-theme-name=Adwaita-dark' "$HOME/.config/gtk-4.0/settings.ini"
check "cyberpunk SDDM theme payload is installed" \
  test -f /usr/share/sddm/themes/cyberpunk/Main.qml
check "cyberpunk SDDM wallpaper is installed" \
  test -f /usr/share/sddm/themes/cyberpunk/background.jpg
check "superseded SDDM wallpaper was removed" \
  test ! -e /usr/share/sddm/themes/cyberpunk/background.png

if [[ -f /etc/sddm.conf.d/20-cyberpunk-theme.conf ]]; then
  check "gated cyberpunk SDDM theme is selected" \
    grep -Eq '^[[:space:]]*Current=cyberpunk[[:space:]]*$' \
    /etc/sddm.conf.d/20-cyberpunk-theme.conf
else
  warn "cyberpunk SDDM selection remains gated pending manual acceptance"
fi

if [[ $(fc-match -f '%{family}\n' sans-serif 2>/dev/null) == Pretendard* ]]; then
  pass "Pretendard is the first sans-serif match"
else
  fail "Pretendard is not the first sans-serif match"
fi
if [[ $(fc-match -f '%{family}\n' monospace 2>/dev/null) == Jetendard* ]]; then
  pass "Jetendard is the first monospace match"
else
  fail "Jetendard is not the first monospace match"
fi

scaling_helper=$HOME/.local/bin/desktop-scaling-status
if systemctl --user is-active --quiet graphical-session.target &&
  hyprctl clients -j >/dev/null 2>&1; then
  if [[ -x $scaling_helper ]]; then
    "$scaling_helper"
    scaling_status=$?
    case $scaling_status in
      0) pass "all scaling acceptance clients have the intended backend" ;;
      2) warn "some scaling acceptance clients are not running" ;;
      *) fail "one or more live clients use the wrong display backend" ;;
    esac
  else
    fail "desktop scaling status helper is not deployed"
  fi
else
  warn "graphical IPC is unavailable; live application scaling checks are deferred"
fi

rclone_config=${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf
if [[ -f $rclone_config ]]; then
  if grep -q '^RCLONE_ENCRYPT_V[0-9]\+:' "$rclone_config"; then
    pass "rclone configuration is encrypted"
  else
    fail "rclone configuration exists but is not encrypted"
  fi
  if [[ $(stat -c '%a' "$rclone_config" 2>/dev/null) == 600 ]]; then
    pass "rclone configuration mode is 0600"
  else
    fail "rclone configuration mode is not 0600"
  fi
  for remote in google-drive proton-drive; do
    unit=rclone-$remote.service
    check "cloud mount unit enabled: $unit" \
      systemctl --user is-enabled --quiet "$unit"
    check "cloud mount unit active: $unit" \
      systemctl --user is-active --quiet "$unit"
  done
  check "Google Drive mount is present" mountpoint -q "$HOME/Cloud/GoogleDrive"
  check "Proton Drive mount is present" mountpoint -q "$HOME/Cloud/ProtonDrive"
else
  warn "cloud accounts are not onboarded; run rclone-cloud-setup all"
fi

bridge_marker=${XDG_STATE_HOME:-$HOME/.local/state}/protonmail-bridge/managed-service-enabled
bridge_status=$HOME/.local/bin/protonmail-bridge-status
if [[ -f $bridge_marker ]]; then
  if [[ -x $bridge_status ]] && "$bridge_status"; then
    pass "Proton Mail Bridge managed state is ready"
  else
    fail "Proton Mail Bridge onboarding exists but managed state is unhealthy"
  fi
else
  warn "Proton Mail Bridge is not onboarded; run protonmail-bridge-setup"
fi

if systemctl is-enabled --quiet warp-svc.service &&
  systemctl is-active --quiet warp-svc.service; then
  pass "Cloudflare One system daemon is enabled and active"
else
  fail "Cloudflare One daemon did not converge after the AUR phase"
fi
if systemctl --user is-enabled --quiet warp-taskbar.service; then
  pass "Cloudflare One taskbar unit is enabled"
else
  warn "Cloudflare One GUI enrollment is pending; run cloudflare-one-setup"
fi
cloudflare_status=$HOME/.local/bin/cloudflare-one-status
if [[ -x $cloudflare_status ]]; then
  "$cloudflare_status"
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
  pass "PDF default remains Google Chrome"
else
  fail "PDF default changed from the approved existing policy"
fi

rhwp_private_dir=$(
  find /opt/rhwp-desktop -type d ! -perm -0005 -print -quit 2>/dev/null || true
)
if [[ $(stat -c '%U:%G:%a' /opt/rhwp-desktop 2>/dev/null) == root:root:755 ]] &&
  [[ -z $rhwp_private_dir ]]; then
  pass "RHWP application directories are readable and traversable"
else
  fail "RHWP application directory ownership or modes are incorrect"
fi
if [[ $(stat -c '%U:%G:%a' /opt/rhwp-desktop/chrome-sandbox 2>/dev/null) == root:root:4755 ]]; then
  pass "RHWP Chromium sandbox has the reviewed root-owned 4755 mode"
else
  fail "RHWP Chromium sandbox owner or mode is incorrect"
fi

if xdg-mime query default application/vnd.hancom.hwpx 2>/dev/null |
  grep -Fxq rhwp-desktop.desktop; then
  pass "RHWP defaults were enabled after local acceptance"
else
  warn "RHWP HWP/HWPX defaults remain gated pending sample acceptance"
fi

graphics_status=$HOME/.local/bin/graphics-workflow-check
if [[ -x $graphics_status ]]; then
  if "$graphics_status" --status; then
    pass "GIMP and PhotoGIMP profiles remain isolated"
  else
    fail "graphics workflow status reported a managed-state failure"
  fi
else
  fail "graphics workflow status helper is not deployed"
fi

if [[ -z $(systemctl --failed --no-legend --plain 2>/dev/null) ]]; then
  pass "no failed system units"
else
  fail "one or more system units are failed"
fi

if [[ -z $(systemctl --user --failed --no-legend --plain 2>/dev/null) ]]; then
  pass "no failed user units"
else
  warn "one or more session/application user units are failed; inspect after the next graphical login"
fi

printf '\nPostflight result: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
printf 'Manual checks still required: sudo fingerprint, SDDM fingerprint, Hyprlock, Wi-Fi/WWAN handoff, Kakao login/files/clipboard/tray, and Parsec input/video.\n'

((failures == 0))
