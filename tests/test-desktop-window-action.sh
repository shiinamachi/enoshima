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
  activewindow | clients)
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
  {"address":"0xaaa","title":"Editor","class":"dev.zed.Zed","floating":false,"fullscreen":0},
  {"address":"0xbbb","title":"Browser","class":"google-chrome","floating":true,"fullscreen":1}
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
