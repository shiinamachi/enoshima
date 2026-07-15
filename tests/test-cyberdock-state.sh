#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_cyberdock-state
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export XDG_RUNTIME_DIR=$work/runtime
export CYBERDOCK_FAKE_ROOT=$work/hyprland
export CYBERDOCK_HYPRCTL=$work/bin/hyprctl
mkdir -m 0700 "$XDG_RUNTIME_DIR" "$CYBERDOCK_FAKE_ROOT" "$work/bin"

fail() {
  printf 'test-cyberdock-state: %s\n' "$*" >&2
  exit 1
}

run_state() {
  bash "$helper" "$@"
}

cat >"$CYBERDOCK_HYPRCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

root=${CYBERDOCK_FAKE_ROOT:?}

replace_json() {
  local destination=$1 temporary
  temporary=$(mktemp "$root/.json.XXXXXX")
  cat >"$temporary"
  mv -f -- "$temporary" "$destination"
}

case ${1:-} in
  clients | monitors | workspaces | activewindow)
    [[ ${2:-} == -j ]]
    cat "$root/$1.json"
    ;;
  dispatch)
    expression=${2:?}
    dispatcher=
    argument=
    case $expression in
      hl.dsp.window.move*)
        dispatcher=movetoworkspacesilent
        target=$(sed -nE 's/.*workspace = "?([^", }]+)"?.*/\1/p' <<<"$expression")
        address=$(sed -nE 's/.*address:(0x[0-9A-Fa-f]+).*/\1/p' <<<"$expression")
        argument="$target,address:$address"
        ;;
      hl.dsp.workspace.move*)
        dispatcher=moveworkspacetomonitor
        target=$(sed -nE 's/.*workspace = "?([^", }]+)"?.*/\1/p' <<<"$expression")
        monitor=$(sed -nE 's/.*monitor = "([[:alnum:]_.-]+)".*/\1/p' <<<"$expression")
        argument="$target $monitor"
        ;;
      hl.dsp.focus*)
        if [[ $expression == *'monitor ='* ]]; then
          dispatcher=focusmonitor
          argument=$(sed -nE 's/.*monitor = "([[:alnum:]_.-]+)".*/\1/p' <<<"$expression")
        elif [[ $expression == *'workspace ='* ]]; then
          dispatcher=workspace
          argument=$(sed -nE 's/.*workspace = "?([^", }]+)"?.*/\1/p' <<<"$expression")
        else
          dispatcher=focuswindow
          address=$(sed -nE 's/.*address:(0x[0-9A-Fa-f]+).*/\1/p' <<<"$expression")
          argument="address:$address"
        fi
        ;;
      hl.dsp.window.close*)
        dispatcher=closewindow
        address=$(sed -nE 's/.*address:(0x[0-9A-Fa-f]+).*/\1/p' <<<"$expression")
        argument="address:$address"
        ;;
      hl.dsp.window.float*)
        action=$(sed -nE 's/.*action = "(set|unset)".*/\1/p' <<<"$expression")
        address=$(sed -nE 's/.*address:(0x[0-9A-Fa-f]+).*/\1/p' <<<"$expression")
        dispatcher=windowfloat
        argument="$action,address:$address"
        ;;
      hl.dsp.window.fullscreen_state*)
        internal=$(sed -nE 's/.*internal = ([0-3]).*/\1/p' <<<"$expression")
        client=$(sed -nE 's/.*client = ([0-3]).*/\1/p' <<<"$expression")
        address=$(sed -nE 's/.*address:(0x[0-9A-Fa-f]+).*/\1/p' <<<"$expression")
        dispatcher=fullscreenstate
        argument="$internal $client,address:$address"
        ;;
      *)
        exit 1
        ;;
    esac
    [[ -n $dispatcher && -n $argument ]]
    printf '%s\t%s\n' "$dispatcher" "$argument" >>"$root/dispatch.log"
    case $dispatcher in
      movetoworkspacesilent)
        target=${argument%%,address:*}
        address=${argument##*,address:}
        if [[ $target == special:minimized ]]; then
          workspace_id=-99
          workspace_name=special:minimized
          monitor_id=$(jq -r --arg address "$address" \
            '.[] | select(.address == $address) | .monitor' "$root/clients.json")
        else
          workspace=$(jq -c --arg target "$target" \
            '.[] | select((.id | tostring) == $target or .name == $target)' \
            "$root/workspaces.json" | head -n1)
          workspace_id=$(jq -r '.id' <<<"$workspace")
          workspace_name=$(jq -r '.name' <<<"$workspace")
          workspace_monitor=$(jq -r '.monitor' <<<"$workspace")
          monitor_id=$(jq -r --arg monitor "$workspace_monitor" \
            '.[] | select(.name == $monitor) | .id' "$root/monitors.json")
        fi
        jq -c \
          --arg address "$address" \
          --arg workspaceName "$workspace_name" \
          --argjson workspaceId "$workspace_id" \
          --argjson monitorId "$monitor_id" '
            map(if .address == $address then
              .workspace = {id: $workspaceId, name: $workspaceName}
              | .monitor = $monitorId
            else . end)
          ' "$root/clients.json" | replace_json "$root/clients.json"
        if jq -e --arg address "$address" '.address == $address' \
          "$root/activewindow.json" >/dev/null; then
          printf '{}\n' >"$root/activewindow.json"
        fi
        ;;
      moveworkspacetomonitor)
        target=${argument%% *}
        monitor=${argument#* }
        jq -c --arg target "$target" --arg monitor "$monitor" '
          map(if ((.id | tostring) == $target or .name == $target)
            then .monitor = $monitor else . end)
        ' "$root/workspaces.json" | replace_json "$root/workspaces.json"
        ;;
      focusmonitor)
        jq -c --arg monitor "$argument" \
          'map(.focused = (.name == $monitor))' "$root/monitors.json" |
          replace_json "$root/monitors.json"
        ;;
      workspace)
        workspace=$(jq -c --arg target "$argument" '
          .[] | select((.id | tostring) == $target or .name == $target)
        ' "$root/workspaces.json" | head -n1)
        jq -c --argjson workspace "$workspace" '
          map(if .focused then
            .activeWorkspace = {id: $workspace.id, name: $workspace.name}
          else . end)
        ' "$root/monitors.json" | replace_json "$root/monitors.json"
        ;;
      focuswindow)
        address=${argument#address:}
        jq -c --arg address "$address" \
          '.[] | select(.address == $address)' "$root/clients.json" |
          replace_json "$root/activewindow.json"
        ;;
      closewindow)
        address=${argument#address:}
        jq -c --arg address "$address" \
          'map(select(.address != $address))' "$root/clients.json" |
          replace_json "$root/clients.json"
        if jq -e --arg address "$address" '.address == $address' \
          "$root/activewindow.json" >/dev/null; then
          printf '{}\n' >"$root/activewindow.json"
        fi
        ;;
      windowfloat)
        action=${argument%%,*}
        address=${argument##*,address:}
        floating=false
        [[ $action == set ]] && floating=true
        jq -c --arg address "$address" --argjson floating "$floating" '
          map(if .address == $address then .floating = $floating else . end)
        ' "$root/clients.json" | replace_json "$root/clients.json"
        ;;
      fullscreenstate)
        states=${argument%%,*}
        internal=${states%% *}
        client=${states#* }
        address=${argument##*,address:}
        jq -c --arg address "$address" --argjson internal "$internal" --argjson client "$client" '
          map(if .address == $address then
            .fullscreen = $internal | .fullscreenClient = $client
          else . end)
        ' "$root/clients.json" | replace_json "$root/clients.json"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
FAKE
chmod 0700 "$CYBERDOCK_HYPRCTL"

reset_fixture() {
  rm -rf -- "$XDG_RUNTIME_DIR/cyberdock"
  : >"$CYBERDOCK_FAKE_ROOT/dispatch.log"
  cat >"$CYBERDOCK_FAKE_ROOT/monitors.json" <<'JSON'
[
  {"id":0,"name":"eDP-1","focused":true,"activeWorkspace":{"id":3,"name":"3"}},
  {"id":1,"name":"DP-1","focused":false,"activeWorkspace":{"id":2,"name":"2"}}
]
JSON
  cat >"$CYBERDOCK_FAKE_ROOT/workspaces.json" <<'JSON'
[
  {"id":1,"name":"1","monitor":"eDP-1"},
  {"id":2,"name":"2","monitor":"DP-1"},
  {"id":3,"name":"3","monitor":"eDP-1"}
]
JSON
  cat >"$CYBERDOCK_FAKE_ROOT/clients.json" <<'JSON'
[
  {"address":"0xaaa","mapped":true,"class":"dev.zed.Zed","initialClass":"dev.zed.Zed","title":"Notes","workspace":{"id":3,"name":"3"},"monitor":0,"floating":false,"fullscreen":0,"fullscreenClient":0,"focusHistoryID":0},
  {"address":"0xbbb","mapped":true,"class":"google-chrome","initialClass":"google-chrome","title":"Browser","workspace":{"id":2,"name":"2"},"monitor":1,"floating":true,"fullscreen":1,"fullscreenClient":1,"focusHistoryID":1},
  {"address":"0xccc","mapped":true,"class":"xembed-sni-proxy","initialClass":"xembed-sni-proxy","title":"","workspace":{"id":3,"name":"3"},"monitor":0,"focusHistoryID":2},
  {"address":"0xddd","mapped":true,"class":"explorer.exe","initialClass":"explorer.exe","title":"","workspace":{"id":-98,"name":"special:tray"},"monitor":0,"focusHistoryID":3}
]
JSON
  jq -c '.[] | select(.address == "0xaaa")' \
    "$CYBERDOCK_FAKE_ROOT/clients.json" >"$CYBERDOCK_FAKE_ROOT/activewindow.json"
}

printf '%s\n' '==> snapshot initializes private runtime state'
reset_fixture
snapshot=$(run_state snapshot)
jq -e '.version == 1 and (.windows | length == 2) and (.windows | all(.minimized == false))' \
  <<<"$snapshot" >/dev/null || fail 'unexpected initial snapshot'
jq -e 'all(.windows[]; .workspace.name != "special:tray" and .class != "xembed-sni-proxy")' \
  <<<"$snapshot" >/dev/null || fail 'tray bridge surface leaked into the dock snapshot'
[[ $(stat -c %a "$XDG_RUNTIME_DIR/cyberdock") == 700 ]] || fail 'runtime directory mode is not 0700'
[[ $(stat -c %a "$XDG_RUNTIME_DIR/cyberdock/minimized.json") == 600 ]] ||
  fail 'state file mode is not 0600'

printf '%s\n' '==> minimize records origin atomically and snapshot exposes it'
run_state minimize 0xaaa
jq -e '.[] | select(.address == "0xaaa") | .workspace.name == "special:minimized"' \
  "$CYBERDOCK_FAKE_ROOT/clients.json" >/dev/null || fail 'window was not minimized'
jq -e '.windows["0xaaa"].workspace.name == "3" and .windows["0xaaa"].monitor == "eDP-1"' \
  "$XDG_RUNTIME_DIR/cyberdock/minimized.json" >/dev/null || fail 'origin was not recorded'
snapshot=$(run_state snapshot)
jq -e '.windows[] | select(.address == "0xaaa") | .minimized and .originalWorkspace.name == "3"' \
  <<<"$snapshot" >/dev/null || fail 'snapshot did not expose minimized state'

printf '%s\n' '==> activation restores the original workspace, output, and focus'
run_state activate 0xaaa
jq -e '.[] | select(.address == "0xaaa") | .workspace.name == "3" and .monitor == 0' \
  "$CYBERDOCK_FAKE_ROOT/clients.json" >/dev/null || fail 'window was not restored'
jq -e '.windows | length == 0' "$XDG_RUNTIME_DIR/cyberdock/minimized.json" >/dev/null ||
  fail 'restore record was not removed'
jq -e '.address == "0xaaa"' "$CYBERDOCK_FAKE_ROOT/activewindow.json" >/dev/null ||
  fail 'restored window was not focused'

printf '%s\n' '==> activation crosses monitors and is a no-op for the focused window'
run_state activate 0xbbb
grep -Fqx $'focusmonitor\tDP-1' "$CYBERDOCK_FAKE_ROOT/dispatch.log" ||
  fail 'owning monitor was not selected'
grep -Fqx $'workspace\t2' "$CYBERDOCK_FAKE_ROOT/dispatch.log" ||
  fail 'owning workspace was not selected'
before=$(wc -l <"$CYBERDOCK_FAKE_ROOT/dispatch.log")
run_state activate 0xbbb
after=$(wc -l <"$CYBERDOCK_FAKE_ROOT/dispatch.log")
[[ $before -eq $after ]] || fail 'focused activation dispatched an action'

printf '%s\n' '==> disconnected output recovery keeps the recorded workspace on a safe monitor'
run_state minimize 0xbbb
jq 'map(if .address == "0xbbb" then
  .floating = false | .fullscreen = 0 | .fullscreenClient = 0
else . end)' "$CYBERDOCK_FAKE_ROOT/clients.json" >"$work/clients.new"
mv -f -- "$work/clients.new" "$CYBERDOCK_FAKE_ROOT/clients.json"
cat >"$CYBERDOCK_FAKE_ROOT/monitors.json" <<'JSON'
[
  {"id":0,"name":"eDP-1","focused":true,"activeWorkspace":{"id":1,"name":"1"}}
]
JSON
printf '{}\n' >"$CYBERDOCK_FAKE_ROOT/activewindow.json"
run_state restore 0xbbb
grep -Fqx $'moveworkspacetomonitor\t2 eDP-1' "$CYBERDOCK_FAKE_ROOT/dispatch.log" ||
  fail 'recorded workspace was not recovered to the remaining monitor'
jq -e '.[] | select(.address == "0xbbb") | .workspace.name == "2" and .monitor == 0' \
  "$CYBERDOCK_FAKE_ROOT/clients.json" >/dev/null || fail 'disconnected-output restore was unsafe'
jq -e '.[] | select(.address == "0xbbb") | .floating and .fullscreen == 1 and .fullscreenClient == 1' \
  "$CYBERDOCK_FAKE_ROOT/clients.json" >/dev/null || fail 'window geometry state was not restored'

printf '%s\n' '==> closed clients are pruned from runtime state'
reset_fixture
run_state minimize 0xaaa
jq -c 'map(select(.address != "0xaaa"))' "$CYBERDOCK_FAKE_ROOT/clients.json" >"$work/clients.new"
mv -f -- "$work/clients.new" "$CYBERDOCK_FAKE_ROOT/clients.json"
run_state snapshot >/dev/null
jq -e '.windows | length == 0' "$XDG_RUNTIME_DIR/cyberdock/minimized.json" >/dev/null ||
  fail 'closed client record was not pruned'

printf '%s\n' '==> close requests target a specific window and clear minimized state'
reset_fixture
run_state minimize 0xaaa
run_state close 0xaaa
jq -e 'all(.[]; .address != "0xaaa")' "$CYBERDOCK_FAKE_ROOT/clients.json" >/dev/null ||
  fail 'targeted close did not remove the window'
jq -e '.windows | length == 0' "$XDG_RUNTIME_DIR/cyberdock/minimized.json" >/dev/null ||
  fail 'targeted close retained minimized state'
grep -Fqx $'closewindow\taddress:0xaaa' "$CYBERDOCK_FAKE_ROOT/dispatch.log" ||
  fail 'targeted close did not use the Lua dispatcher'

printf '%s\n' '==> crash recovery restores unrecorded minimized clients to a safe workspace'
cat >"$CYBERDOCK_FAKE_ROOT/clients.json" <<'JSON'
[
  {"address":"0xccc","mapped":true,"class":"orphan","initialClass":"orphan","title":"Orphan","workspace":{"id":-99,"name":"special:minimized"},"monitor":0,"focusHistoryID":0}
]
JSON
cat >"$CYBERDOCK_FAKE_ROOT/workspaces.json" <<'JSON'
[
  {"id":1,"name":"1","monitor":"eDP-1"}
]
JSON
cat >"$CYBERDOCK_FAKE_ROOT/monitors.json" <<'JSON'
[
  {"id":0,"name":"eDP-1","focused":true,"activeWorkspace":{"id":1,"name":"1"}}
]
JSON
printf '{}\n' >"$CYBERDOCK_FAKE_ROOT/activewindow.json"
run_state recover >/dev/null
jq -e '.[] | select(.address == "0xccc") | .workspace.name == "1" and .monitor == 0' \
  "$CYBERDOCK_FAKE_ROOT/clients.json" >/dev/null || fail 'orphan recovery failed'

printf '%s\n' '==> concurrent snapshots preserve valid atomic JSON'
pids=()
for _ in {1..16}; do
  run_state snapshot >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
jq -e '.version == 1 and (.windows | type == "object")' \
  "$XDG_RUNTIME_DIR/cyberdock/minimized.json" >/dev/null || fail 'concurrent state is invalid'

printf '%s\n' 'Cyberdock state tests passed.'
