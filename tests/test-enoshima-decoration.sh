#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

plugin=native/enoshima-decoration
config=home/dot_config/enoshima/window-interaction.yaml
lua=home/dot_config/hypr/hyprland.lua
loader=home/dot_local/bin/executable_enoshima-decoration-load

cleanup() { make -s -C "$plugin" clean; }
trap cleanup EXIT

[[ $(yq -r '.decoration.owner' "$config") == enoshima-decoration ]]
[[ $(yq -r '.decoration.positive_allowlist | length' "$config") -gt 0 ]]
if yq -e '.decoration.positive_allowlist[] | select(.mode != "enoshima-system")' \
  "$config" >/dev/null; then
  printf 'Decoration allowlist contains a non-Enoshima owner.\n' >&2
  exit 1
fi

expected=$(yq -r '.decoration.positive_allowlist | map(.class) | join(",")' "$config")
grep -Fq "allowlist = \"$expected\"" "$lua"
grep -Fq 'classMatchesAllowlist' "$plugin/src/main.cpp"
grep -Fq 'windowIsAllowlisted(window)' "$plugin/src/main.cpp"
grep -Fq 'addWindowDecoration' "$plugin/src/main.cpp"
grep -Fq 'ABI mismatch' "$plugin/src/main.cpp"
grep -Fq 'enoshima-snap-controller preview' "$plugin/src/barDeco.cpp"
grep -Fq 'enoshima-snap-controller commit' "$plugin/src/barDeco.cpp"
grep -Fq 'enoshima-snap-controller cancel' "$plugin/src/barDeco.cpp"
grep -Fq 'enoshima-window-menu' "$plugin/src/barDeco.cpp"
grep -Fq 'bar_hit_height = 44' "$lua"
grep -Fq 'hl.bind("ALT + SPACE"' "$lua"

grep -Fq 'recorded_abi == "$abi"' "$loader"
grep -Fq 'hyprctl plugin load "$plugin"' "$loader"
grep -Fq 'hyprpm disable hyprbars' bootstrap.sh
grep -Fq 'enoshima-decoration-load' bootstrap.sh

make -s -C "$plugin" all
[[ -s $plugin/enoshima-decoration.so ]]

printf 'Enoshima decoration tests passed.\n'
