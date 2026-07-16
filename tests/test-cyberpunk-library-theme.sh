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
  docs/assets/concepts/cyberpunk-notification-center.png \
  docs/assets/concepts/cyberpunk-lock-screen.png; do
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
  'hl.env("XCURSOR_THEME", "capitaine-cursors")' \
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
for shell_binding in \
  'local launcher = "cyberlauncher-toggle"' \
  'hl.bind(mainMod .. " + A"' \
  'hl.bind(mainMod .. " + SHIFT + A"' \
  'hl.bind(mainMod .. " + P", hl.dsp.exec_cmd("desktop-display-mode menu")' \
  'hl.bind(mainMod .. " + SHIFT + P", hl.dsp.window.pseudo()' \
  'desktop-brightness-control raise' \
  'desktop-brightness-control lower'; do
  assert_contains "$hyprland" "$shell_binding"
done
for focus_contract in \
  'local function configureHyprfocus()' \
  'hl.get_config("plugin.hyprfocus.enable")' \
  'hl.get_config("plugin.hyprfocus.mode")' \
  'keyboard_focus_animation = "flash"' \
  'mouse_focus_animation = "none"' \
  'mode = "flash"' \
  'fade_opacity = 0.94' \
  'hyprbars == "false" && hyprfocus == "true"' \
  'hyprpm reload && hyprctl reload config-only' \
  'hl.on("hyprland.start", reloadHyprlandPlugins)' \
  'hl.dsp.window.cycle_next({ next = nextWindow })' \
  'hl.on("config.reloaded", applyAppearancePreferences)' \
  'workspace = "e-1"' \
  'workspace = "e+1"'; do
  assert_contains "$hyprland" "$focus_contract"
done
assert_not_contains "$hyprland" 'shrink_percentage'
for animation_contract in \
  'leaf = "global", enabled = true, speed = 1.8' \
  'leaf = "border", enabled = true, speed = 1.1' \
  'leaf = "windowsIn", enabled = true, speed = 1.8' \
  'leaf = "windowsOut", enabled = true, speed = 1.2' \
  'leaf = "fade", enabled = true, speed = 1.4' \
  'leaf = "layers", enabled = true, speed = 1.8' \
  'leaf = "workspaces", enabled = true, speed = 2.0' \
  'leaf = "hyprfocusIn", enabled = true, speed = 1.6' \
  'leaf = "hyprfocusOut", enabled = true, speed = 1.1'; do
  assert_contains "$hyprland" "$animation_contract"
done
assert_not_contains "$hyprland" 'leaf = "global", enabled = true, speed = 8'
assert_not_contains "$hyprland" 'leaf = "hyprfocusIn", enabled = true, speed = 12'

hyprpaper=home/dot_config/hypr/hyprpaper.conf
assert_contains "$hyprpaper" 'monitor = eDP-1'
assert_contains "$hyprpaper" 'cyberpunk-library-16x10.jpg'
assert_contains "$hyprpaper" 'cyberpunk-library-16x9.jpg'

hyprlock=home/dot_config/hypr/hyprlock.conf
assert_contains "$hyprlock" 'monitor = eDP-1'
assert_contains "$hyprlock" "path = \$wallpaper16x10"
assert_contains "$hyprlock" "path = \$wallpaper16x9"
assert_count 2 "$hyprlock" 'brightness = 0.62'
assert_count 2 "$hyprlock" 'blur_passes = 1'
assert_count 2 "$hyprlock" 'blur_size = 3'
assert_contains "$hyprlock" 'size = 600, 360'
assert_contains "$hyprlock" "text = \$FPRINTPROMPT"
assert_contains "$hyprlock" "fail_text = \$FAIL"
assert_contains "$hyprlock" 'fade_on_empty = false'
assert_not_contains "$hyprlock" 'Fingerprint reader ready'
assert_not_contains "$hyprlock" "fail_text = \$PAMFAIL"
assert_contains "$hyprlock" 'shape {'
assert_contains "$hyprlock" 'color = rgba(10, 12, 62, 0.94)'
assert_contains "$hyprlock" 'rounding = 18'
assert_contains "$hyprlock" 'border_size = 1'
assert_contains "$hyprlock" 'outer_color = rgba(98, 216, 255, 1.0) rgba(154, 92, 255, 1.0) 45deg'
assert_contains "$hyprlock" 'check_color = rgba(119, 224, 198, 1.0)'
assert_contains "$hyprlock" 'fail_color = rgba(255, 93, 143, 1.0)'
assert_contains "$hyprlock" 'capslock_color = rgba(255, 184, 107, 1.0)'
assert_contains "$hyprlock" 'fingerprint {'
/usr/bin/python - "$hyprlock" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
backgrounds = re.findall(r"background\s*\{(.*?)\n\}", text, flags=re.DOTALL)
if len(backgrounds) != 2:
    raise SystemExit("expected exactly two Hyprlock background blocks")
