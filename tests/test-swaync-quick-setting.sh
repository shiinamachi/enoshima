#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_swaync-quick-setting
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'SwayNC quick-setting test failed: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$test_root/bin"
call_log=$test_root/calls.log

cat >"$test_root/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nmcli %s\n' "$*" >>"$FAKE_CALL_LOG"
if [[ $* == 'radio wifi' ]]; then
  printf '%s\n' "${FAKE_WIFI_STATE:-disabled}"
fi
EOF

cat >"$test_root/bin/bluetoothctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'bluetoothctl %s\n' "$*" >>"$FAKE_CALL_LOG"
if [[ ${1:-} == show ]]; then
  printf 'Powered: %s\n' "${FAKE_BLUETOOTH_STATE:-no}"
fi
EOF

cat >"$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >>"$FAKE_CALL_LOG"
if [[ $* == '--user is-active --quiet hyprsunset-quick.service' ]]; then
  [[ ${FAKE_NIGHT_LIGHT_STATE:-inactive} == active ]]
fi
EOF
chmod +x "$test_root/bin/"{nmcli,bluetoothctl,systemctl}

run_helper() {
  env \
    PATH="$test_root/bin:/usr/bin" \
    FAKE_CALL_LOG="$call_log" \
    FAKE_WIFI_STATE="${FAKE_WIFI_STATE:-disabled}" \
    FAKE_BLUETOOTH_STATE="${FAKE_BLUETOOTH_STATE:-no}" \
    FAKE_NIGHT_LIGHT_STATE="${FAKE_NIGHT_LIGHT_STATE:-inactive}" \
    SWAYNC_TOGGLE_STATE="${SWAYNC_TOGGLE_STATE:-}" \
    bash "$helper" "$@"
}

assert_logged() {
  grep -Fxq -- "$1" "$call_log" || fail "missing command: $1"
}

[[ $(FAKE_WIFI_STATE=enabled run_helper status wifi) == true ]] ||
  fail 'enabled Wi-Fi was not reported as true'
[[ $(FAKE_WIFI_STATE=disabled run_helper status wifi) == false ]] ||
  fail 'disabled Wi-Fi was not reported as false'
[[ $(FAKE_BLUETOOTH_STATE=yes run_helper status bluetooth) == true ]] ||
  fail 'powered Bluetooth was not reported as true'
[[ $(FAKE_BLUETOOTH_STATE=no run_helper status bluetooth) == false ]] ||
  fail 'unpowered Bluetooth was not reported as false'
[[ $(FAKE_NIGHT_LIGHT_STATE=active run_helper status night-light) == true ]] ||
  fail 'active Night Light was not reported as true'
[[ $(FAKE_NIGHT_LIGHT_STATE=inactive run_helper status night-light) == false ]] ||
  fail 'inactive Night Light was not reported as false'

: >"$call_log"
SWAYNC_TOGGLE_STATE=true run_helper apply wifi
SWAYNC_TOGGLE_STATE=false run_helper apply wifi
SWAYNC_TOGGLE_STATE=true run_helper apply bluetooth
SWAYNC_TOGGLE_STATE=false run_helper apply bluetooth
SWAYNC_TOGGLE_STATE=true run_helper apply night-light
SWAYNC_TOGGLE_STATE=false run_helper apply night-light
assert_logged 'nmcli radio wifi on'
assert_logged 'nmcli radio wifi off'
assert_logged 'bluetoothctl power on'
assert_logged 'bluetoothctl power off'
assert_logged 'systemctl --user start hyprsunset-quick.service'
assert_logged 'systemctl --user stop hyprsunset-quick.service'

if SWAYNC_TOGGLE_STATE=invalid run_helper apply wifi >/dev/null 2>&1; then
  fail 'invalid toggle state unexpectedly succeeded'
fi

printf 'SwayNC quick-setting tests passed.\n'
