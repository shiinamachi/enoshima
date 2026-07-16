#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'Login manager test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local path=$1 expected=$2
  grep -Fq -- "$expected" "$path" || fail "$path does not contain: $expected"
}

assert_not_contains() {
  local path=$1 unexpected=$2
  if grep -Fq -- "$unexpected" "$path"; then
    fail "$path unexpectedly contains: $unexpected"
  fi
}

group_vars=ansible/inventory/group_vars/all.yml
host_vars=ansible/inventory/host_vars/tpx1c13.yml
login_tasks=ansible/roles/system/tasks/login-manager.yml
greetd_config=ansible/roles/system/templates/greetd-config.toml.j2
greetd_hyprland=ansible/roles/system/templates/greetd-hyprland.conf.j2
greetd_session=ansible/roles/system/templates/greetd-session.sh.j2
regreet_config=ansible/roles/system/templates/regreet.toml.j2
regreet_css=ansible/roles/system/templates/regreet.css.j2
session_entry=ansible/roles/system/templates/enoshima-hyprland-uwsm.desktop.j2
sddm_config=ansible/roles/system/templates/sddm-hidpi.conf.j2
sddm_qml=ansible/roles/desktop_expansion/files/sddm-cyberpunk/Main.qml

printf '%s\n' '==> login manager selection and package contract'
grep -Fxq greetd packages/native.txt || fail 'greetd is not a native package'
grep -Fxq greetd-regreet packages/native.txt || fail 'greetd-regreet is not a native package'
grep -Fxq sddm packages/native.txt || fail 'SDDM fallback package was removed prematurely'
assert_contains "$group_vars" 'desktop_login_manager: sddm'
assert_contains "$group_vars" 'desktop_login_manager_apply_now: false'
assert_contains "$host_vars" 'desktop_login_manager: greetd'
assert_not_contains "$host_vars" '  - sddm.service'
assert_not_contains "$host_vars" '  - greetd.service'
assert_contains ansible/roles/system/tasks/main.yml 'import_tasks: login-manager.yml'

printf '%s\n' '==> login managers are mutually exclusive and do not stop the live session by default'
assert_contains "$login_tasks" "desktop_login_manager in ['greetd', 'sddm']"
assert_contains "$login_tasks" "'sddm.service' if desktop_login_manager == 'greetd' else 'greetd.service'"
assert_contains "$login_tasks" 'name: "{{ desktop_login_manager }}.service"'
assert_contains "$login_tasks" 'enabled: false'
assert_contains "$login_tasks" 'enabled: true'
[[ $(grep -Fc 'when: desktop_login_manager_apply_now | bool' "$login_tasks") == 2 ]] ||
  fail 'runtime service replacement is not fully gated by the TTY-only switch'

printf '%s\n' '==> greetd launches only the isolated ReGreet compositor'
python - "$greetd_config" "$regreet_config" <<'PY'
import sys
import tomllib

for path in sys.argv[1:]:
    with open(path, "rb") as handle:
        tomllib.load(handle)
PY
assert_contains "$greetd_config" 'command = "dbus-run-session start-hyprland -- -c /etc/greetd/hyprland.conf"'
assert_contains "$greetd_config" 'user = "greeter"'
for contract in \
  'monitor = eDP-1,2880x1800@120,0x540,2' \
  'monitor = desc:Dell Inc. DELL U2725QE,3840x2160@120,1440x0,1.5' \
  'monitor = ,preferred,auto-right,auto' \
  'env = GTK_USE_PORTAL,0' \
  'env = GDK_DEBUG,no-portals' \
  'bindl = , switch:on:Lid Switch, exec, /usr/local/lib/enoshima/greetd-session lid-closed' \
  'bindl = , switch:off:Lid Switch, exec, /usr/local/lib/enoshima/greetd-session lid-open' \
  'exec-once = /usr/local/lib/enoshima/greetd-session start'; do
  assert_contains "$greetd_hyprland" "$contract"
done
assert_not_contains "$greetd_hyprland" 'default_monitor = eDP-1'
assert_not_contains "$greetd_hyprland" 'waybar'
assert_not_contains "$greetd_hyprland" 'quickshell'
assert_not_contains "$greetd_hyprland" 'cyberdock'
# These contracts intentionally match literal shell variables in the template.
# shellcheck disable=SC2016
for contract in \
  'has_external_output()' \
  'lid_is_closed()' \
  '"$hyprctl_command" keyword monitor "$internal_output,disable"' \
  '"$hyprctl_command" keyword monitor "$internal_rule"' \
  '"$regreet_command"' \
  '"$hyprctl_command" dispatch exit'; do
  assert_contains "$greetd_session" "$contract"
done
assert_contains "$login_tasks" 'dest: /usr/local/lib/enoshima/greetd-session'
assert_contains "$login_tasks" 'mode: "0755"'

mkdir -p "$work/bin" "$work/lid/LID"
cat >"$work/bin/hyprctl" <<'SH'
#!/usr/bin/env sh
set -u
if [ "${1:-}" = -j ] && [ "${2:-}" = monitors ]; then
  printf '%s\n' "${GREETD_TEST_MONITORS:?}"
  exit 0
