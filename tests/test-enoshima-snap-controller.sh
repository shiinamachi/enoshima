#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
controller=$repo_root/home/dot_local/bin/executable_enoshima-snap-controller
daemon=$repo_root/home/dot_local/libexec/executable_enoshima-windowd
tmp=$(mktemp -d)
daemon_pid=

cleanup() {
  if [[ -n $daemon_pid ]]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT

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
export ENOSHIMA_WINDOWD_RUNTIME_DIR=$tmp/runtime
export ENOSHIMA_WINDOWD_HYPRCTL=$tmp/bin/hyprctl
export ENOSHIMA_WINDOW_INTERACTION_CONFIG=$repo_root/home/dot_config/enoshima/window-interaction.yaml
export SNAP_DISPATCH_LOG=$tmp/dispatch.log

"$daemon" &
daemon_pid=$!
for _ in {1..50}; do
  [[ -S $tmp/runtime/enoshima/windowd.sock ]] && break
  sleep 0.02
done
[[ -S $tmp/runtime/enoshima/windowd.sock ]]
[[ $(stat -c %a "$tmp/runtime/enoshima/windowd.sock") == 600 ]]

"$controller" preview --address 0xabc --x 4 --y 540 --session 101 --sequence 1
jq -e '
  .schema == 2 and .active == true and .session == 101 and .sequence == 1
  and .target == "left-half" and .monitor == "eDP-1"
  and .geometry.x == 10 and .geometry.y == 58
  and .geometry.width == 945 and .geometry.height == 938
' "$tmp/runtime/enoshima/snap.json" >/dev/null

"$controller" commit --address 0xabc --session 101 --sequence 2
jq -e '.schema == 2 and .active == false and .session == 101' \
  "$tmp/runtime/enoshima/snap.json" >/dev/null
grep -Fq 'internal = 0, client = 0' "$tmp/dispatch.log"
grep -Fq 'resizewindowpixel exact 945 938,address:0xabc' "$tmp/dispatch.log"
grep -Fq 'movewindowpixel exact 10 58,address:0xabc' "$tmp/dispatch.log"

# Once committed, a delayed pointer packet in the same session is discarded.
"$controller" preview --address 0xabc --x 1915 --y 540 --session 101 --sequence 3
jq -e '.active == false and .session == 101' "$tmp/runtime/enoshima/snap.json" >/dev/null

: >"$tmp/dispatch.log"
"$controller" preview --address 0xdef --x 3838 --y 600 --session 202 --sequence 1
jq -e '
  .active == true and .target == "right-half" and .monitor == "DP-1"
  and .geometry.localX == 965 and .geometry.width == 945
' "$tmp/runtime/enoshima/snap.json" >/dev/null

"$controller" preview --address 0xabc --x 960 --y 540 --session 303 --sequence 1
jq -e '.active == false and .session == 303' "$tmp/runtime/enoshima/snap.json" >/dev/null

"$controller" place maximize --address 0xabc
grep -Fq 'internal = 1, client = 1' "$tmp/dispatch.log"

# Super+Z exposes every approved layout family and commits an exact-address
# thirds target through the same broker path.
"$controller" chooser --address 0xabc
jq -e '
  .active == true and .source == "keyboard" and .chooser.visible == true
  and (.chooser.layouts | map(.id)) == [
    "halves", "third-two-thirds", "two-thirds-third",
    "thirds", "quarters", "maximize"
  ]
' "$tmp/runtime/enoshima/snap.json" >/dev/null
"$controller" choose center-third --commit
grep -Fq 'resizewindowpixel exact 626 938,address:0xabc' "$tmp/dispatch.log"
grep -Fq 'movewindowpixel exact 646 58,address:0xabc' "$tmp/dispatch.log"
jq -e '.active == false' "$tmp/runtime/enoshima/snap.json" >/dev/null

grep -Fq 'SOCK_SEQPACKET' "$daemon"
grep -Fq 'SO_PEERCRED' "$daemon"
grep -Fq 'm_snapSession' "$repo_root/native/enoshima-decoration/src/barDeco.hpp"
if grep -Fq 'executor()->spawn(std::format("enoshima-snap-controller preview' \
  "$repo_root/native/enoshima-decoration/src/barDeco.cpp"; then
  printf 'Pointer updates still launch a process.\n' >&2
  exit 1
fi

printf 'Enoshima snap broker tests passed.\n'
