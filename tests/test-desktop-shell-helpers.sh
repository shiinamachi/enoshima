#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
osd_helper=$repo_root/home/dot_local/bin/executable_cyberosd-show
launcher_helper=$repo_root/home/dot_local/bin/executable_cyberlauncher-toggle
brightness_helper=$repo_root/home/dot_local/bin/executable_desktop-brightness-control
microphone_helper=$repo_root/home/dot_local/bin/executable_desktop-microphone-control
keyboard_helper=$repo_root/home/dot_local/bin/executable_desktop-keyboard-backlight-control
airplane_helper=$repo_root/home/dot_local/bin/executable_desktop-airplane-control
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'test-desktop-shell-helpers: %s\n' "$*" >&2
  exit 1
}

cat >"$work/qs" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${QS_LOG:?}"
FAKE

cat >"$work/wpctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'Volume: 0.42 [MUTED]'
FAKE

cat >"$work/brightnessctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' -m '* ]]; then
  printf '%s\n' 'intel_backlight,backlight,934,73%,1280'
else
  printf '%s\n' "$*" >>"${BRIGHTNESS_LOG:?}"
fi
FAKE

cat >"$work/nmcli" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == '-t -f WIFI,WWAN radio' ]]; then
  printf 'disabled:disabled\n'
elif [[ $* == '-t -f WIFI radio' ]]; then
  printf 'enabled\n'
else
  printf '%s\n' "$*" >>"${NMCLI_LOG:?}"
fi
FAKE

cat >"$work/osd" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${OSD_LOG:?}"
FAKE

chmod 0700 "$work/qs" "$work/wpctl" "$work/brightnessctl" "$work/nmcli" "$work/osd"

export HOME=$work/home
export XDG_CONFIG_HOME=$HOME/.config
export QS_LOG=$work/qs.log
export BRIGHTNESS_LOG=$work/brightness.log
export OSD_LOG=$work/osd.log
export NMCLI_LOG=$work/nmcli.log
mkdir -p "$HOME"

printf '%s\n' '==> OSD values are normalized before IPC'
CYBEROSD_QS=$work/qs \
  CYBEROSD_WPCTL=$work/wpctl \
  bash "$osd_helper" volume
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- osd show volume 42 true" \
  "$QS_LOG" || fail 'volume OSD IPC payload is wrong'

CYBEROSD_QS=$work/qs \
  CYBEROSD_BRIGHTNESSCTL=$work/brightnessctl \
  bash "$osd_helper" brightness
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- osd show brightness 73 false" \
  "$QS_LOG" || fail 'brightness OSD IPC payload is wrong'

CYBEROSD_QS=$work/qs CYBEROSD_WPCTL=$work/wpctl \
  bash "$osd_helper" microphone
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- osd show microphone 42 true" \
  "$QS_LOG" || fail 'microphone OSD IPC payload is wrong'

CYBEROSD_QS=$work/qs CYBEROSD_BRIGHTNESSCTL=$work/brightnessctl \
  bash "$osd_helper" keyboard-backlight
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- osd show keyboard-backlight 73 false" \
  "$QS_LOG" || fail 'keyboard OSD IPC payload is wrong'

CYBEROSD_QS=$work/qs CYBEROSD_NMCLI=$work/nmcli \
  bash "$osd_helper" airplane-mode
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- osd show airplane-mode 100 true" \
  "$QS_LOG" || fail 'airplane OSD IPC payload is wrong'

CYBEROSD_QS=$work/qs bash "$osd_helper" show \
  --kind volume --value 37 --state normal
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- osd show volume 37 false" \
  "$QS_LOG" || fail 'explicit OSD event payload is wrong'

if CYBEROSD_QS=$work/qs bash "$osd_helper" invalid 2>/dev/null; then
  fail 'invalid OSD kind unexpectedly succeeded'
fi

printf '%s\n' '==> launcher toggle addresses the managed Quickshell instance'
CYBERLAUNCHER_QS=$work/qs bash "$launcher_helper"
grep -Fxq -- \
  "-p $HOME/.config/quickshell/cyberdock ipc call -- launcher toggle" \
  "$QS_LOG" || fail 'launcher IPC target is wrong'

printf '%s\n' '==> brightness changes always request visual feedback'
DESKTOP_BRIGHTNESSCTL=$work/brightnessctl \
  DESKTOP_BRIGHTNESS_OSD=$work/osd \
  bash "$brightness_helper" raise
DESKTOP_BRIGHTNESSCTL=$work/brightnessctl \
  DESKTOP_BRIGHTNESS_OSD=$work/osd \
  bash "$brightness_helper" lower
grep -Fxq -- '-e4 -n2 set 5%+' "$BRIGHTNESS_LOG" ||
  fail 'brightness raise command is wrong'
grep -Fxq -- '-e4 -n2 set 5%-' "$BRIGHTNESS_LOG" ||
  fail 'brightness lower command is wrong'
[[ $(grep -Fc brightness "$OSD_LOG") -eq 2 ]] ||
  fail 'brightness helper did not request both OSD updates'

DESKTOP_MICROPHONE_WPCTL=$work/wpctl DESKTOP_MICROPHONE_OSD=$work/osd \
  bash "$microphone_helper" toggle-mute
grep -Fxq microphone "$OSD_LOG" || fail 'microphone control omitted OSD feedback'

DESKTOP_KEYBOARD_BRIGHTNESSCTL=$work/brightnessctl \
  DESKTOP_KEYBOARD_BRIGHTNESS_OSD=$work/osd \
  bash "$keyboard_helper" raise
grep -Fxq keyboard-backlight "$OSD_LOG" || fail 'keyboard control omitted OSD feedback'

DESKTOP_AIRPLANE_NMCLI=$work/nmcli DESKTOP_AIRPLANE_OSD=$work/osd \
  bash "$airplane_helper" toggle
grep -Fxq 'radio all off' "$NMCLI_LOG" || fail 'airplane toggle did not disable radios'
grep -Fxq airplane-mode "$OSD_LOG" || fail 'airplane control omitted OSD feedback'

printf 'Desktop shell helper tests passed.\n'
