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
greeter_css=ansible/roles/system/templates/enoshima-greeter.css.j2
greeter_source=packages/local/enoshima-greeter/enoshima-greeter.c
greeter_pkgbuild=packages/local/enoshima-greeter/PKGBUILD
session_entry=ansible/roles/system/templates/enoshima-desktop.desktop.j2
hidden_session_entry=ansible/roles/system/templates/hidden-wayland-session.desktop.j2
sddm_config=ansible/roles/system/templates/sddm-hidpi.conf.j2
sddm_qml=ansible/roles/desktop_expansion/files/sddm-cyberpunk/Main.qml

printf '%s\n' '==> login manager selection and package contract'
grep -Fxq greetd packages/native.txt || fail 'greetd is not a native package'
grep -Fxq greetd-regreet packages/absent.txt || fail 'ReGreet is not retired explicitly'
if grep -Fxq greetd-regreet packages/native.txt; then
  fail 'ReGreet remains in the native package manifest'
fi
[[ -f $greeter_pkgbuild ]] || fail 'Enoshima greeter local package is missing'
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

printf '%s\n' '==> greetd launches only the isolated Enoshima Auth compositor'
python - "$greetd_config" <<'PY'
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
  'xwayland {' \
  'enabled = false' \
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
  '"$enoshima_greeter_command" --user "$enoshima_user"' \
  '"$hyprctl_command" dispatch '\''hl.dsp.exit()'\'''; do
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
cat >"$work/bin/enoshima-greeter" <<'SH'
#!/usr/bin/env sh
printf 'enoshima-greeter %s\n' "$*" >>"${GREETD_TEST_LOG:?}"
exit "${GREETD_TEST_GREETER_STATUS:-0}"
SH
chmod 0755 "$work/bin/hyprctl" "$work/bin/enoshima-greeter"
printf 'kentakang\n' >"$work/enoshima-user"

