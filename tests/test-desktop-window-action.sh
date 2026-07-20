#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-window-action
bridge=$repo_root/home/dot_local/bin/executable_cyberdock-event-bridge
bridge_service=$repo_root/home/dot_config/systemd/user/cyberdock-event-bridge.service
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export DESKTOP_WINDOW_HYPRCTL=$work/bin/hyprctl
export DESKTOP_WINDOW_STATE=$work/bin/cyberdock-state
export WINDOW_TEST_ROOT=$work/state
export WINDOW_TEST_LOG=$work/commands.log
export DESKTOP_WINDOW_RUNTIME_DIR=$work/runtime/window-adjust
mkdir -p "$work/bin" "$WINDOW_TEST_ROOT"

fail() {
  printf 'test-desktop-window-action: %s\n' "$*" >&2
  exit 1
}

cat >"$DESKTOP_WINDOW_HYPRCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
root=${WINDOW_TEST_ROOT:?}
case ${1:-} in
  activewindow | clients | monitors)
    [[ ${2:-} == -j ]]
    cat "$root/$1.json"
    ;;
  dispatch)
    printf 'hyprctl' >>"${WINDOW_TEST_LOG:?}"
    for argument in "$@"; do printf ' %s' "$argument" >>"${WINDOW_TEST_LOG:?}"; done
    printf '\n' >>"${WINDOW_TEST_LOG:?}"
    ;;
  *) exit 64 ;;
esac
FAKE

cat >"$DESKTOP_WINDOW_STATE" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == snapshot ]]; then
  cat "${WINDOW_TEST_ROOT:?}/snapshot.json"
  exit