specific, fallback = backgrounds
if "path = $wallpaper16x10" not in specific or "zindex = -1" not in specific:
    raise SystemExit("16:10 Hyprlock background does not have zindex -1")
if "path = $wallpaper16x9" not in fallback or "zindex = -2" not in fallback:
    raise SystemExit("16:9 Hyprlock fallback does not have zindex -2")
PY

waybar_config=home/dot_config/waybar/config.jsonc
jq -e '
  .height == 48 and
  ."margin-top" == 14 and
  ."margin-left" == 14 and
  ."margin-right" == 14 and
  ."modules-left" == ["ext/workspaces", "hyprland/window"] and
  ."modules-right" == ["custom/window-minimize", "custom/window-maximize", "custom/window-close", "custom/notification", "pulseaudio", "network", "bluetooth", "battery", "group/system", "custom/power"] and
  ."ext/workspaces"."all-outputs" == false and
  ."group/system".drawer."transition-duration" == 0 and
  ."group/system".modules == ["custom/system", "tray", "backlight", "custom/power-profile", "custom/wwan", "clock#date"] and
  ."custom/notification".tooltip == true and
  ."custom/power"."on-click" == "desktop-power menu" and
  ."hyprland/window".icon == true and
  ."custom/window-minimize"."on-click" == "desktop-window-action minimize --tracked" and
  ."custom/window-maximize"."on-click" == "desktop-window-action maximize --tracked" and
  ."custom/window-close"."on-click" == "desktop-window-action close --tracked" and
  ."network"."on-click" == "swaync-client -t -sw" and
  ."ext/workspaces"."format-icons"."3" == "DOCS"
' "$waybar_config" >/dev/null
waybar_style=home/dot_config/waybar/style.css
assert_contains "$waybar_style" '@import url("../cyberpunk-library/palette.css");'
assert_contains "$waybar_style" 'min-height: 40px;'
assert_contains "$waybar_style" 'min-width: 14px;'
assert_contains "$waybar_style" 'font-family: "Pretendard", "Noto Sans CJK KR", sans-serif;'
assert_contains "$waybar_style" 'background: @cyber_selection_strong;'
assert_contains "$waybar_style" 'color: alpha(@cyber_text_muted, 0.68);'
assert_contains "$waybar_style" 'box-shadow: inset 0 0 0 1px @cyber_focus;'
assert_contains "$waybar_style" 'box-shadow: inset 0 0 0 2px @cyber_focus;'
assert_contains "$waybar_style" '#battery.charging,'
assert_contains "$waybar_style" '#battery.critical {'
assert_contains "$waybar_style" 'border: 2px solid alpha(@cyber_critical, 0.86);'
assert_contains "$waybar_style" '#network.wifi,'
assert_contains "$waybar_style" '#bluetooth.connected,'
assert_not_contains "$waybar_style" '"JetBrainsMono Nerd Font"'
assert_not_contains "$waybar_style" 'battery-pulse'

palette=home/dot_config/cyberpunk-library/palette.css
for token in \
  '@define-color cyber_canvas #050623;' \
  '@define-color cyber_surface #0a0c3e;' \
  '@define-color cyber_header #101047;' \
  '@define-color cyber_focus #62d8ff;' \
  '@define-color cyber_selection #9a5cff;' \
  '@define-color cyber_selection_strong #6541b8;' \
  '@define-color cyber_on_selection #f2ecff;' \
  '@define-color cyber_critical #ff5d8f;'; do
  assert_contains "$palette" "$token"
