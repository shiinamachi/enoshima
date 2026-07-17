#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

plugin=native/enoshima-decoration
config=home/dot_config/enoshima/window-interaction.yaml
lua=home/dot_config/hypr/hyprland.lua
loader=home/dot_local/bin/executable_enoshima-decoration-load
window_menu=home/dot_config/quickshell/cyberdock/EnoshimaWindowMenu.qml
work=$(mktemp -d)

cleanup() {
  make -s -C "$plugin" clean
  rm -rf -- "$work"
}
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
grep -Fq -- '-Wall -Wextra -Wformat=2 -Werror' "$plugin/Makefile"
if grep -Fq -- '-Wno-c++11-narrowing' "$plugin/Makefile"; then
  printf 'Decoration build retains a compiler-specific warning suppression.\n' >&2
  exit 1
fi
grep -Fq 'Qt.callLater(() => scrimInput.forceActiveFocus())' "$window_menu"
grep -Fq 'Keys.onPressed: event => menu.handleKey(event)' "$window_menu"
if grep -Fq '    Keys.onPressed: event => {' "$window_menu"; then
  printf 'Window menu attaches Keys directly to a non-Item PanelWindow.\n' >&2
  exit 1
fi
grep -Fq 'bar_hit_height = 44' "$lua"
grep -Fq 'hl.bind("ALT + SPACE"' "$lua"

grep -Fq 'recorded_abi == "$abi"' "$loader"
grep -Fq 'hyprctl plugin load "$plugin"' "$loader"
grep -Fq '(_[[:alnum:]]+([.-][[:alnum:]]+)*)*' scripts/postflight.sh
grep -Fq 'hyprpm disable hyprbars' bootstrap.sh
grep -Fq 'enoshima-decoration-load' bootstrap.sh

printf '%s\n' '==> composite Hyprland ABI loads the matching decoration plugin'
composite_abi=0123456789abcdef0123456789abcdef01234567_aq_0.12_hu_0.13_hg_0.5
mkdir -p \
  "$work/bin" \
  "$work/config/enoshima" \
  "$work/data/enoshima/plugins/$composite_abi" \
  "$work/state/enoshima-decoration"
cp "$config" "$work/config/enoshima/window-interaction.yaml"
touch "$work/data/enoshima/plugins/$composite_abi/enoshima-decoration.so"
printf '%s\n' "$composite_abi" >"$work/state/enoshima-decoration/hyprland-abi"
cat >"$work/bin/Hyprland" <<'EOF'
#!/usr/bin/env bash
printf 'Version ABI string: %s\n' "$TEST_HYPRLAND_ABI"
EOF
cat >"$work/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'plugin list -j') printf '[]\n' ;;
  plugin\ load\ *) printf '%s\n' "${3:-}" >"$TEST_HYPRCTL_LOG" ;;
  'reload config-only') ;;
  *) exit 64 ;;
esac
EOF
chmod 0700 "$work/bin/Hyprland" "$work/bin/hyprctl"
PATH="$work/bin:$PATH" \
  XDG_CONFIG_HOME="$work/config" \
  XDG_DATA_HOME="$work/data" \
  XDG_STATE_HOME="$work/state" \
  HYPRLAND_INSTANCE_SIGNATURE=test \
  TEST_HYPRLAND_ABI="$composite_abi" \
  TEST_HYPRCTL_LOG="$work/hyprctl.log" \
  bash "$loader"
[[ $(<"$work/hyprctl.log") == "$work/data/enoshima/plugins/$composite_abi/enoshima-decoration.so" ]]

printf '%s\n' '==> unsafe Hyprland ABI cannot escape the plugin root'
if PATH="$work/bin:$PATH" \
  XDG_CONFIG_HOME="$work/config" \
  XDG_DATA_HOME="$work/data" \
  XDG_STATE_HOME="$work/state" \
  HYPRLAND_INSTANCE_SIGNATURE=test \
  TEST_HYPRLAND_ABI="${composite_abi}_../../outside" \
  TEST_HYPRCTL_LOG="$work/unsafe.log" \
  bash "$loader" >/dev/null 2>&1; then
  printf 'Unsafe composite ABI unexpectedly passed validation.\n' >&2
  exit 1
fi
[[ ! -e $work/unsafe.log ]]

make -s -C "$plugin" all
[[ -s $plugin/enoshima-decoration.so ]]

printf 'Enoshima decoration tests passed.\n'