fi
printf 'hyprctl %s\n' "$*" >>"${GREETD_TEST_LOG:?}"
SH
cat >"$work/bin/regreet" <<'SH'
#!/usr/bin/env sh
printf 'regreet\n' >>"${GREETD_TEST_LOG:?}"
exit "${GREETD_TEST_REGREET_STATUS:-0}"
SH
chmod 0755 "$work/bin/hyprctl" "$work/bin/regreet"

run_greetd_session() {
  env \
    GREETD_HYPRCTL="$work/bin/hyprctl" \
    GREETD_REGREET="$work/bin/regreet" \
    GREETD_LID_STATE_ROOT="$work/lid" \
    GREETD_TEST_LOG="$work/session.log" \
    GREETD_TEST_MONITORS="$1" \
    sh "$greetd_session" "${2:-start}"
}

printf '%s\n' 'state:      closed' >"$work/lid/LID/state"
: >"$work/session.log"
run_greetd_session '[{"name":"eDP-1"},{"name":"DP-1"}]'
grep -Fxq 'hyprctl keyword monitor eDP-1,disable' "$work/session.log" ||
  fail 'closed-lid startup did not disable eDP when an external output existed'
grep -Fxq regreet "$work/session.log" || fail 'startup did not run ReGreet'
grep -Fxq 'hyprctl dispatch exit' "$work/session.log" ||
  fail 'ReGreet exit did not stop the isolated compositor'

: >"$work/session.log"
run_greetd_session '[{"name":"eDP-1"}]' lid-closed
[[ ! -s $work/session.log ]] || fail 'lid close disabled the only active output'

: >"$work/session.log"
run_greetd_session '[{"name":"DP-1"}]' lid-open
grep -Fxq 'hyprctl keyword monitor eDP-1,2880x1800@120,0x540,2' \
  "$work/session.log" || fail 'lid open did not restore the balanced eDP rule'

printf '%s\n' '==> ReGreet preserves the desktop accessibility and visual contracts'
assert_contains "$regreet_config" 'fit = "Cover"'
assert_contains "$regreet_config" 'font_name = "Pretendard 12"'
assert_contains "$regreet_config" 'theme_name = "adw-gtk3-dark"'
assert_contains "$regreet_css" 'min-height: 44px;'
assert_contains "$regreet_css" 'outline: 2px solid @cyber_focus;'
assert_contains "$regreet_css" '@define-color cyber_canvas #050623;'
assert_contains "$login_tasks" 'mode: "0644"'
assert_contains "$login_tasks" 'dest: /etc/greetd/background-16x10.jpg'
assert_contains scripts/postflight.sh 'greetd is the boot display manager'
assert_contains scripts/postflight.sh 'fallback SDDM is disabled'
assert_contains scripts/postflight.sh 'ReGreet mixed-DPI compositor configuration parses'
assert_contains scripts/postflight.sh 'ReGreet lid-aware session helper is executable'

printf '%s\n' '==> UWSM session entry is valid'
grep -Eq '^\[Desktop Entry\]$' "$session_entry" || fail 'session entry header is invalid'
grep -Eq '^Type=Application$' "$session_entry" || fail 'session entry type is invalid'
assert_contains "$session_entry" 'Exec=uwsm start -- hyprland.desktop'
assert_contains "$session_entry" 'TryExec=uwsm'

printf '%s\n' '==> greetd and fallback SDDM retain password-first fingerprint PAM'
for pam_template in \
  ansible/roles/system/templates/pam-greetd.j2 \
  ansible/roles/system/templates/pam-sddm.j2; do
  assert_contains "$pam_template" 'pam_unix.so try_first_pass likeauth nullok'
  assert_contains "$pam_template" 'pam_fprintd.so timeout=15 max-tries=3'
done
assert_contains ansible/roles/system/tasks/authentication.yml 'dest: /etc/pam.d/greetd'

printf '%s\n' '==> fallback SDDM has one geometry scale and a responsive root'
assert_contains "$sddm_config" 'DisplayServer=x11'
assert_contains "$sddm_config" 'GreeterEnvironment=QT_SCALE_FACTOR={{ sddm_scale_factor }}'
assert_not_contains "$sddm_config" 'QT_FONT_DPI'
assert_not_contains "$host_vars" 'sddm_font_dpi'
assert_not_contains "$sddm_qml" '    width: 1920'
assert_not_contains "$sddm_qml" '    height: 1080'
for contract in \
  'readonly property real shortSide: Math.min(width, height)' \
  'readonly property int panelWidth:' \
  'readonly property int safeMargin:' \
  'readonly property int controlHeight:' \
  'width: root.panelWidth' \
  'anchors.leftMargin: root.safeMargin' \
  'wrapMode: Text.WordWrap'; do
  assert_contains "$sddm_qml" "$contract"
done

python - <<'PY'
resolutions = [(1920, 1080), (1920, 1200), (2560, 1440), (2880, 1800), (3840, 2160)]
for width, height in resolutions:
    short = min(width, height)
    panel = round(max(420, min(640, width * 0.34)))
    margin = round(max(24, min(72, short * 0.04)))
    control = round(max(44, min(52, 48 * max(0.9, min(1.2, short / 1080)))))
    assert panel + 2 * margin <= width
    assert height - 2 * margin >= 800
    assert 44 <= control <= 52
PY

printf 'Login manager tests passed.\n'