done
/usr/bin/python - "$palette" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def color(token):
    match = re.search(rf"@define-color {token} (#[0-9a-fA-F]{{6}});", text)
    if not match:
        raise SystemExit(f"missing color token: {token}")
    value = match.group(1)
    return tuple(int(value[index:index + 2], 16) / 255 for index in (1, 3, 5))

def luminance(rgb):
    channels = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in rgb]
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

foreground = luminance(color("cyber_on_selection"))
background = luminance(color("cyber_selection_strong"))
ratio = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
if ratio < 4.5:
    raise SystemExit(f"selection contrast {ratio:.2f}:1 is below WCAG AA")
PY

dock=home/dot_config/quickshell/cyberdock/shell.qml
assert_contains "$dock" '//@ pragma IconTheme Papirus-Dark'
assert_contains "$dock" 'interval: 420'
assert_contains "$dock" 'height: 6'
assert_contains "$dock" 'height: 58'
assert_contains "$dock" 'width: app.id === "launcher" ? 54 : 44'
assert_contains "$dock" 'height: 46'
assert_contains "$dock" 'height: 40'
assert_contains "$dock" 'appItem.active ? 16 : 7'
assert_contains "$dock" 'height: 3'
assert_contains "$dock" 'readonly property color colorFocus: "#62d8ff"'
assert_contains "$dock" 'readonly property color colorSelectionStrong: "#6541b8"'
assert_contains "$dock" 'readonly property color colorOnSelection: "#f2ecff"'
assert_contains "$dock" 'readonly property color colorSelectionHover: "#cc6541b8"'
assert_contains "$dock" 'readonly property int radiusPanel: 14'
assert_contains "$dock" 'readonly property int radiusControl: 12'
assert_contains "$dock" 'readonly property int durationOsdVisible: 1400'
assert_contains "$dock" 'exclusiveZone: fullscreenActive ? 0 : 74'
assert_contains "$dock" 'readonly property var monitorState:'
assert_contains "$dock" 'Number(window.monitor) === Number(monitorState.id)'
assert_contains "$dock" 'workspaceName === String(activeWorkspace.name || "")'
assert_contains "$dock" '!root.launcherOpen && (!fullscreenActive || manualReveal)'
assert_contains "$dock" 'visible: !root.launcherOpen'
assert_contains "$dock" 'item: dockWindow.revealed ? dockHitArea : null'
assert_contains "$dock" 'item: contextMenu.visible ? contextMenu : null'
assert_contains "$dock" 'item: chooser.visible ? chooser : null'
assert_contains "$dock" 'aboveWindows: true'
assert_contains "$dock" 'focusable: false'
assert_contains "$dock" 'command: ["cyberdock-pins", "list", "--json"]'
assert_contains "$dock" 'path: root.pinsPath'
assert_contains "$dock" '"id": "unpin", "label": "Unpin from Dock"'
assert_contains "$dock" '"id": "move-left", "label": "Move Left"'
assert_contains "$dock" 'function reorderPinnedFromDrag(id, offsetX, slotWidth)'
assert_contains "$dock" 'DragHandler {'
assert_contains "$dock" 'grabPermissions: PointerHandler.CanTakeOverFromItems'
assert_not_contains "$dock" 'readonly property var pinnedApps:'
assert_contains "$dock" 'target: "launcher"'
assert_contains "$dock" 'target: "osd"'
assert_contains "$dock" 'FileView {'
assert_contains "$dock" 'path: root.appearanceStateHome + "/desktop-appearance/mode"'
assert_contains "$dock" 'watchChanges: true'
assert_contains "$dock" 'onFileChanged: reload()'
assert_contains "$dock" 'readonly property bool reducedMotion:'
assert_contains "$dock" 'readonly property bool reducedTransparency:'
assert_contains "$dock" 'colorCanvasOverlay: root.reducedTransparency'
assert_contains "$dock" 'colorLauncherSurface: root.reducedTransparency'
assert_count 8 "$dock" 'enabled: !root.reducedMotion'
assert_count 4 "$dock" 'theme: root.theme'
assert_count 4 "$dock" 'reducedMotion: root.reducedMotion'
assert_contains "$dock" 'border.color: root.theme.colorQuietBorder'
assert_contains "$dock" 'color: root.theme.colorRaisedOverlay'
assert_contains "$dock" '? "9+"'
assert_contains "$dock" 'function performPrimaryAction(app)'
assert_contains "$dock" 'dockWindow.performPrimaryAction(appItem.app)'
assert_contains "$dock" 'Math.max(0, Math.min(100, value))'

