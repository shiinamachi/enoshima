#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

fail() {
  printf 'Cyberpunk Library theme test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local path=$1
  local expected=$2
  grep -Fq -- "$expected" "$path" ||
    fail "$path does not contain: $expected"
}

assert_count() {
  local expected_count=$1
  local path=$2
  local expected=$3
  local actual_count
  actual_count=$(grep -Fc -- "$expected" "$path")
  [[ $actual_count == "$expected_count" ]] ||
    fail "$path contains '$expected' $actual_count times, expected $expected_count"
}

asset_dimensions() {
  local path=$1
  if command -v identify >/dev/null 2>&1; then
    identify -format '%wx%h' "$path"
  else
    file --brief -- "$path" | grep -oE '[0-9]+x[0-9]+' | tail -n 1
  fi
}

external_asset=home/dot_local/share/backgrounds/cyberpunk-library-16x9.jpg
internal_asset=home/dot_local/share/backgrounds/cyberpunk-library-16x10.jpg

printf '%s  %s\n' \
  '5b96bdca2bfc912164e2dec3ec5aec6f360e3c7ba6dabc7136afe39b618ce1cc' \
  "$external_asset" | sha256sum --check --status
printf '%s  %s\n' \
  '784c66002966e57a2ab0e5ae2413c3faee7b93a8c656d203899d41b25faffafb' \
  "$internal_asset" | sha256sum --check --status
[[ $(asset_dimensions "$external_asset") == 3840x2160 ]] ||
  fail 'the external wallpaper is not 3840x2160'
[[ $(asset_dimensions "$internal_asset") == 2880x1800 ]] ||
  fail 'the internal wallpaper is not 2880x1800'

hyprland=home/dot_config/hypr/hyprland.lua
for expected in \
  'gaps_in = 7' \
  'gaps_out = 14' \
  'rounding = 12' \
  'rounding_power = 2.4' \
  'size = 7' \
  'passes = 2' \
  'xray = true' \
  'popups = true' \
  'input_methods = false' \
  '"rgba(62d8ffff)"' \
  '"rgba(9a5cffff)"' \
  '"rgba(e56bffff)"' \
  'inactive_border = "rgba(6d8cff66)"'; do
  assert_contains "$hyprland" "$expected"
done
for binding in \
  'hl.bind(mainMod .. " + C"' \
  'hl.bind(mainMod .. " + F"' \
  'hl.bind(mainMod .. " + N"' \
  'hl.bind(mainMod .. " + SHIFT + N"'; do
  assert_contains "$hyprland" "$binding"
done

hyprpaper=home/dot_config/hypr/hyprpaper.conf
assert_contains "$hyprpaper" 'monitor = eDP-1'
assert_contains "$hyprpaper" 'cyberpunk-library-16x10.jpg'
assert_contains "$hyprpaper" 'cyberpunk-library-16x9.jpg'

hyprlock=home/dot_config/hypr/hyprlock.conf
assert_contains "$hyprlock" 'monitor = eDP-1'
assert_contains "$hyprlock" "path = \$wallpaper16x10"
assert_contains "$hyprlock" "path = \$wallpaper16x9"
assert_count 2 "$hyprlock" 'brightness = 0.47'
assert_count 2 "$hyprlock" 'blur_passes = 2'
assert_contains "$hyprlock" 'shape {'
assert_contains "$hyprlock" 'check_color = rgba(119, 224, 198, 1.0)'
assert_contains "$hyprlock" 'fail_color = rgba(255, 93, 143, 1.0)'
assert_contains "$hyprlock" 'capslock_color = rgba(255, 184, 107, 1.0)'
assert_contains "$hyprlock" 'fingerprint {'

waybar_config=home/dot_config/waybar/config.jsonc
jq -e '
  .height == 42 and
  ."margin-top" == 14 and
  ."margin-left" == 14 and
  ."margin-right" == 14 and
  ."ext/workspaces"."all-outputs" == false and
  (."modules-right" | index("custom/wwan") != null) and
  (."modules-right" | index("network") != null) and
  (."modules-right" | index("bluetooth") != null) and
  (."modules-right" | index("battery") != null)
