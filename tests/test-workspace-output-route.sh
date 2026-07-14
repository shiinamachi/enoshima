#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper="$repo_root/home/dot_local/bin/executable_workspace-output-route"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$test_root/hyprctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

root=${WORKSPACE_OUTPUT_ROUTE_TEST_ROOT:?}

case ${1-} in
monitors)
  cat "$root/monitors.json"
  ;;
workspaces)
  cat "$root/workspaces.json"
  ;;
dispatch)
  expression=${2-}
  [[ $expression == hl.dsp.workspace.move* ]] || exit 64
  workspace_id=$(sed -nE 's/.*workspace = ([0-9]+).*/\1/p' <<<"$expression")
  output=$(sed -nE 's/.*monitor = "([[:alnum:]_.-]+)".*/\1/p' <<<"$expression")
  [[ -n $workspace_id && -n $output ]] || exit 64
  printf '%s\t%s\n' "$workspace_id" "$output" >>"$root/dispatch.log"
  jq --argjson id "$workspace_id" --arg output "$output" \
    'map(if .id == $id then .monitor = $output else . end)' \
    "$root/workspaces.json" >"$root/workspaces.next"
  mv -- "$root/workspaces.next" "$root/workspaces.json"
  ;;
*)
  exit 64
  ;;
esac
SH
chmod +x "$test_root/hyprctl"

cat >"$test_root/monitors.json" <<'JSON'
[
  {"name":"eDP-1","description":"Samsung Display Corp. ATNA40HQ02-0","model":"ATNA40HQ02-0","x":0},
  {"name":"HDMI-A-1","description":"LG Electronics 27UP850","model":"27UP850","x":1920}
]
JSON

jq -n '[range(1; 11) | {id: ., name: tostring, monitor: "eDP-1"}]' \
  >"$test_root/workspaces.json"
: >"$test_root/dispatch.log"

run_helper() {
  WORKSPACE_OUTPUT_ROUTE_HYPRCTL="$test_root/hyprctl" \
    WORKSPACE_OUTPUT_ROUTE_TEST_ROOT="$test_root" \
    "$helper"
}

printf '%s\n' '==> any extended monitor receives DEV, WEB, and REMOTE workspaces'
run_helper
for id in 1 2 4; do
  grep -Fqx "$id"$'\tHDMI-A-1' "$test_root/dispatch.log" ||
    fail "workspace $id was not routed to the detected external output"
done
jq -e '
  all(.[] | select(.id == 1 or .id == 2 or .id == 4); .monitor == "HDMI-A-1")
  and all(.[] | select(.id == 3 or .id >= 5); .monitor == "eDP-1")
' "$test_root/workspaces.json" >/dev/null || fail 'connected workspace layout is incorrect'

printf '%s\n' '==> repeated routing is idempotent'
: >"$test_root/dispatch.log"
run_helper
[[ ! -s $test_root/dispatch.log ]] || fail 'unchanged workspaces were moved again'

printf '%s\n' '==> multiple extended monitors share the external workspace set'
jq '. + [{"name":"DP-7","description":"ASUS ProArt","model":"PA279CV","x":4480}]' \
  "$test_root/monitors.json" >"$test_root/monitors.next"
mv -- "$test_root/monitors.next" "$test_root/monitors.json"
run_helper
grep -Fqx $'2\tDP-7' "$test_root/dispatch.log" ||
  fail 'the second external output did not receive a workspace'
jq -e '
  (map(select(.id == 1 or .id == 4)) | all(.monitor == "HDMI-A-1"))
  and (map(select(.id == 2))[0].monitor == "DP-7")
' "$test_root/workspaces.json" >/dev/null || fail 'multi-output workspace layout is incorrect'

printf '%s\n' '==> disconnect returns every managed workspace to the laptop panel'
jq 'map(select(.name == "eDP-1"))' "$test_root/monitors.json" \
  >"$test_root/monitors.next"
mv -- "$test_root/monitors.next" "$test_root/monitors.json"
run_helper
for id in 1 2 4; do
  grep -Fqx "$id"$'\teDP-1' "$test_root/dispatch.log" ||
    fail "workspace $id was not recovered to the laptop output"
done
jq -e 'all(.[]; .monitor == "eDP-1")' "$test_root/workspaces.json" >/dev/null ||
  fail 'disconnected workspace layout is incorrect'

printf '%s\n' 'PASS: workspace output routing behavior'