launcher=home/dot_config/quickshell/cyberdock/CyberLauncher.qml
assert_contains "$launcher" 'WlrLayershell.namespace: "cyberlauncher"'
assert_contains "$launcher" 'WlrKeyboardFocus.Exclusive'
assert_contains "$launcher" 'exclusionMode: ExclusionMode.Ignore'
assert_contains "$launcher" 'DesktopEntries.applications.values'
assert_contains "$launcher" 'ScriptModel {'
assert_contains "$launcher" 'function launch(entry)'
assert_contains "$launcher" 'required property var theme'
assert_contains "$launcher" 'required property bool reducedMotion'
assert_contains "$launcher" 'required property var pinIds'
assert_contains "$launcher" 'return applications.slice(0, 4);'
assert_contains "$launcher" 'filter(entry => searchableText(entry).includes(query)).slice(0, 7)'
assert_contains "$launcher" 'visible: launcher.queryEmpty && quickApps.values.length > 0'
assert_contains "$launcher" 'text: "빠른 앱"'
assert_contains "$launcher" 'text: "Ctrl+" + (index + 1)'
assert_contains "$launcher" 'launcher.launchQuick(event.key - Qt.Key_1)'
assert_contains "$launcher" 'if (searchField.inputMethodComposing)'
assert_contains "$launcher" 'acceptedButtons: Qt.LeftButton | Qt.RightButton'
assert_contains "$launcher" 'selectedTextColor: launcher.theme.colorOnSelection'
assert_contains "$launcher" 'selectionColor: launcher.theme.colorSelectionStrong'
assert_contains "$launcher" 'Math.max(960, Math.round(parent.width * 0.62))'
assert_contains "$launcher" 'Math.max(660, Math.round(parent.height * 0.64))'
assert_contains "$launcher" '? launcher.theme.colorSelectionHover'
assert_contains "$launcher" 'color: launcher.theme.colorTextMuted'
assert_contains "$launcher" 'Accessible.role: Accessible.EditableText'
assert_contains "$launcher" 'Accessible.role: Accessible.ListItem'
assert_contains "$launcher" 'Accessible.role: Accessible.Button'
assert_count 4 "$launcher" 'enabled: !launcher.reducedMotion'
assert_contains "$launcher" ': "Dock에 고정"'
assert_contains "$launcher" 'text: "Ctrl+P"'
assert_not_contains "$launcher" 'readonly property var favoriteOrder:'
assert_contains "$launcher" '↑↓  이동     Enter  실행'

osd=home/dot_config/quickshell/cyberdock/CyberOsd.qml
assert_contains "$osd" 'WlrLayershell.namespace: "cyberosd"'
assert_contains "$osd" 'osd.osdValue + "%"'
assert_contains "$osd" 'mask: Region {}'
assert_contains "$osd" 'visible: true'
assert_contains "$osd" 'readonly property bool showing:'
assert_contains "$osd" 'visible: osd.showing'
assert_contains "$osd" 'required property var theme'
assert_contains "$osd" 'required property bool reducedMotion'
assert_contains "$osd" 'xfpm-brightness-lcd'
assert_contains "$osd" 'audio-volume-muted'
assert_contains "$osd" 'Accessible.role: Accessible.ProgressBar'
assert_count 1 "$osd" 'enabled: !osd.reducedMotion'

display_overlay=home/dot_config/quickshell/cyberdock/DisplayModeOverlay.qml
assert_contains "$display_overlay" 'WlrLayershell.namespace: "cyberdisplay"'
assert_contains "$display_overlay" '"id": "mirror", "label": "복제"'
assert_contains "$display_overlay" '"label": "변경 내용 유지"'
assert_contains "$display_overlay" 'overlay.displayStatus.seconds_remaining'
assert_contains "$display_overlay" 'Accessible.role: Accessible.Button'

