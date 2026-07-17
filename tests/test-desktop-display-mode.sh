#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-display-mode
overlay_qml=$repo_root/home/dot_config/quickshell/cyberdock/DisplayModeOverlay.qml
event_listener=$repo_root/home/dot_local/bin/executable_desktop-display-event-listener
event_service=$repo_root/home/dot_config/systemd/user/desktop-display-events.service
hyprland_config=$repo_root/home/dot_config/hypr/hyprland.lua
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export HOME=$work/home
export XDG_CONFIG_HOME=$HOME/.config
export XDG_STATE_HOME=$HOME/.local/state
export XDG_RUNTIME_DIR=$work/runtime
export DESKTOP_DISPLAY_CONFIG_HOME=$XDG_CONFIG_HOME
export DESKTOP_DISPLAY_STATE_HOME=$XDG_STATE_HOME
export DESKTOP_DISPLAY_RUNTIME_HOME=$XDG_RUNTIME_DIR
export DESKTOP_DISPLAY_DEFAULTS_FILE=$repo_root/home/dot_config/enoshima/defaults/display.json
export DESKTOP_DISPLAY_HYPRCTL=$work/bin/hyprctl
export DESKTOP_DISPLAY_SYSTEMCTL=$work/bin/systemctl
export DESKTOP_DISPLAY_ROUTE=$work/bin/workspace-output-route
export DISPLAY_TEST_ROOT=$work/state
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$work/bin" "$DISPLAY_TEST_ROOT"

fail() {
  printf 'test-desktop-display-mode: %s\n' "$*" >&2
  exit 1
}

cat >"$DESKTOP_DISPLAY_HYPRCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
root=${DISPLAY_TEST_ROOT:?}

apply_rule() {
  local rule=$1 name mode position scale width height refresh x y mirror=none
  IFS=, read -r name mode position scale _ <<<"$rule"
  printf '%s\n' "$rule" >>"$root/rules.log"
  if [[ $mode == disable ]]; then
    jq -c --arg name "$name" '
      map(if .name == $name then
        .disabled = true | .width = 0 | .height = 0 | .mirrorOf = "none"
      else . end)
    ' "$root/monitors.json" >"$root/next.json"
    mv -f -- "$root/next.json" "$root/monitors.json"
    return
  fi

  if [[ $mode == preferred ]]; then
    mode=$(jq -r --arg name "$name" \
      '.[] | select(.name == $name) | .availableModes[0]' "$root/monitors.json")
  fi
  mode=${mode%Hz}
  width=${mode%%x*}
  remainder=${mode#*x}
  height=${remainder%%@*}
  refresh=${mode#*@}
  case $position in
    auto*) x=1920; y=0 ;;
    *) x=${position%%x*}; y=${position#*x} ;;
  esac
  [[ $scale == auto ]] && scale=1
  if [[ $rule == *,mirror,* ]]; then
    mirror=${rule##*,mirror,}
    mirror=${mirror%%,*}
  fi
  jq -c \
    --arg name "$name" --arg mirror "$mirror" \
    --argjson width "$width" --argjson height "$height" \
    --argjson refresh "$refresh" --argjson x "$x" --argjson y "$y" \
    --argjson scale "$scale" '
      map(if .name == $name then
        .disabled = false
        | .width = $width
        | .height = $height
        | .refreshRate = $refresh
        | .x = $x
        | .y = $y
        | .scale = $scale
        | .mirrorOf = $mirror
      else . end)
    ' "$root/monitors.json" >"$root/next.json"
  mv -f -- "$root/next.json" "$root/monitors.json"
}

case ${1:-} in
  -j)
    [[ ${2:-} == monitors && ${3:-} == all ]]
    cat "$root/monitors.json"
    ;;
  keyword)
    [[ ${2:-} == monitor ]]
    printf 'single\n' >>"$root/calls.log"
    apply_rule "${3:?}"
    ;;
  --batch)
    printf 'batch\n' >>"$root/calls.log"
    batch=${2:?}
    while [[ $batch == *'keyword monitor '* ]]; do
      batch=${batch#*keyword monitor }
      rule=${batch%%;*}
      apply_rule "$rule"
      [[ $batch == *';'* ]] || break
      batch=${batch#*;}
    done
    ;;
  notify)
    ;;
  version)
    printf 'Hyprland test\n'
    ;;
  *) exit 64 ;;
esac
FAKE

cat >"$DESKTOP_DISPLAY_SYSTEMCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DISPLAY_TEST_ROOT:?}/systemctl.log"
if [[ ${DISPLAY_SYSTEMCTL_FAIL:-false} == true && $* == *' restart '* ]]; then
  exit 1
