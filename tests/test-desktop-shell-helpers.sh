#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
osd_helper=$repo_root/home/dot_local/bin/executable_cyberosd-show
launcher_helper=$repo_root/home/dot_local/bin/executable_cyberlauncher-toggle
brightness_helper=$repo_root/home/dot_local/bin/executable_desktop-brightness-control
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
if [[ ${1:-} == -m ]]; then
  printf '%s\n' 'intel_backlight,backlight,934,73%,1280'
else
  printf '%s\n' "$*" >>"${BRIGHTNESS_LOG:?}"
fi
FAKE

cat >"$work/osd" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${OSD_LOG:?}"
FAKE

chmod 0700 "$work/qs" "$work/wpctl" "$work/brightnessctl" "$work/osd"

export HOME=$work/home
export XDG_CONFIG_HOME=$HOME/.config
export QS_LOG=$work/qs.log
export BRIGHTNESS_LOG=$work/brightness.log
export OSD_LOG=$work/osd.log
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

printf 'Desktop shell helper tests passed.\n'