if grep -Eq '#[[:xdigit:]]{6,8}' "$launcher" "$osd"; then
  fail 'Launcher and OSD must consume the shared semantic theme instead of raw colors'
fi
/usr/bin/python - "$dock" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
colors = dict(re.findall(
    r'readonly property color (\w+): "(#[0-9a-fA-F]{6,8})"',
    text,
))

def parse(value):
    value = value.removeprefix("#")
    alpha = int(value[:2], 16) / 255 if len(value) == 8 else 1.0
    value = value[2:] if len(value) == 8 else value
    rgb = tuple(int(value[index:index + 2], 16) / 255 for index in (0, 2, 4))
    return rgb, alpha

def composite(foreground, background):
    front, alpha = parse(foreground)
    back, _ = parse(background)
    return tuple(alpha * front_value + (1 - alpha) * back_value
                 for front_value, back_value in zip(front, back))

def luminance(rgb):
    linear = [
        value / 12.92 if value <= 0.04045
        else ((value + 0.055) / 1.055) ** 2.4
        for value in rgb
    ]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

def contrast(foreground, background):
    values = sorted((luminance(foreground), luminance(background)), reverse=True)
    return (values[0] + 0.05) / (values[1] + 0.05)

surface, _ = parse(colors["colorSurface"])
canvas, _ = parse(colors["colorCanvas"])
selection, _ = parse(colors["colorSelectionStrong"])
checks = {
    "selected result secondary text": (
        parse(colors["colorTextMuted"])[0],
        composite(colors["colorSelectionSoft"], colors["colorSurface"]),
    ),
    "Open hover text": (
        parse(colors["colorText"])[0],
        composite(colors["colorSelectionHover"], colors["colorSurface"]),
    ),
    "on-selection text": (parse(colors["colorOnSelection"])[0], selection),
    "search placeholder": (
        composite(colors["colorTextSubtle"], colors["colorCanvas"]),
        canvas,
    ),
}
for label, pair in checks.items():
    ratio = contrast(*pair)
    if ratio < 4.5:
        raise SystemExit(f"{label} contrast is {ratio:.2f}:1, expected at least 4.5:1")
PY

hyprland=home/dot_config/hypr/hyprland.lua
assert_contains "$hyprland" 'name = "hide-xembed-tray-host"'
assert_contains "$hyprland" 'name = "route-kakaotalk-main"'
assert_not_contains "$hyprland" 'name = "hide-wine-shell-surface"'
assert_contains "$hyprland" 'workspace = "special:tray silent"'
assert_contains "$hyprland" 'no_focus = true'

swaync_config=home/dot_config/swaync/config.json
jq -e '
  ."$schema" == "/etc/xdg/swaync/configSchema.json" and
  .positionX == "right" and
  .positionY == "top" and
  ."control-center-margin-top" == 8 and
  ."transition-time" == 0 and
  ."control-center-width" == 460 and
  ."control-center-height" == 850 and
  ."fit-to-screen" == true and
  ."notification-inline-replies" == true and
  ."notification-grouping" == true and
  ."image-visibility" == "when-available" and
  ."widget-config".title.text == "Notifications" and
  (.widgets | index("buttons-grid#quick-settings") != null) and
  (.widgets | index("volume") != null) and
  (.widgets | index("backlight") != null) and
  (.widgets | index("mpris") != null) and
  ."widget-config"."buttons-grid#quick-settings"."buttons-per-row" == 3 and
  (."widget-config"."buttons-grid#quick-settings".actions | length) == 6 and
  ."widget-config"."buttons-grid#quick-settings".actions[0].label == "Wi-Fi" and
  ."widget-config"."buttons-grid#quick-settings".actions[0].command == "swaync-quick-setting apply wifi" and
  ."widget-config"."buttons-grid#quick-settings".actions[0]."update-command" == "swaync-quick-setting status wifi" and
  ."widget-config"."buttons-grid#quick-settings".actions[1].command == "swaync-quick-setting apply bluetooth" and
  ."widget-config"."buttons-grid#quick-settings".actions[1]."update-command" == "swaync-quick-setting status bluetooth" and
  ."widget-config"."buttons-grid#quick-settings".actions[2].command == "swaync-quick-setting apply night-light" and
  ."widget-config"."buttons-grid#quick-settings".actions[2]."update-command" == "swaync-quick-setting status night-light" and
  ."widget-config"."buttons-grid#quick-settings".actions[4].command == "hyprpwcenter" and
  ."widget-config"."buttons-grid#quick-settings".actions[5].command == "desktop-display-mode menu"
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
swaync_quick_setting=home/dot_local/bin/executable_swaync-quick-setting
bash -n "$swaync_quick_setting"
for setting in wifi bluetooth night-light; do
  case $(bash "$swaync_quick_setting" status "$setting") in
    true | false) ;;
    *) fail "$setting quick-setting status did not return a boolean" ;;
  esac
