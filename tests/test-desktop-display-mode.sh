#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-display-mode
overlay_qml=$repo_root/home/dot_config/quickshell/cyberdock/DisplayModeOverlay.qml
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

printf '%s\n' '==> status and availability describe the connected topology'
reset_fixture
jq -e '.mode == "extend" and .external_count == 1 and (.pending | not)' \
  < <(run_display status --json) >/dev/null || fail 'initial status is wrong'
jq -e '.modes | all(.available)' < <(run_display list --json) >/dev/null ||
  fail 'all projection modes should be available'

printf '%s\n' '==> internal-only enables its safe target before disabling externals'
run_display apply internal
jq -e '[.[] | select(.disabled == false)] | map(.name) == ["eDP-1"]' \
  "$DISPLAY_TEST_ROOT/monitors.json" >/dev/null || fail 'internal-only mode is wrong'
[[ $(sed -n '1p' "$DISPLAY_TEST_ROOT/calls.log") == single ]] ||
  fail 'target output was not enabled before the disable batch'
jq -e '.pending and .target_mode == "internal" and .seconds_remaining > 0' \
  < <(run_display status --json) >/dev/null || fail 'rollback transaction was not armed'
grep -Fq -- '--user restart desktop-display-revert.timer' "$DISPLAY_TEST_ROOT/systemctl.log" ||
  fail 'automatic rollback timer was not started'

printf '%s\n' '==> revert restores every output from the transaction snapshot'
run_display revert
jq -e '[.[] | select(.disabled == false)] | length == 2' \
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
jq -e '.schema == 1 and .mode == "external"' \
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
grep -Fq 'stderr: StdioCollector { id: applyErrorCollector }' "$overlay_qml" ||
  fail 'projection overlay does not capture apply errors'
grep -Fq 'Accessible.role: Accessible.AlertMessage' "$overlay_qml" ||
  fail 'projection overlay error is not exposed to accessibility clients'
grep -Fq '호환되는 복제 모드가 없습니다.' "$overlay_qml" ||
  fail 'projection overlay lacks the duplicate-mode recovery message'

printf 'Desktop display mode tests passed.\n'
