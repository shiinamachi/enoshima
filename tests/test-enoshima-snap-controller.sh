#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
controller=$repo_root/home/dot_local/bin/executable_enoshima-snap-controller
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/runtime" "$tmp/bin"
cat >"$tmp/bin/hyprctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'monitors -j')
    printf '%s\n' '[
      {"id":0,"name":"eDP-1","x":0,"y":0,"width":1920,"height":1080,"scale":1,"reserved":[48,74,0,0]},
      {"id":1,"name":"DP-1","x":1920,"y":0,"width":2880,"height":1800,"scale":1.5,"reserved":[0,0,0,0]}
    ]'
    ;;
  'clients -j')
    printf '%s\n' '[
      {"address":"0xabc","monitor":0},
      {"address":"0xdef","monitor":1}
    ]'
    ;;
  'activewindow -j')
    printf '%s\n' '{"address":"0xabc","monitor":0}'
    ;;
  dispatch*)
    printf '%s\n' "$*" >>"$SNAP_DISPATCH_LOG"
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/hyprctl"

export XDG_RUNTIME_DIR=$tmp/runtime
export ENOSHIMA_SNAP_HYPRCTL=$tmp/bin/hyprctl
export ENOSHIMA_WINDOW_INTERACTION_CONFIG=$repo_root/home/dot_config/enoshima/window-interaction.yaml
export SNAP_DISPATCH_LOG=$tmp/dispatch.log

"$controller" preview --address 0xabc --x 4 --y 540
jq -e '
  .schema == 1 and .active == true and .target == "left-half"
  and .monitor == "eDP-1" and .geometry.x == 10 and .geometry.y == 58
  and .geometry.width == 945 and .geometry.height == 938
' "$tmp/runtime/enoshima/snap.json" >/dev/null

"$controller" commit --address 0xabc
jq -e '.active == false' "$tmp/runtime/enoshima/snap.json" >/dev/null
grep -Fq 'internal = 0, client = 0' "$tmp/dispatch.log"
grep -Fq 'resizewindowpixel exact 945 938,address:0xabc' "$tmp/dispatch.log"
grep -Fq 'movewindowpixel exact 10 58,address:0xabc' "$tmp/dispatch.log"

: >"$tmp/dispatch.log"
"$controller" preview --address 0xdef --x 3838 --y 600
jq -e '
  .active == true and .target == "right-half" and .monitor == "DP-1"
  and .geometry.localX == 965 and .geometry.width == 945
' "$tmp/runtime/enoshima/snap.json" >/dev/null

"$controller" preview --address 0xabc --x 960 --y 540
jq -e '.active == false' "$tmp/runtime/enoshima/snap.json" >/dev/null

"$controller" place maximize --address 0xabc
grep -Fq 'internal = 1, client = 1' "$tmp/dispatch.log"

printf 'Enoshima snap controller tests passed.\n'