done
if SWAYNC_TOGGLE_STATE=invalid bash "$swaync_quick_setting" apply wifi >/dev/null 2>&1; then
  fail 'the quick-setting helper accepted an invalid toggle state'
fi
assert_contains home/dot_config/swaync/style.css \
  '@import url("../cyberpunk-library/palette.css");'
assert_contains home/dot_config/swaync/style.css 'border: 2px solid @cyber_critical;'
assert_contains home/dot_config/swaync/style.css '--noti-bg: 22, 17, 81;'
assert_contains home/dot_config/swaync/style.css '--noti-bg-alpha: 0.96;'
assert_contains home/dot_config/swaync/style.css 'font-family: "Pretendard", "Noto Sans CJK KR", sans-serif;'
assert_contains home/dot_config/swaync/style.css 'min-height: 82px;'
assert_contains home/dot_config/swaync/style.css 'background-size: 28px 28px;'
assert_contains home/dot_config/swaync/style.css '-gtk-icontheme("network-wireless-signal-excellent-symbolic")'
assert_contains home/dot_config/swaync/style.css 'min-width: 60px;'
assert_contains home/dot_config/swaync/style.css 'background-color: @cyber_selection_strong;'
assert_contains home/dot_config/swaync/style.css 'box-shadow: inset 0 0 0 2px @cyber_focus;'
assert_contains home/dot_config/swaync/style.css 'margin-right: 52px;'
assert_contains home/dot_config/swaync/style.css '--group-collapse-tranistion: opacity 0ms linear;'
assert_contains home/dot_config/swaync/style.css 'transition: none;'
assert_contains home/dot_config/swaync/style.css '.widget-mpris {'
assert_not_contains home/dot_config/swaync/style.css 'linear-gradient('
assert_not_contains home/dot_config/swaync/style.css '"JetBrainsMono Nerd Font"'
assert_contains home/dot_config/systemd/user/hyprsunset-quick.service \
  'ExecStart=/usr/bin/hyprsunset --temperature 4500'

if /usr/bin/python -c 'import gi' >/dev/null 2>&1; then
  /usr/bin/python - <<'PY'
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

provider = Gtk.CssProvider()
provider.load_from_path("home/dot_config/waybar/style.css")
provider = Gtk.CssProvider()
provider.load_from_path("home/dot_config/gtk-3.0/gtk.css")
PY
  /usr/bin/python - <<'PY'
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

provider = Gtk.CssProvider()
provider.load_from_path("home/dot_config/swaync/style.css")
provider = Gtk.CssProvider()
provider.load_from_path("home/dot_config/gtk-4.0/gtk.css")
PY
fi

assert_contains home/dot_config/hypr/hyprtoolkit.conf 'base = rgba(0a0c3ef2)'
assert_contains home/dot_config/hypr/hyprtoolkit.conf 'rounding_large = 18'

for shell_package in \
  adw-gtk-theme capitaine-cursors fcitx5-material-color hyprpwcenter nwg-displays; do
  grep -Fxq "$shell_package" packages/native.txt ||
    fail "missing desktop shell package: $shell_package"