fi
FAKE

cat >"$DESKTOP_DISPLAY_ROUTE" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'route\n' >>"${DISPLAY_TEST_ROOT:?}/route.log"
FAKE

chmod 0700 "$DESKTOP_DISPLAY_HYPRCTL" "$DESKTOP_DISPLAY_SYSTEMCTL" "$DESKTOP_DISPLAY_ROUTE"

reset_fixture() {
  rm -rf -- "$XDG_CONFIG_HOME/enoshima/user" "$XDG_STATE_HOME/enoshima" "$XDG_RUNTIME_DIR/enoshima"
  : >"$DISPLAY_TEST_ROOT/calls.log"
  : >"$DISPLAY_TEST_ROOT/rules.log"
  : >"$DISPLAY_TEST_ROOT/systemctl.log"
  : >"$DISPLAY_TEST_ROOT/route.log"
  cat >"$DISPLAY_TEST_ROOT/monitors.json" <<'JSON'
[
  {
    "id":0,"name":"eDP-1","description":"Internal OLED","make":"Samsung","model":"ATNA40","serial":"INT1",
    "width":2880,"height":1800,"refreshRate":120,"x":0,"y":240,"scale":1.5,"transform":0,"disabled":false,"mirrorOf":"none",
    "availableModes":["2880x1800@120.00Hz","1920x1080@60.00Hz"]
  },
  {
    "id":1,"name":"DP-1","description":"Dell U2725QE","make":"Dell","model":"U2725QE","serial":"EXT1",
    "width":3840,"height":2160,"refreshRate":120,"x":1920,"y":0,"scale":1.5,"transform":0,"disabled":false,"mirrorOf":"none",
    "availableModes":["3840x2160@120.00Hz","1920x1080@60.00Hz"]
  }
]
JSON
}

run_display() {
  bash "$helper" "$@"
}

printf '%s\n' '==> managed seed and profile registry describe the HiDPI policy'
jq -e '
  .schema == 2 and .display_policy_revision == 3 and .default_profile == "balanced"
  and .profiles.balanced.internal_scale == 1.5
  and .profiles.balanced.internal_position == "0x240"
  and .profiles.balanced.known_external_scale == 1.5
  and .profiles.balanced.known_external_position == "1920x0"
  and .profiles.matched.internal_scale == 2.25
  and .profiles.matched.internal_position == "0x640"
  and .profiles.matched.known_external_position == "1280x0"
' "$DESKTOP_DISPLAY_DEFAULTS_FILE" >/dev/null || fail 'managed profile registry is wrong'
for contract in \
  'position = "0x240"' \
  'scale = 1.5' \
  'position = "1920x0"'; do
  grep -Fq -- "$contract" "$hyprland_config" || fail "Hyprland seed is missing: $contract"
done

printf '%s\n' '==> status and availability describe the connected topology'
reset_fixture
jq -e '.schema == 2 and .mode == "extend" and .external_count == 1 and
  .default_profile == "balanced" and (.pending | not)' \
  < <(run_display status --json) >/dev/null || fail 'initial status is wrong'
jq -e '.schema == 2 and .default_profile == "balanced" and
  .profiles == ["balanced", "matched"] and (.modes | all(.available))' \
  < <(run_display list --json) >/dev/null ||
  fail 'all projection modes should be available'

printf '%s\n' '==> internal-only enables its safe target before disabling externals'
run_display apply internal
jq -e '[.[] | select(.disabled == false)] | map(.name) == ["eDP-1"]' \
  "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'internal-only mode is wrong'
jq -e '.[] | select(.name == "eDP-1") | .scale == 1.5 and .x == 0 and .y == 0' \
  "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'internal-only HiDPI policy is wrong'
[[ $(sed -n '1p' "$DISPLAY_TEST_ROOT/calls.log") == single ]] ||
  fail 'target output was not enabled before the disable batch'
jq -e '.pending and .target_mode == "internal" and .seconds_remaining > 0' \
  < <(run_display status --json) >/dev/null || fail 'rollback transaction was not armed'
grep -Fq -- '--user restart desktop-display-revert.timer' "$DISPLAY_TEST_ROOT/systemctl.log" ||
  fail 'automatic rollback timer was not started'

printf '%s\n' '==> revert restores every output from the transaction snapshot'
run_display revert
jq -e '
  ([.[] | select(.disabled == false)] | length == 2)
  and (.[] | select(.name == "eDP-1") | .scale == 1.5 and .x == 0 and .y == 240)
' \
  "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'revert did not restore both outputs'
