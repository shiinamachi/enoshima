#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_cyberdock-pins
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export HOME=$work/home
export CYBERDOCK_PINS_CONFIG_HOME=$HOME/.config
export CYBERDOCK_PINS_DEFAULTS_FILE=$repo_root/home/dot_config/enoshima/defaults/cyberdock-pins.json

fail() {
  printf 'test-cyberdock-pins: %s\n' "$*" >&2
  exit 1
}

run_pins() {
  bash "$helper" "$@"
}

printf '%s\n' '==> first read seeds a private user-owned store'
state=$(run_pins list --json)
jq -e '.schema == 1 and (.entries | length == 4)' <<<"$state" >/dev/null ||
  fail 'managed defaults were not seeded'
user_file=$HOME/.config/enoshima/user/cyberdock-pins.json
[[ $(stat -c %a "$(dirname -- "$user_file")") == 700 ]] || fail 'user directory is not private'
[[ $(stat -c %a "$user_file") == 600 ]] || fail 'user state is not private'

printf '%s\n' '==> add, toggle, and remove preserve unique desktop entry IDs'
run_pins add org.example.New.desktop
run_pins add org.example.New.desktop
[[ $(jq -r '[.entries[] | select(. == "org.example.New.desktop")] | length' "$user_file") == 1 ]] ||
  fail 'add created a duplicate'
run_pins toggle org.example.New.desktop
jq -e '.entries | index("org.example.New.desktop") == null' "$user_file" >/dev/null ||
  fail 'toggle did not remove the entry'
run_pins toggle org.example.New.desktop
run_pins remove org.example.New.desktop

printf '%s\n' '==> reorder supports pointer and keyboard-equivalent directions'
run_pins move google-chrome.desktop --before thunar.desktop
jq -e '.entries[1] == "google-chrome.desktop" and .entries[2] == "thunar.desktop"' \
  "$user_file" >/dev/null || fail 'move before failed'
run_pins move google-chrome.desktop --after dev.zed.Zed.desktop
jq -e '.entries[3] == "google-chrome.desktop"' "$user_file" >/dev/null ||
  fail 'move after failed'

printf '%s\n' '==> malformed state recovers from the last valid backup'
printf '%s\n' '{broken' >"$user_file"
state=$(run_pins list --json)
jq -e '.schema == 1 and (.entries | length == 4)' <<<"$state" >/dev/null ||
  fail 'last valid backup was not restored'

printf '%s\n' '==> import, export, reset, and validation are deterministic'
cat >"$work/import.json" <<'JSON'
{"schema":1,"entries":["org.example.One.desktop","org.example.One.desktop","org.example.Two.desktop"]}
JSON
run_pins import "$work/import.json"
jq -e '.entries == ["org.example.One.desktop", "org.example.Two.desktop"]' "$user_file" >/dev/null ||
  fail 'import did not normalize duplicates'
run_pins export "$work/export.json"
cmp -s "$user_file" "$work/export.json" || fail 'export differs from state'
run_pins reset
jq -e '.entries[0] == "com.mitchellh.ghostty.desktop"' "$user_file" >/dev/null ||
  fail 'reset did not restore managed defaults'
if run_pins add 'ghostty;reboot.desktop' 2>/dev/null; then
  fail 'unsafe desktop entry ID was accepted'
fi

printf '%s\n' '==> concurrent updates retain valid atomic JSON'
pids=()
for index in {1..12}; do
  run_pins add "org.example.Concurrent$index.desktop" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
jq -e '.schema == 1 and (.entries | type == "array")' "$user_file" >/dev/null ||
  fail 'concurrent writes corrupted state'

printf 'Cyberdock pin tests passed.\n'