done
grep -Fxq hyprlauncher packages/absent.txt || fail 'hyprlauncher is not retired'
if grep -Fxq hyprlauncher packages/native.txt; then
  fail 'hyprlauncher remains in the desired native package set'
fi

for plugin_dependency in cmake cpio; do
  grep -Fxq "$plugin_dependency" packages/native.txt ||
    fail "missing native hyprpm dependency: $plugin_dependency"
done
assert_contains home/run_after_30-enable-custom-user-services.sh.tmpl \
  "\"\$hyprbars_state/hyprland-abi\" \"\$hyprbars_state/setup.lock\""
assert_contains home/run_after_30-enable-custom-user-services.sh.tmpl \
  'hyprctl reload config-only'
assert_contains home/run_after_30-enable-custom-user-services.sh.tmpl \
  'disable --now hyprlauncher.service'
test ! -e home/dot_config/systemd/user/hyprlauncher.service
assert_contains scripts/postflight.sh 'hyprfocus_configured()'
assert_contains scripts/postflight.sh \
  'hyprfocus uses the managed schema and accessibility mode'

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
  assert_contains "$gtk_settings" 'gtk-theme-name=adw-gtk3-dark'
  assert_contains "$gtk_settings" 'gtk-icon-theme-name=Papirus-Dark'
  assert_contains "$gtk_settings" 'gtk-font-name=Pretendard 11'
  assert_contains "$gtk_settings" 'gtk-cursor-theme-name=capitaine-cursors'
done
for gtk_css in \
  home/dot_config/gtk-3.0/gtk.css \
  home/dot_config/gtk-4.0/gtk.css; do
  assert_contains "$gtk_css" '@import url("../cyberpunk-library/palette.css");'
  assert_contains "$gtk_css" '@define-color accent_bg_color @cyber_selection_strong;'
  assert_contains "$gtk_css" '@define-color accent_fg_color @cyber_on_selection;'
  assert_contains "$gtk_css" 'border-radius: 10px;'
  assert_contains "$gtk_css" 'background-color: @accent_bg_color;'
done
assert_contains home/dot_config/gtk-4.0/gtk.css ':root {'
assert_contains home/dot_config/gtk-4.0/gtk.css '--accent-bg-color: @cyber_selection_strong;'
assert_contains home/dot_config/gtk-4.0/gtk.css '--accent-fg-color: @cyber_on_selection;'
assert_contains home/dot_config/gtk-4.0/gtk.css '--accent-color: @cyber_focus;'
assert_not_contains home/dot_config/gtk-3.0/gtk.css '--accent-bg-color:'
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "color-scheme='prefer-dark'"
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "accent-color='purple'"
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "gtk-theme='adw-gtk3-dark'"
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "icon-theme='Papirus-Dark'"
assert_contains home/.chezmoitemplates/dconf-interface.ini \
  "cursor-theme='capitaine-cursors'"
assert_contains home/dot_config/xdg-desktop-portal/hyprland-portals.conf \
  'org.freedesktop.impl.portal.FileChooser=gtk'
fcitx_ui=home/dot_config/private_fcitx5/private_conf/private_classicui.conf
assert_contains "$fcitx_ui" 'Theme=Material-Color-DeepPurple'
assert_contains "$fcitx_ui" 'Font="Pretendard 12"'
assert_contains "$fcitx_ui" 'EnableFractionalScale=True'

sddm_tasks=ansible/roles/desktop_expansion/tasks/sddm.yml
sddm_qml=ansible/roles/desktop_expansion/files/sddm-cyberpunk/Main.qml
assert_contains "$sddm_tasks" 'cyberpunk-library-16x9.jpg'
assert_contains "$sddm_tasks" 'cyberpunk-library-16x10.jpg'
assert_contains "$sddm_tasks" 'dest: background-16x9.jpg'
assert_contains "$sddm_tasks" 'dest: background-16x10.jpg'
assert_contains "$sddm_tasks" 'path: "/usr/share/sddm/themes/cyberpunk/{{ item }}"'
assert_contains "$sddm_tasks" '- background.jpg'
assert_contains "$sddm_tasks" '- background.png'
assert_contains scripts/postflight.sh \
  'cyberpunk SDDM 16:9 wallpaper is installed intact'