' "$waybar_config" >/dev/null
waybar_style=home/dot_config/waybar/style.css
assert_contains "$waybar_style" 'min-height: 30px;'
assert_contains "$waybar_style" 'linear-gradient(110deg, #62d8ff, #9a5cff 54%, #e56bff)'
assert_contains "$waybar_style" '#battery.charging,'
assert_contains "$waybar_style" '#battery.critical {'
assert_contains "$waybar_style" 'border: 1px solid rgba(255, 93, 143, 0.78);'

dock=home/dot_config/quickshell/cyberdock/shell.qml
assert_contains "$dock" '//@ pragma IconTheme Papirus-Dark'
assert_contains "$dock" 'interval: 420'
assert_contains "$dock" 'height: 3'
assert_contains "$dock" 'height: 58'
assert_contains "$dock" 'width: 40'
assert_contains "$dock" 'height: 46'
assert_contains "$dock" 'appItem.active ? 16 : 7'
assert_contains "$dock" 'height: 3'
assert_contains "$dock" 'exclusiveZone: 0'
assert_contains "$dock" 'aboveWindows: true'
assert_contains "$dock" 'focusable: false'

swaync_config=home/dot_config/swaync/config.json
jq -e '
  .positionX == "right" and
  .positionY == "top" and
  ."control-center-margin-top" == 64 and
  ."control-center-height" == 660 and
  ."notification-grouping" == true and
  ."image-visibility" == "when-available" and
  ."widget-config".title.text == "NOTIFICATION // STREAM"
' "$swaync_config" >/dev/null
assert_contains home/dot_config/swaync/style.css 'border: 2px solid #ff72bd;'
assert_contains home/dot_config/swaync/style.css \
  'linear-gradient(110deg, #62d8ff, #9a5cff 54%, #e56bff)'

ghostty=home/dot_config/ghostty/config.ghostty
for expected in \
  'background = #050623' \
  'foreground = #F2ECFF' \
  'minimum-contrast = 4.5' \
  'background-opacity = 0.94' \
  'window-padding-x = 12' \
  'window-padding-y = 10' \
  'window-padding-balance = true'; do
  assert_contains "$ghostty" "$expected"
done
assert_count 16 "$ghostty" 'palette = '
if command -v ghostty >/dev/null 2>&1; then
  ghostty +validate-config --config-file="$repo_root/$ghostty"
fi

jq -e '
  .theme.mode == "dark" and
  .theme.light == "One Dark" and
  .theme.dark == "One Dark" and
  .theme_overrides["One Dark"]["editor.background"] == "#050623" and
  (.theme_overrides["One Dark"].accents | length) == 7
' home/dot_config/zed/settings.json >/dev/null

cmp home/dot_config/gtk-3.0/settings.ini home/dot_config/gtk-4.0/settings.ini
for gtk_settings in \
  home/dot_config/gtk-3.0/settings.ini \
  home/dot_config/gtk-4.0/settings.ini; do
  assert_contains "$gtk_settings" 'gtk-theme-name=Adwaita-dark'
  assert_contains "$gtk_settings" 'gtk-icon-theme-name=Papirus-Dark'
  assert_contains "$gtk_settings" 'gtk-font-name=Pretendard 11'
done
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "color-scheme='prefer-dark'"
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "gtk-theme='Adwaita-dark'"
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "icon-theme='Papirus-Dark'"

sddm_tasks=ansible/roles/desktop_expansion/tasks/sddm.yml
sddm_qml=ansible/roles/desktop_expansion/files/sddm-cyberpunk/Main.qml
assert_contains "$sddm_tasks" 'cyberpunk-library-16x9.jpg'
assert_contains "$sddm_tasks" 'dest: /usr/share/sddm/themes/cyberpunk/background.jpg'
assert_contains "$sddm_tasks" 'path: /usr/share/sddm/themes/cyberpunk/background.png'
assert_contains "$sddm_qml" 'source: "background.jpg"'
assert_contains "$sddm_qml" 'ComboBox {'
assert_contains "$sddm_qml" 'PasswordBox {'
assert_contains "$sddm_qml" 'sddm.suspend()'
assert_contains "$sddm_qml" 'sddm.reboot()'
assert_contains "$sddm_qml" 'sddm.powerOff()'
assert_contains ansible/roles/desktop_expansion/defaults/main.yml \
  'desktop_expansion_sddm_theme_enabled: false'

printf 'Cyberpunk Library theme tests passed.\n'