run_greetd_session() {
  env \
    GREETD_HYPRCTL="$work/bin/hyprctl" \
    GREETD_ENOSHIMA_GREETER="$work/bin/enoshima-greeter" \
    GREETD_ENOSHIMA_USER_FILE="$work/enoshima-user" \
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
grep -Fxq 'enoshima-greeter --user kentakang' "$work/session.log" ||
  fail 'startup did not run Enoshima Auth for the managed user'
grep -Fxq 'hyprctl dispatch hl.dsp.exit()' "$work/session.log" ||
  fail 'Enoshima Auth exit did not stop the isolated compositor'

: >"$work/session.log"
run_greetd_session '[{"name":"eDP-1"}]' lid-closed
[[ ! -s $work/session.log ]] || fail 'lid close disabled the only active output'

: >"$work/session.log"
run_greetd_session '[{"name":"DP-1"}]' lid-open
grep -Fxq 'hyprctl keyword monitor eDP-1,2880x1800@120,0x540,2' \
  "$work/session.log" || fail 'lid open did not restore the balanced eDP rule'

printf '%s\n' '==> Enoshima Auth preserves IPC, accessibility, and visual contracts'
assert_contains "$greeter_css" 'min-width: 420px;'
assert_contains "$greeter_css" 'min-height: 44px;'
assert_contains "$greeter_css" 'min-height: 48px;'
assert_contains "$greeter_css" 'outline: 2px solid @cyber_focus;'
assert_contains "$greeter_css" '@define-color cyber_canvas #050623;'
assert_contains scripts/validate.sh 'scripts/check-auth-theme'
for contract in \
  'GREETD_SOCK' \
  'create_session' \
  'post_auth_message_response' \
  'cancel_session' \
  'start_session' \
  'auth_message_type' \
  'org.freedesktop.login1.Manager' \
  'org.freedesktop.NetworkManager' \
  'gtk_drop_down_new_from_strings' \
  'gtk_window_fullscreen_on_monitor' \
  'avatar-default-symbolic' \
  'system-reboot-symbolic' \
  'G_APPLICATION_NON_UNIQUE' \
  'gtk_window_fullscreen'; do
  assert_contains "$greeter_source" "$contract"
done
assert_not_contains "$greeter_source" 'system('
assert_not_contains "$greeter_source" 'popen('
assert_not_contains "$greeter_source" 'g_bus_get_sync'
assert_not_contains "$greeter_source" 'g_dbus_connection_call_sync'
assert_contains "$greeter_source" 'g_dbus_proxy_new_for_bus'
assert_contains "$greeter_source" 'ENOSHIMA_VM_UI_TEST'
assert_contains "$greeter_source" 'valid_review_state'
assert_contains "$greeter_source" '--review-state'
assert_contains "$greeter_source" 'g-properties-changed'
assert_contains "$greeter_source" 'input:kb_variant'
assert_contains "$greeter_source" 'input:kb_options'
assert_contains "$greeter_source" 'start_session_after_success'
assert_contains "$greeter_pkgbuild" "depends=('glib2' 'greetd' 'gtk4' 'json-glib')"
read -r -a greeter_cflags <<<"$(pkg-config --cflags gtk4 json-glib-1.0 gio-unix-2.0)"
read -r -a greeter_libs <<<"$(pkg-config --libs gtk4 json-glib-1.0 gio-unix-2.0)"
cc -std=c17 -Wall -Wextra -Werror -O2 \
  "${greeter_cflags[@]}" \
  "$greeter_source" -o "$work/enoshima-greeter" \
  "${greeter_libs[@]}"
"$work/enoshima-greeter" --self-test >/dev/null
assert_contains home/dot_config/enoshima/auth-layout.yaml 'policy: serialized'
assert_contains home/dot_config/enoshima/auth-layout.yaml 'keyboard_layouts:'
assert_contains docs/concepts/auth.yaml 'PAM requests are serialized'
assert_contains home/dot_config/enoshima/i18n/en-US.json '"action.signIn": "Sign In"'
assert_contains home/dot_config/enoshima/i18n/ko-KR.json '"action.signIn": "로그인"'
assert_not_contains "$greeter_source" '한 · Korean'
assert_not_contains "$greeter_source" '◎  지문 인식기를 터치하세요'
mkdir -p "$work/status-bin"
cat >"$work/status-bin/nmcli" <<'SH'
#!/usr/bin/env sh
printf '%s\n' disconnected
SH
cat >"$work/status-bin/hyprctl" <<'SH'
#!/usr/bin/env sh
printf '%s\n' 'Hyprland IPC is unavailable'
SH
chmod 0755 "$work/status-bin/nmcli" "$work/status-bin/hyprctl"
auth_status=home/dot_local/bin/executable_enoshima-auth-status
[[ $(env LC_ALL=C PATH="$work/status-bin:/usr/bin" "$auth_status" network) == '○ Offline' ]] ||
  fail 'auth status did not render the English offline state'
[[ $(env LC_ALL=ko_KR.UTF-8 PATH="$work/status-bin:/usr/bin" "$auth_status" network) == '○ 오프라인' ]] ||
  fail 'auth status did not render the Korean offline state'
[[ $(env LC_ALL=C PATH="$work/status-bin:/usr/bin" "$auth_status" mode-unlock) == 'ENOSHIMA // UNLOCK' ]] ||
  fail 'auth status did not render the English unlock mode'
[[ $(env LC_ALL=ko_KR.UTF-8 PATH="$work/status-bin:/usr/bin" "$auth_status" mode-unlock) == 'ENOSHIMA // 잠금 해제' ]] ||
  fail 'auth status did not render the Korean unlock mode'
layout_result=$(env LC_ALL=C PATH="$work/status-bin:/usr/bin" \
  "$auth_status" layout 2>"$work/auth-status.stderr")
[[ $layout_result == EN ]] || fail 'auth status did not fail closed on invalid Hyprland JSON'
[[ ! -s $work/auth-status.stderr ]] || fail 'auth status leaked a JSON parser warning'
assert_contains "$login_tasks" 'mode: "0644"'
assert_contains "$login_tasks" 'dest: /etc/greetd/background-16x10.jpg'
assert_contains "$login_tasks" 'dest: /etc/greetd/enoshima-greeter.css'
assert_contains "$login_tasks" 'dest: /etc/greetd/enoshima-user'
assert_contains "$login_tasks" 'Remove superseded ReGreet configuration'
assert_contains scripts/postflight.sh 'greetd is the boot display manager'
assert_contains scripts/postflight.sh \
  'starts and unlocks GNOME Keyring for the session'
assert_contains scripts/postflight.sh 'fallback SDDM is disabled'
assert_contains scripts/postflight.sh 'Enoshima Auth mixed-DPI compositor configuration parses'
assert_contains scripts/postflight.sh 'Enoshima Auth lid-aware session helper is executable'

printf '%s\n' '==> UWSM session entry is valid'
grep -Eq '^\[Desktop Entry\]$' "$session_entry" || fail 'session entry header is invalid'
grep -Eq '^Type=Application$' "$session_entry" || fail 'session entry type is invalid'
assert_contains "$session_entry" 'Name=enoshima Desktop'
assert_contains "$session_entry" \
  'Exec=uwsm start -e -D Hyprland start-hyprland'
assert_not_contains "$session_entry" ' hyprland.desktop'
assert_not_contains "$session_entry" ' -N '
assert_not_contains "$session_entry" ' -C '
assert_contains "$session_entry" 'TryExec=uwsm'
assert_contains "$login_tasks" 'path: /usr/local/share/wayland-sessions/enoshima-hyprland-uwsm.desktop'
assert_contains "$login_tasks" 'state: absent'
assert_contains "$login_tasks" 'dest: "/usr/local/share/wayland-sessions/{{ item.filename }}"'
assert_contains "$login_tasks" 'filename: hyprland.desktop'
assert_contains "$login_tasks" 'filename: hyprland-uwsm.desktop'
assert_contains "$hidden_session_entry" 'Hidden=true'
assert_contains "$hidden_session_entry" 'NoDisplay=true'
assert_contains "$hidden_session_entry" 'Exec=/usr/bin/false'
assert_contains scripts/postflight.sh \
  'enoshima Desktop login session is the only visible Hyprland session'

if command -v desktop-file-validate >/dev/null 2>&1; then
  cp -- "$session_entry" "$work/enoshima-desktop.desktop"
  sed 's/{{ item.name }}/Hyprland/' "$hidden_session_entry" >"$work/hyprland.desktop"
  desktop-file-validate \
    "$work/enoshima-desktop.desktop" \
    "$work/hyprland.desktop"
fi

printf '%s\n' '==> greetd and fallback SDDM retain password-first fingerprint PAM'
for pam_template in \
  ansible/roles/system/templates/pam-greetd.j2 \
  ansible/roles/system/templates/pam-sddm.j2; do
  assert_contains "$pam_template" '{% if enoshima_capabilities.fingerprint | bool %}'
  assert_contains "$pam_template" 'pam_unix.so try_first_pass likeauth nullok'
  assert_contains "$pam_template" 'pam_fprintd.so timeout=15 max-tries=3'
  assert_contains "$pam_template" 'auth        include     system-local-login'
  assert_contains "$pam_template" 'pam_gnome_keyring.so'
done
assert_contains ansible/roles/system/tasks/authentication.yml 'dest: /etc/pam.d/greetd'
assert_not_contains ansible/roles/system/tasks/main.yml \
  'when: enoshima_capabilities.fingerprint | bool'
assert_contains ansible/roles/system/tasks/authentication.yml \
  'when: enoshima_capabilities.fingerprint | bool'

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