jq -e '.pending | not' < <(run_display status --json) >/dev/null ||
  fail 'revert retained the pending transaction'

printf '%s\n' '==> confirmation persists the topology preference outside chezmoi state'
run_display apply external
run_display confirm
jq -e '[.[] | select(.disabled == false)] | map(.name) == ["DP-1"]' \
  "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'external-only mode is wrong'
profile_count=$(find "$XDG_CONFIG_HOME/enoshima/user/display-topologies" -name '*.json' -type f | wc -l)
[[ $profile_count -eq 1 ]] || fail 'confirmed topology profile was not stored'
jq -e '.schema == 2 and .policy_revision == 3 and .mode == "external" and .profile == "balanced"' \
  "$XDG_CONFIG_HOME"/enoshima/user/display-topologies/*.json >/dev/null ||
  fail 'stored topology profile is invalid'

printf '%s\n' '==> topology restore follows physical metadata across connector renames'
jq 'map(
  if .name == "DP-1" then .name = "DP-9" | .disabled = false
  elif .name == "eDP-1" then .disabled = false | .width = 2880 | .height = 1800
  else . end
)' "$DISPLAY_TEST_ROOT/monitors.json" >"$DISPLAY_TEST_ROOT/next.json"
mv -f -- "$DISPLAY_TEST_ROOT/next.json" "$DISPLAY_TEST_ROOT/monitors.json"
run_display reconcile
jq -e '
  ([.[] | select(.disabled == false)] | map(.name)) == ["DP-9"]
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null ||
  fail 'saved physical output did not follow its renamed connector'

printf '%s\n' '==> balanced and matched profiles use integer logical sizes and bottom alignment'
reset_fixture
run_display apply extend
jq -e '
  (.[] | select(.name == "eDP-1") |
    .scale == 1.5 and .x == 0 and .y == 240 and (.width / .scale) == 1920 and (.height / .scale) == 1200)
  and (.[] | select(.name == "DP-1") |
    .scale == 1.5 and .x == 1920 and .y == 0 and (.width / .scale) == 2560 and (.height / .scale) == 1440)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'balanced profile is wrong'
run_display revert

run_display apply-profile matched
jq -e '
  (.[] | select(.name == "eDP-1") |
    .scale == 2.25 and .x == 0 and .y == 640 and (.width / .scale) == 1280 and (.height / .scale) == 800)
  and (.[] | select(.name == "DP-1") |
    .scale == 1.5 and .x == 1280 and .y == 0 and (.width / .scale) == 2560 and (.height / .scale) == 1440)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'matched profile is wrong'
run_display revert

printf '%s\n' '==> legacy managed defaults migrate while custom topology remains untouched'
reset_fixture
topology=$(run_display status --json | jq -r '.topology')
profile_dir=$XDG_CONFIG_HOME/enoshima/user/display-topologies
mkdir -p -- "$profile_dir"
cat >"$profile_dir/$topology.json" <<'JSON'
{
  "schema": 1,
  "mode": "extend",
  "monitors": [
    {"name":"eDP-1","mode":"2880x1800@120","position":"0x240","scale":1.5,"transform":0,"mirror":"none","fingerprint":"Samsung|ATNA40|INT1|Internal OLED"},
    {"name":"DP-1","mode":"3840x2160@120","position":"1920x0","scale":1.5,"transform":0,"mirror":"none","fingerprint":"Dell|U2725QE|EXT1|Dell U2725QE"}
  ]
}
JSON
run_display reconcile
jq -e '
  (.[] | select(.name == "eDP-1") | .scale == 1.5 and .x == 0 and .y == 240)
  and (.[] | select(.name == "DP-1") | .scale == 1.5 and .x == 1920 and .y == 0)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'legacy managed profile was not migrated'
jq -e '.schema == 2 and .policy_revision == 3 and .profile == "balanced"' \
  "$profile_dir/$topology.json" >/dev/null || fail 'migrated profile was not persisted as schema 2'

printf '%s\n' '==> previous policy defaults refresh while named profiles remain untouched'
reset_fixture
topology=$(run_display status --json | jq -r '.topology')
profile_dir=$XDG_CONFIG_HOME/enoshima/user/display-topologies
mkdir -p -- "$profile_dir"
cat >"$profile_dir/$topology.json" <<'JSON'
{
  "schema": 2,
  "policy_revision": 2,
  "mode": "extend",
  "profile": "balanced",
  "monitors": [
    {"name":"eDP-1","mode":"2880x1800@120","position":"0x540","scale":2,"transform":0,"mirror":"none","fingerprint":"Samsung|ATNA40|INT1|Internal OLED"},
    {"name":"DP-1","mode":"3840x2160@120","position":"1440x0","scale":1.5,"transform":0,"mirror":"none","fingerprint":"Dell|U2725QE|EXT1|Dell U2725QE"}
  ]
}
JSON
run_display reconcile
jq -e '
  (.[] | select(.name == "eDP-1") | .scale == 1.5 and .x == 0 and .y == 240)
  and (.[] | select(.name == "DP-1") | .scale == 1.5 and .x == 1920 and .y == 0)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'previous balanced policy was not refreshed'
jq -e '.schema == 2 and .policy_revision == 3 and .profile == "balanced"' \
  "$profile_dir/$topology.json" >/dev/null || fail 'refreshed balanced policy was not persisted'

reset_fixture
topology=$(run_display status --json | jq -r '.topology')
profile_dir=$XDG_CONFIG_HOME/enoshima/user/display-topologies
mkdir -p -- "$profile_dir"
cat >"$profile_dir/$topology.json" <<'JSON'
{
  "schema": 2,
  "policy_revision": 2,
  "mode": "extend",
  "profile": "custom",
  "monitors": [
    {"name":"eDP-1","mode":"2880x1800@120","position":"0x100","scale":1.75,"transform":0,"mirror":"none","fingerprint":"Samsung|ATNA40|INT1|Internal OLED"},
    {"name":"DP-1","mode":"3840x2160@120","position":"1646x0","scale":1.25,"transform":0,"mirror":"none","fingerprint":"Dell|U2725QE|EXT1|Dell U2725QE"}
  ]
}
JSON
before=$(sha256sum "$profile_dir/$topology.json" | cut -d' ' -f1)
run_display reconcile
after=$(sha256sum "$profile_dir/$topology.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'custom schema 2 profile was rewritten'
jq -e '
  (.[] | select(.name == "eDP-1") | .scale == 1.75 and .x == 0 and .y == 100)
  and (.[] | select(.name == "DP-1") | .scale == 1.25 and .x == 1646 and .y == 0)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'custom schema 2 profile was not preserved'

reset_fixture
topology=$(run_display status --json | jq -r '.topology')
profile_dir=$XDG_CONFIG_HOME/enoshima/user/display-topologies
mkdir -p -- "$profile_dir"
cat >"$profile_dir/$topology.json" <<'JSON'
{
  "schema": 2,
  "policy_revision": 2,
  "mode": "extend",
  "profile": "matched",
  "monitors": [
    {"name":"eDP-1","mode":"2880x1800@120","position":"0x640","scale":2.25,"transform":0,"mirror":"none","fingerprint":"Samsung|ATNA40|INT1|Internal OLED"},
    {"name":"DP-1","mode":"3840x2160@120","position":"1280x0","scale":1.5,"transform":0,"mirror":"none","fingerprint":"Dell|U2725QE|EXT1|Dell U2725QE"}
  ]
}
JSON
before=$(sha256sum "$profile_dir/$topology.json" | cut -d' ' -f1)
run_display reconcile
after=$(sha256sum "$profile_dir/$topology.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'matched schema 2 profile was rewritten'
jq -e '
  (.[] | select(.name == "eDP-1") | .scale == 2.25 and .x == 0 and .y == 640)
  and (.[] | select(.name == "DP-1") | .scale == 1.5 and .x == 1280 and .y == 0)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'matched schema 2 profile was not preserved'

reset_fixture
topology=$(run_display status --json | jq -r '.topology')
profile_dir=$XDG_CONFIG_HOME/enoshima/user/display-topologies
mkdir -p -- "$profile_dir"
cat >"$profile_dir/$topology.json" <<'JSON'
{
  "schema": 1,
  "mode": "extend",
  "monitors": [
    {"name":"eDP-1","mode":"2880x1800@120","position":"0x100","scale":1.75,"transform":0,"mirror":"none","fingerprint":"Samsung|ATNA40|INT1|Internal OLED"},
    {"name":"DP-1","mode":"3840x2160@120","position":"1646x0","scale":1.25,"transform":0,"mirror":"none","fingerprint":"Dell|U2725QE|EXT1|Dell U2725QE"}
  ]
}
JSON
before=$(sha256sum "$profile_dir/$topology.json" | cut -d' ' -f1)
run_display reconcile
after=$(sha256sum "$profile_dir/$topology.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'custom schema 1 profile was rewritten'
jq -e '
  (.[] | select(.name == "eDP-1") | .scale == 1.75 and .x == 0 and .y == 100)
  and (.[] | select(.name == "DP-1") | .scale == 1.25 and .x == 1646 and .y == 0)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'custom schema 1 profile was not preserved'

printf '%s\n' '==> duplicate mode chooses a real common resolution and refresh rate'
reset_fixture
run_display apply mirror
jq -e '
  (.[] | select(.name == "eDP-1") | .width == 1920 and .height == 1080)
  and (.[] | select(.name == "DP-1") | .mirrorOf == "eDP-1" and .width == 1920 and .height == 1080)
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'compatible mirror mode was not applied'
run_display confirm

printf '%s\n' '==> saved duplicate mode remaps its source after a connector rename'
jq 'map(if .name == "DP-1" then .name = "DP-9" | .mirrorOf = "none" else .mirrorOf = "none" end)' \
  "$DISPLAY_TEST_ROOT/monitors.json" >"$DISPLAY_TEST_ROOT/next.json"
mv -f -- "$DISPLAY_TEST_ROOT/next.json" "$DISPLAY_TEST_ROOT/monitors.json"
run_display reconcile
jq -e '
  (.[] | select(.name == "DP-9") | .mirrorOf == "eDP-1")
' "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null ||
  fail 'saved mirror source did not survive a connector rename'

printf '%s\n' '==> duplicate mode refuses incompatible outputs without changing layout'
reset_fixture
jq 'map(if .name == "DP-1" then .availableModes = ["1024x768@60.00Hz"] else . end)' \
  "$DISPLAY_TEST_ROOT/monitors.json" >"$DISPLAY_TEST_ROOT/next.json"
mv -f -- "$DISPLAY_TEST_ROOT/next.json" "$DISPLAY_TEST_ROOT/monitors.json"
before=$(sha256sum "$DISPLAY_TEST_ROOT/monitors.json" | cut -d' ' -f1)
if run_display apply mirror 2>/dev/null; then
  fail 'incompatible mirror mode unexpectedly succeeded'
fi
after=$(sha256sum "$DISPLAY_TEST_ROOT/monitors.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'failed mirror attempt changed monitor state'

printf '%s\n' '==> extend is unavailable when no external output is connected'
reset_fixture
jq '[.[] | select(.name == "eDP-1")]' "$DISPLAY_TEST_ROOT/monitors.json" >"$DISPLAY_TEST_ROOT/next.json"
mv -f -- "$DISPLAY_TEST_ROOT/next.json" "$DISPLAY_TEST_ROOT/monitors.json"
jq -e '.modes | map(select(.id == "extend"))[0].available == false' \
  < <(run_display list --json) >/dev/null || fail 'extend remained available without an external output'
before=$(sha256sum "$DISPLAY_TEST_ROOT/monitors.json" | cut -d' ' -f1)
if run_display apply extend 2>/dev/null; then
  fail 'extend unexpectedly succeeded without an external output'
fi
after=$(sha256sum "$DISPLAY_TEST_ROOT/monitors.json" | cut -d' ' -f1)
[[ $before == "$after" ]] || fail 'failed extend attempt changed monitor state'

printf '%s\n' '==> rollback timer failure immediately restores the safe snapshot'
reset_fixture
if DISPLAY_SYSTEMCTL_FAIL=true run_display apply internal 2>/dev/null; then
  fail 'apply unexpectedly succeeded without an automatic rollback timer'
fi
jq -e '[.[] | select(.disabled == false)] | length == 2' \
  "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null ||
  fail 'timer failure did not restore the original layout'
[[ ! -e $XDG_RUNTIME_DIR/enoshima/display/pending.json ]] ||
  fail 'timer failure retained a pending transaction'

printf '%s\n' '==> projection overlay reports apply failures in context'
grep -Fq 'id: applyProcess' "$overlay_qml" ||
  fail 'projection overlay does not track the apply process'
grep -Fq 'id: applyResultCollector' "$overlay_qml" ||
  fail 'projection overlay does not capture apply results'
grep -Fq 'Accessible.role: Accessible.AlertMessage' "$overlay_qml" ||
  fail 'projection overlay error is not exposed to accessibility clients'
grep -Fq '호환되는 복제 모드가 없습니다.' "$overlay_qml" ||
  fail 'projection overlay lacks the duplicate-mode recovery message'
# shellcheck disable=SC2016 # Match the literal command in the managed helper.
grep -Fq '"$socat_bin" -u "UNIX-CONNECT:$socket" STDOUT' "$event_listener" ||
  fail 'display listener still closes its socket when service stdin reaches EOF'
grep -Fxq 'Restart=always' "$event_service" ||
  fail 'display listener does not reconnect after a compositor socket closes'

printf 'Desktop display mode tests passed.\n'
