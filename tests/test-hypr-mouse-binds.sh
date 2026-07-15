#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
doctor=$repo_root/home/dot_local/bin/executable_hypr-window-control-doctor
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HYPR_WINDOW_DOCTOR_HYPRCTL=$work/hyprctl
export MOUSE_TEST_GRAB_AREA=24
hypr_config=$repo_root/home/dot_config/hypr/hyprland.lua

fail() {
  printf 'test-hypr-mouse-binds: %s\n' "$*" >&2
  exit 1
}

cat >"$HYPR_WINDOW_DOCTOR_HYPRCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  binds)
    [[ ${2:-} == -j ]]
    cat <<'JSON'
[
  {"mouse":true,"modmask":64,"key":"mouse:272","description":"Move window with pointer"},
  {"mouse":true,"modmask":64,"key":"mouse:273","description":"Resize window with pointer"}
]
JSON
    ;;
  devices)
    [[ ${2:-} == -j ]]
    printf '{"mice":[{"name":"touchpad","address":"0x1"},{"name":"trackpoint","address":"0x2"}]}\n'
    ;;
  activewindow)
    [[ ${2:-} == -j ]]
    printf '{"address":"0xaaa","class":"test","title":"Test"}\n'
    ;;
  submap) printf '"default"\n' ;;
  getoption)
    case ${2:-} in
      general:resize_on_border) printf '{"bool":true}\n' ;;
      general:extend_border_grab_area) printf '{"int":%s}\n' "${MOUSE_TEST_GRAB_AREA:-24}" ;;
      *) exit 64 ;;
    esac
    ;;
  version) printf 'Hyprland test\n' ;;
  *) exit 64 ;;
esac
FAKE
chmod 0700 "$HYPR_WINDOW_DOCTOR_HYPRCTL"

grep -Fq 'extend_border_grab_area = 24' "$hypr_config" ||
  fail 'managed border grab area is not 24'
grep -Fq 'description = "Move window with pointer"' "$hypr_config" ||
  fail 'managed move bind has no discoverable description'
grep -Fq 'description = "Resize window with pointer"' "$hypr_config" ||
  fail 'managed resize bind has no discoverable description'

printf '%s\n' '==> effective runtime binds and border resizing are healthy'
jq -e '
  .healthy and .effective.move and .effective.resize and
  .effective.resize_on_border and .effective.border_grab_area == 24 and
  (.mice | length) == 2
' < <(bash "$doctor" --json) >/dev/null || fail 'healthy mouse control report is invalid'

printf '%s\n' '==> an undersized effective border area fails the doctor'
if MOUSE_TEST_GRAB_AREA=15 bash "$doctor" --json >/dev/null 2>&1; then
  fail 'undersized border grab area unexpectedly passed'
fi

printf 'Hyprland mouse binding tests passed.\n'