fi
printf 'state' >>"${WINDOW_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$WINDOW_TEST_LOG"; done
printf '\n' >>"$WINDOW_TEST_LOG"
FAKE
chmod 0700 "$work"/bin/*

cat >"$WINDOW_TEST_ROOT/clients.json" <<'JSON'
[
  {"address":"0xaaa","stableId":"stable-a","title":"Editor","class":"dev.zed.Zed","at":[20,60],"size":[1200,800],"workspace":{"id":2,"name":"2"},"monitor":0,"floating":false,"pinned":false,"fullscreen":0,"fullscreenClient":0,"grouped":[]},
  {"address":"0xbbb","stableId":"stable-b","title":"Browser","class":"google-chrome","at":[120,80],"size":[1280,840],"workspace":{"id":3,"name":"3"},"monitor":1,"floating":true,"pinned":false,"fullscreen":1,"fullscreenClient":1,"grouped":[]},
  {"address":"0xddd","stableId":"stable-d","title":"Grouped","class":"grouped-app","at":[0,0],"size":[800,600],"workspace":{"id":4,"name":"4"},"monitor":0,"floating":false,"pinned":false,"fullscreen":0,"fullscreenClient":0,"grouped":["0xddd","0xeee"]}
]
JSON
cat >"$WINDOW_TEST_ROOT/monitors.json" <<'JSON'
[
  {"id":0,"name":"eDP-1"},
  {"id":1,"name":"DP-1"}
]
JSON
jq -c '.[] | select(.address == "0xaaa")' "$WINDOW_TEST_ROOT/clients.json" \
  >"$WINDOW_TEST_ROOT/activewindow.json"
cat >"$WINDOW_TEST_ROOT/snapshot.json" <<'JSON'
{"version":1,"windows":[{"address":"0xaaa","minimized":false},{"address":"0xbbb","minimized":true}]}
JSON
: >"$WINDOW_TEST_LOG"

run_action() {
  bash "$helper" "$@"
}

if grep -Fq -- '--tracked' "$helper"; then
  fail 'desktop-window-action still exposes the retired tracked address mode'
fi
if grep -Eq 'active-window-address|activewindowv2' "$bridge"; then
  fail 'event bridge still maintains the retired active-window side channel'
fi

printf '%s\n' '==> status exposes the exact active window address and state'
jq -e '
  .schema == 1 and .address == "0xaaa" and .title == "Editor" and
  .class == "dev.zed.Zed" and .actionable and (.minimized | not)
' < <(run_action status --json) >/dev/null || fail 'active window status is invalid'

printf '%s\n' '==> active and explicit actions preserve their target addresses'
run_action minimize --active
run_action restore --address 0xbbb
run_action focus --address 0xbbb
run_action close --address 0xaaa
grep -Fxq 'state minimize 0xaaa' "$WINDOW_TEST_LOG" || fail 'active minimize lost its address'
grep -Fxq 'state restore 0xbbb' "$WINDOW_TEST_LOG" || fail 'restore lost its address'
grep -Fxq 'state activate 0xbbb' "$WINDOW_TEST_LOG" || fail 'focus lost its address'
grep -Fxq 'state close 0xaaa' "$WINDOW_TEST_LOG" || fail 'close lost its address'

printf '%s\n' '==> maximize uses an address-scoped compositor dispatcher'
run_action maximize --address 0xbbb
grep -Fq 'window = "address:0xbbb"' "$WINDOW_TEST_LOG" ||
  fail 'maximize did not target the requested address'
grep -Fq 'mode = "maximized"' "$WINDOW_TEST_LOG" ||
  fail 'maximize did not use the work-area state'

printf '%s\n' '==> system-menu geometry changes retain the exact target and roll back'
run_action move-by --address 0xbbb --x -20 --y 20 --origin titlebar
run_action resize-by --address 0xbbb --x 20 --y -20 --origin titlebar
run_action restore-geometry --address 0xbbb --x 120 --y 80 \
  --width 1280 --height 840 --floating true --fullscreen 1 --fullscreen-client 1
grep -Fq 'movewindowpixel -20 20,address:0xbbb' "$WINDOW_TEST_LOG" ||
  fail 'move-by did not retain its exact address'
grep -Fq 'resizewindowpixel 20 -20,address:0xbbb' "$WINDOW_TEST_LOG" ||
  fail 'resize-by did not retain its exact address'
grep -Fq 'resizewindowpixel exact 1280 840,address:0xbbb' "$WINDOW_TEST_LOG" ||
  fail 'geometry rollback did not restore the original size'
grep -Fq 'movewindowpixel exact 120 80,address:0xbbb' "$WINDOW_TEST_LOG" ||
  fail 'geometry rollback did not restore the original position'
grep -Fq 'internal = 1, client = 1' "$WINDOW_TEST_LOG" ||
  fail 'geometry rollback did not restore fullscreen state'

printf '%s\n' '==> system-menu adjustment transactions restore complete exact-target state'
transaction=window-adjustment-0001
jq -e '.ok and .code == "adjustment-started"' \
  < <(run_action begin-adjust --address 0xbbb --transaction "$transaction" --mode move --json) \
  >/dev/null || fail 'adjustment transaction did not start'
jq -e '
  .schema == 1 and .address == "0xbbb" and .stableId == "stable-b"
  and .workspace.id == 3 and .monitor.name == "DP-1"
  and .geometry == {x:120,y:80,width:1280,height:840}
  and .floating == true and .fullscreen == 1 and .fullscreenClient == 1
  and .pinned == false and .pseudo == false and .grouped == []
' "$DESKTOP_WINDOW_RUNTIME_DIR/$transaction.json" >/dev/null ||
  fail 'adjustment transaction omitted window state'
run_action adjust-step --transaction "$transaction" --x -20 --y 20 --json | jq -e '.ok' >/dev/null
run_action cancel-adjust --transaction "$transaction" --json | jq -e '.ok' >/dev/null
[[ ! -e $DESKTOP_WINDOW_RUNTIME_DIR/$transaction.json ]] ||
  fail 'cancelled adjustment transaction was not removed'
grep -Fq 'hl.dsp.window.move({ workspace = 3, follow = false, window = "address:0xbbb" })' \
  "$WINDOW_TEST_LOG" || fail 'adjustment rollback did not restore the workspace'
grep -Fq 'resizewindowpixel exact 1280 840,address:0xbbb' "$WINDOW_TEST_LOG" ||
  fail 'transaction rollback did not restore size'
grep -Fq 'movewindowpixel exact 120 80,address:0xbbb' "$WINDOW_TEST_LOG" ||
  fail 'transaction rollback did not restore position'

printf '%s\n' '==> grouped windows and reused addresses fail closed'
if run_action begin-adjust --address 0xddd --transaction grouped-window-0001 \
    --mode resize --json | jq -e '.ok' >/dev/null; then
  fail 'grouped window unexpectedly entered an independent adjustment'
fi
reuse_transaction=window-adjustment-reuse-0001
run_action begin-adjust --address 0xbbb --transaction "$reuse_transaction" --mode resize --json \
  | jq -e '.ok' >/dev/null
jq 'map(if .address == "0xbbb" then .stableId = "replacement" else . end)' \
  "$WINDOW_TEST_ROOT/clients.json" >"$WINDOW_TEST_ROOT/clients.next.json"
mv "$WINDOW_TEST_ROOT/clients.next.json" "$WINDOW_TEST_ROOT/clients.json"
if run_action cancel-adjust --transaction "$reuse_transaction" --json \
    | jq -e '.ok' >/dev/null; then
  fail 'reused address unexpectedly restored another window'
fi
run_action commit-adjust --transaction "$reuse_transaction" --json | jq -e '.ok' >/dev/null

printf '%s\n' '==> stale and malformed addresses are rejected before dispatch'
before=$(wc -l <"$WINDOW_TEST_LOG")
if run_action close --address 0xccc 2>/dev/null; then
  fail 'stale address unexpectedly succeeded'
fi
if run_action minimize --address 'class:.*' 2>/dev/null; then
  fail 'non-address selector unexpectedly succeeded'
fi
if run_action close --tracked 2>/dev/null; then
  fail 'retired tracked address mode unexpectedly succeeded'
fi
after=$(wc -l <"$WINDOW_TEST_LOG")
[[ $before -eq $after ]] || fail 'invalid target dispatched a window action'

printf '%s\n' '==> socket events are reconciled only by the state machine'
export CYBERDOCK_EVENT_STATE=$work/bin/event-state
export CYBERDOCK_EVENT_QS=$work/bin/event-qs
export EVENT_STATE_FILE=$work/event-state.json
cat >"$CYBERDOCK_EVENT_STATE" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == snapshot ]]; then
  cat "${EVENT_STATE_FILE:?}"
  exit
fi
printf 'event-state' >>"${WINDOW_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$WINDOW_TEST_LOG"; done
printf '\n' >>"$WINDOW_TEST_LOG"
FAKE
chmod 0700 "$CYBERDOCK_EVENT_STATE"
cat >"$CYBERDOCK_EVENT_QS" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'event-qs' >>"${WINDOW_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$WINDOW_TEST_LOG"; done
printf '\n' >>"$WINDOW_TEST_LOG"
FAKE
chmod 0700 "$CYBERDOCK_EVENT_QS"
cat >"$EVENT_STATE_FILE" <<'JSON'
{"version":1,"windows":[{"address":"0xaaa","minimized":false},{"address":"0xbbb","minimized":false}]}
JSON
printf '%s\n' \
  'activewindowv2>>0xbbb' \
  'minimize>>0xaaa,1' \
  'minimized>>0xaaa,1' \
  'minimized>>0xaaa,1' \
  'minimized>>0xaaa,0' \
  'minimized>>0xaaa,0' \
  'minimized>>0xbbb,1' \
  'minimized>>class:bad,1' \
  'closewindow>>0xaaa' | bash "$bridge" --stdin
[[ $(grep -Fc 'event-state observe-minimized 0xaaa 1' "$WINDOW_TEST_LOG") -eq 2 ]] ||
  fail 'valid minimize observations did not reach the state machine'
[[ $(grep -Fc 'event-state observe-minimized 0xaaa 0' "$WINDOW_TEST_LOG") -eq 2 ]] ||
  fail 'valid restore observations did not reach the state machine'
grep -Fxq 'event-state observe-minimized 0xbbb 1' "$WINDOW_TEST_LOG" ||
  fail 'documented minimize observation was not bridged'
if grep -Fq 'event-state observe-minimized class:bad' "$WINDOW_TEST_LOG"; then
  fail 'malformed minimize observation reached the state machine'
fi
if grep -Fq 'event-controller' "$WINDOW_TEST_LOG"; then
  fail 'event bridge bypassed the authoritative state machine'
fi
if grep -Fq 'debounce' "$bridge" || grep -Fq 'minimize\>\>* |' "$bridge"; then
  fail 'event bridge retains timing correctness or the undocumented event name'
fi
grep -Fxq 'event-state prune' "$WINDOW_TEST_LOG" ||
  fail 'close event did not prune runtime state'
grep -Fq 'ipc call -- dock refresh' "$WINDOW_TEST_LOG" ||
  fail 'state-changing events do not refresh the rendered dock'
printf '%s\n' 'closewindow>>0xbbb' | bash "$bridge" --stdin
# shellcheck disable=SC2016 # Match the literal command in the managed helper.
grep -Fq '"$socat_bin" -u "UNIX-CONNECT:$socket" STDOUT' "$bridge" ||
  fail 'event bridge still closes its socket when service stdin reaches EOF'
grep -Fxq 'Restart=always' "$bridge_service" ||
  fail 'event bridge does not reconnect after a compositor socket closes'
grep -Fxq 'RestartSec=1' "$bridge_service" ||
  fail 'event bridge reconnect delay is not bounded to one second'
grep -Fxq 'StandardOutput=journal' "$bridge_service" ||
  fail 'event bridge output is not explicitly routed to the journal'
grep -Fxq 'StandardError=journal' "$bridge_service" ||
  fail 'event bridge errors are not explicitly routed to the journal'

printf 'Desktop window action tests passed.\n'
