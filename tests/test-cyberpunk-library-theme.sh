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

assert_not_contains() {
  local path=$1
  local unexpected=$2
  if grep -Fq -- "$unexpected" "$path"; then
    fail "$path unexpectedly contains: $unexpected"
  fi
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

for concept_asset in \
  docs/assets/concepts/cyberpunk-desktop-shell.png \
  docs/assets/concepts/cyberpunk-launcher.png \
  docs/assets/concepts/cyberpunk-notification-center.png; do
  dimensions=$(asset_dimensions "$concept_asset")
  width=${dimensions%x*}
  height=${dimensions#*x}
  ((width >= 1500 && height >= 900)) ||
    fail "$concept_asset is smaller than the reviewed concept-art baseline"
done

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
  'inactive_border = "rgba(6d8cff44)"'; do
  assert_contains "$hyprland" "$expected"
done
assert_not_contains "$hyprland" 'name = "waybar-blur"'
for binding in \
  'hl.bind("ALT + Tab"' \
  'hl.bind("ALT + SHIFT + Tab"' \
  'hl.bind(mainMod .. " + C"' \
  'hl.bind(mainMod .. " + F"' \
  'hl.bind(mainMod .. " + N"' \
  'hl.bind(mainMod .. " + SHIFT + N"'; do
  assert_contains "$hyprland" "$binding"
done
for focus_contract in \
  'local function configureHyprfocus()' \
  'hl.get_config("plugin.hyprfocus.mode")' \
  'mode = "flash"' \
  'fade_opacity = 0.94' \
  'hl.on("hyprland.start", reloadHyprlandPlugins)' \
  'hl.dsp.window.cycle_next({ next = nextWindow })' \
  'hl.on("config.reloaded", applyAppearancePreferences)' \
  'workspace = "e-1"' \
  'workspace = "e+1"'; do
  assert_contains "$hyprland" "$focus_contract"
done
for unsupported_hyprfocus_option in \
  'plugin.hyprfocus.enable' \
  'animate_floating' \
  'keyboard_focus_animation' \
  'mouse_focus_animation' \
  'shrink_percentage'; do
  assert_not_contains "$hyprland" "$unsupported_hyprfocus_option"
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
  .height == 48 and
  ."margin-top" == 14 and
  ."margin-left" == 14 and
  ."margin-right" == 14 and
  ."ext/workspaces"."all-outputs" == false and
  (."modules-right" | index("group/connectivity") != null) and
  ."group/connectivity".drawer."transition-duration" == 180 and
  ."group/connectivity".modules == ["network", "custom/wwan", "bluetooth"] and
  ."custom/notification".tooltip == true and
  ."ext/workspaces"."format-icons"."3" == "3  DOCS"
' "$waybar_config" >/dev/null
waybar_style=home/dot_config/waybar/style.css
assert_contains "$waybar_style" '@import url("../cyberpunk-library/palette.css");'
assert_contains "$waybar_style" 'min-height: 40px;'
assert_contains "$waybar_style" 'linear-gradient(110deg, @cyber_focus, @cyber_selection)'
assert_contains "$waybar_style" '#battery.charging,'
assert_contains "$waybar_style" '#battery.critical {'
assert_contains "$waybar_style" 'border: 2px solid alpha(@cyber_critical, 0.86);'
assert_not_contains "$waybar_style" 'battery-pulse'

palette=home/dot_config/cyberpunk-library/palette.css
for token in \
  '@define-color cyber_canvas #050623;' \
  '@define-color cyber_surface #0a0c3e;' \
  '@define-color cyber_focus #62d8ff;' \
  '@define-color cyber_selection #9a5cff;' \
  '@define-color cyber_critical #ff5d8f;'; do
  assert_contains "$palette" "$token"
done

dock=home/dot_config/quickshell/cyberdock/shell.qml
assert_contains "$dock" '//@ pragma IconTheme Papirus-Dark'
assert_contains "$dock" 'interval: 420'
assert_contains "$dock" 'height: 6'
assert_contains "$dock" 'height: 58'
assert_contains "$dock" 'width: 44'
assert_contains "$dock" 'height: 46'
assert_contains "$dock" 'height: 40'
assert_contains "$dock" 'appItem.active ? 16 : 7'
assert_contains "$dock" 'height: 3'
assert_contains "$dock" 'readonly property color colorFocus: "#62d8ff"'
assert_contains "$dock" 'exclusiveZone: 0'
assert_contains "$dock" 'aboveWindows: true'
assert_contains "$dock" 'focusable: false'

swaync_config=home/dot_config/swaync/config.json
jq -e '
  .positionX == "right" and
  .positionY == "top" and
  ."control-center-margin-top" == 70 and
  ."control-center-width" == 460 and
  ."control-center-height" == 780 and
  ."notification-inline-replies" == true and
  ."notification-grouping" == true and
  ."image-visibility" == "when-available" and
  ."widget-config".title.text == "Notifications" and
  (.widgets | index("buttons-grid#quick-settings") != null) and
  (.widgets | index("volume") != null) and
  (.widgets | index("backlight") != null) and
  ."widget-config"."buttons-grid#quick-settings"."buttons-per-row" == 3
' "$swaync_config" >/dev/null
/usr/bin/python - "$waybar_config" "$swaync_config" <<'PY'
import pathlib
import sys

for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    for character in path.read_text(encoding="utf-8"):
        if 0xF000 <= ord(character) <= 0xF057:
            raise SystemExit(
                f"{path} uses U+{ord(character):04X}, which collides with Pretendard's PUA glyphs"
            )
PY
while IFS= read -r quick_setting_command; do
  bash -n -c "$quick_setting_command"
done < <(
  jq -r '
    ."widget-config"."buttons-grid#quick-settings".actions[]
    | .command, ."update-command"
  ' "$swaync_config"
)
assert_contains home/dot_config/swaync/style.css \
  '@import url("../cyberpunk-library/palette.css");'
assert_contains home/dot_config/swaync/style.css 'border: 2px solid @cyber_critical;'
assert_contains home/dot_config/swaync/style.css \
  'linear-gradient(110deg, @cyber_focus, @cyber_selection)'
assert_contains home/dot_config/swaync/style.css 'min-height: 64px;'
assert_contains home/dot_config/systemd/user/hyprsunset-quick.service \
  'ExecStart=/usr/bin/hyprsunset --temperature 4500'

if /usr/bin/python -c 'import gi' >/dev/null 2>&1; then
  /usr/bin/python - <<'PY'
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

provider = Gtk.CssProvider()
provider.load_from_path("home/dot_config/waybar/style.css")
PY
  /usr/bin/python - <<'PY'
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

provider = Gtk.CssProvider()
provider.load_from_path("home/dot_config/swaync/style.css")
PY
fi

hyprlauncher=home/dot_config/hypr/hyprlauncher.conf
assert_contains "$hyprlauncher" 'unicode_prefix = .'
assert_contains "$hyprlauncher" 'math_prefix = ='
assert_contains "$hyprlauncher" "font_prefix = '"
assert_contains "$hyprlauncher" 'window_size = 760 480'
assert_contains home/dot_config/hypr/hyprtoolkit.conf 'base = rgba(0a0c3ef2)'
assert_contains home/dot_config/hypr/hyprtoolkit.conf 'rounding_large = 18'

for plugin_dependency in cmake cpio; do
  grep -Fxq "$plugin_dependency" packages/native.txt ||
    fail "missing native hyprpm dependency: $plugin_dependency"
done
assert_contains home/run_after_30-enable-custom-user-services.sh.tmpl \
  "\"\$hyprbars_state/hyprland-abi\" \"\$hyprbars_state/setup.lock\""

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
