#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-appearance
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'Desktop appearance test failed: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$test_root/bin" "$test_root/home"
log=$test_root/hyprctl.log

cat >"$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_HYPRCTL_LOG"
case ${1:-} in
  monitors)
    printf '[]\n'
    ;;
  getoption)
    if [[ ${FAKE_PLUGIN_AVAILABLE:-true} == true ]]; then
      printf '{"option":"plugin:hyprfocus:mode","str":"flash"}\n'
    else
      printf 'no such option\n'
    fi
    ;;
esac
EOF
chmod +x "$test_root/bin/hyprctl"

run_helper() {
  env \
    PATH="$test_root/bin:/usr/bin" \
    HOME="$test_root/home" \
    XDG_STATE_HOME="$test_root/state" \
    FAKE_HYPRCTL_LOG="$log" \
    FAKE_PLUGIN_AVAILABLE="${FAKE_PLUGIN_AVAILABLE:-true}" \
    bash "$helper" "$@"
}

assert_logged() {
  grep -Fxq -- "$1" "$log" || fail "missing hyprctl call: $1"
}

assert_not_logged() {
  if grep -Fxq -- "$1" "$log"; then
    fail "unexpected hyprctl call: $1"
  fi
}

[[ $(run_helper status) == default ]] || fail 'default mode was not reported'

: >"$log"
[[ $(run_helper reduced-motion) == reduced-motion ]] || fail 'reduced-motion failed'
assert_logged reload
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'
assert_not_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'
[[ $(stat -c %a "$test_root/state/desktop-appearance/mode") == 600 ]] ||
  fail 'stored mode is not private'

: >"$log"
[[ $(run_helper reduced-transparency) == reduced-transparency ]] ||
  fail 'reduced-transparency failed'
assert_logged reload
assert_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'
assert_not_logged 'eval hl.config({ animations = { enabled = false } })'

: >"$log"
[[ $(run_helper accessible) == accessible ]] || fail 'accessible mode failed'
assert_logged reload
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'
assert_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'

: >"$log"
run_helper default >/dev/null
assert_logged reload
assert_not_logged 'eval hl.config({ animations = { enabled = false } })'
assert_not_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'

: >"$log"
FAKE_PLUGIN_AVAILABLE=false run_helper reduced-motion >/dev/null
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_not_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'

: >"$log"
FAKE_PLUGIN_AVAILABLE=false run_helper apply
assert_not_logged reload
assert_logged 'eval hl.config({ animations = { enabled = false } })'

if run_helper unsupported >/dev/null 2>&1; then
  fail 'unsupported mode unexpectedly succeeded'
fi

printf 'Desktop appearance accessibility tests passed.\n'