assert_contains scripts/postflight.sh \
  '/usr/share/sddm/themes/cyberpunk/background-16x9.jpg'
assert_contains scripts/postflight.sh \
  'cyberpunk SDDM 16:10 wallpaper is installed intact'
assert_contains scripts/postflight.sh \
  '/usr/share/sddm/themes/cyberpunk/background-16x10.jpg'
assert_contains scripts/postflight.sh \
  '[[ ! -e /usr/share/sddm/themes/cyberpunk/background.jpg && ! -e /usr/share/sddm/themes/cyberpunk/background.png ]]'
assert_contains scripts/postflight.sh 'swaync_quick_settings_callable()'
assert_contains scripts/postflight.sh "[[ -x \$helper ]]"
assert_contains "$sddm_qml" 'source: root.width / Math.max(root.height, 1) < 1.7'
assert_contains "$sddm_qml" '? "background-16x10.jpg"'
assert_contains "$sddm_qml" ': "background-16x9.jpg"'
assert_contains "$sddm_qml" 'id: authPanel'
assert_contains "$sddm_qml" 'color: "#f00a0c3e"'
assert_contains "$sddm_qml" 'text: "Username"'
assert_contains "$sddm_qml" 'text: "Password"'
assert_contains "$sddm_qml" 'text: "Session"'
assert_contains "$sddm_qml" 'ComboBox {'
assert_contains "$sddm_qml" 'PasswordBox {'
assert_contains "$sddm_qml" 'function submitLogin()'
assert_contains "$sddm_qml" 'if (authenticating)'
assert_contains "$sddm_qml" 'function onLoginSucceeded()'
assert_contains "$sddm_qml" 'function onLoginFailed()'
assert_contains "$sddm_qml" 'function onInformationMessage(message)'
assert_contains "$sddm_qml" 'Keys.onPressed: function(keyEvent)'
assert_contains "$sddm_qml" 'greeter.login(username.text, password.text, sessionIndex)'
assert_contains "$sddm_qml" 'enabled: !root.authenticating'
assert_contains "$sddm_qml" 'text: "⌄"'
for navigation_contract in \
  'KeyNavigation.tab: password' \
  'KeyNavigation.tab: session' \
  'KeyNavigation.tab: login' \
  'KeyNavigation.tab: suspend' \
  'KeyNavigation.tab: reboot' \
  'KeyNavigation.tab: powerOff' \
  'KeyNavigation.tab: username' \
  'KeyNavigation.backtab: powerOff' \
  'KeyNavigation.backtab: username' \
  'KeyNavigation.backtab: password' \
  'KeyNavigation.backtab: session' \
  'KeyNavigation.backtab: login' \
  'KeyNavigation.backtab: suspend' \
  'KeyNavigation.backtab: reboot'; do
  assert_contains "$sddm_qml" "$navigation_contract"
done
for focus_contract in \
  'username.activeFocus ? 2 : 0' \
  'password.activeFocus ? 2 : 0' \
  'session.activeFocus ? 2 : 0' \
  'login.activeFocus ? 2 : 0' \
  'suspend.activeFocus ? 2 : 0' \
  'reboot.activeFocus ? 2 : 0' \
  'powerOff.activeFocus ? 2 : 0'; do
  assert_contains "$sddm_qml" "$focus_contract"
done
assert_count 3 "$sddm_qml" 'height: 44'
assert_contains "$sddm_qml" 'visible: root.greeter.canSuspend'
assert_contains "$sddm_qml" 'visible: root.greeter.canReboot'
assert_contains "$sddm_qml" 'visible: root.greeter.canPowerOff'
assert_contains "$sddm_qml" 'root.greeter.suspend()'
assert_contains "$sddm_qml" 'root.greeter.reboot()'
assert_contains "$sddm_qml" 'root.greeter.powerOff()'
assert_contains ansible/roles/desktop_expansion/defaults/main.yml \
  'desktop_expansion_sddm_theme_enabled: false'
assert_contains ansible/inventory/host_vars/tpx1c13.yml \
  'desktop_expansion_sddm_theme_enabled: true'

printf 'Cyberpunk Library theme tests passed.\n'
