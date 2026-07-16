#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repair=$repo_root/home/dot_local/bin/executable_kakaotalk-focus-repair
guard=$repo_root/home/dot_local/bin/executable_kakaotalk-focus-guard
guard_service=$repo_root/home/dot_config/systemd/user/kakaotalk-focus-guard.service
tray_service=$repo_root/home/dot_config/systemd/user/xembed-sni-proxy.service
doctor=$repo_root/home/dot_local/bin/executable_kakaotalk-doctor
hyprland=$repo_root/home/dot_config/hypr/hyprland.lua
shell_qml=$repo_root/home/dot_config/quickshell/cyberdock/shell.qml
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fake_bin=$work/bin
proc_root=$work/proc
mkdir -p -- "$fake_bin" "$proc_root/102" "$proc_root/103"
printf 'WINEPREFIX=/home/test/.var/app/com.usebottles.bottles/data/bottles/bottles/KakaoTalk\0' \
  >"$proc_root/102/environ"
printf 'WINEPREFIX=/home/test/.var/app/com.usebottles.bottles/data/bottles/bottles/KakaoTalk\0' \
  >"$proc_root/103/environ"

cat >"$fake_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  clients)
    [[ ${2:-} == -j ]]
    cat <<'JSON'
[
  {"address":"0xaaa","class":"kakaotalk.exe","title":"카카오톡","pid":101,"mapped":true,"hidden":false,"xwayland":true,"size":[439,1032],"workspace":{"id":3,"name":"3"},"monitor":0},
  {"address":"0xbbb","class":"explorer.exe","title":"","pid":102,"mapped":true,"hidden":false,"xwayland":true,"size":[16,16],"workspace":{"id":3,"name":"3"},"monitor":0},
  {"address":"0xccc","class":"explorer.exe","title":"","pid":103,"mapped":true,"hidden":false,"xwayland":true,"size":[420,180],"workspace":{"id":3,"name":"3"},"monitor":0},
  {"address":"0xddd","class":"org.gnome.TextEditor","title":"Editor","pid":104,"mapped":true,"hidden":false,"xwayland":false,"size":[900,700],"workspace":{"id":1,"name":"1"},"monitor":0}
]
JSON
    ;;
  activewindow)
    [[ ${2:-} == -j ]]
    address=$(cat "${FAKE_ACTIVE:?}")
    printf '{"address":"%s"}\n' "$address"
    ;;
  dispatch)
    printf 'hyprctl %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
    if [[ ${2:-} == focuswindow && ${3:-} == address:* ]]; then
      printf '%s\n' "${3#address:}" >"${FAKE_ACTIVE:?}"
    fi
    ;;
  *) exit 64 ;;
esac
EOF

cat >"$fake_bin/qs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'qs %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
printf '%s\n' "${*: -1}" >"${FAKE_ACTIVE:?}"
EOF

cat >"$fake_bin/desktop-window-action" <<'EOF'
#!/usr/bin/env bash
printf 'window-action %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
EOF

cat >"$fake_bin/kakaotalk-focus-repair" <<'EOF'
#!/usr/bin/env bash
printf 'repair %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
EOF

cat >"$fake_bin/kakaotalk-profile" <<'EOF'
#!/usr/bin/env bash
case ${1:-} in
  current) printf '{"id":"test","runner":{"name":"wine-test"}}\n' ;;
  verify) ;;
  *) exit 2 ;;
esac
EOF

cat >"$fake_bin/flatpak" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == *'--show-commit'* ]]; then
  printf 'test-commit\n'
elif [[ $* == *'--version'* ]]; then
  printf 'Bottles test\n'
elif [[ $* == *'--json list bottles'* ]]; then
  printf '{"KakaoTalk":{"Runner":"wine-test","Installed_Dependencies":["test-dependency"]}}\n'
elif [[ $* == *'reg query'* ]]; then
  printf 'InputStyle    REG_SZ    root\n'
fi
EOF

cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ $* == *'is-active'* ]]
EOF

cat >"$fake_bin/fcitx5-remote" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_bin"/*

export PATH="$fake_bin:/usr/bin"
export FAKE_ACTIVE=$work/active
export FAKE_CALL_LOG=$work/calls.log
printf '0xddd\n' >"$FAKE_ACTIVE"

env \
  KAKAOTALK_FOCUS_HYPRCTL="$fake_bin/hyprctl" \
  KAKAOTALK_FOCUS_QS="$fake_bin/qs" \
  KAKAOTALK_FOCUS_WINDOW_ACTION="$fake_bin/desktop-window-action" \
  bash "$repair" --address 0xaaa >/dev/null
[[ $(<"$FAKE_ACTIVE") == 0xaaa ]]
grep -Fq -- 'window-action restore --address 0xaaa' "$FAKE_CALL_LOG"
grep -Fq -- 'ipc call -- kakaofocus pulse 0xaaa' "$FAKE_CALL_LOG"

printf '0xddd\n' >"$FAKE_ACTIVE"
env \
  KAKAOTALK_FOCUS_HYPRCTL="$fake_bin/hyprctl" \
  KAKAOTALK_FOCUS_QS="$work/unavailable-qs" \
  KAKAOTALK_FOCUS_WINDOW_ACTION="$fake_bin/desktop-window-action" \
  bash "$repair" >/dev/null
[[ $(<"$FAKE_ACTIVE") == 0xaaa ]]
grep -Fq -- 'dispatch focuswindow address:0xaaa' "$FAKE_CALL_LOG"

if env KAKAOTALK_FOCUS_HYPRCTL="$fake_bin/hyprctl" \
  bash "$repair" --address 0xccc >/dev/null 2>&1; then
  printf 'A non-KakaoTalk address was accepted by focus repair.\n' >&2
  exit 1
fi

: >"$FAKE_CALL_LOG"
printf '%s\n' \
  'activewindowv2>>0xaaa' \
  'activewindowv2>>0xaaa' \
  'openwindow>>0xbbb,3,explorer.exe,' \
  'openwindow>>0xccc,3,explorer.exe,' |
  env \
    KAKAOTALK_GUARD_HYPRCTL="$fake_bin/hyprctl" \
    KAKAOTALK_GUARD_REPAIR="$fake_bin/kakaotalk-focus-repair" \
    KAKAOTALK_GUARD_RATE_LIMIT_MS=60000 \
    KAKAOTALK_GUARD_PROC_ROOT="$proc_root" \
    bash "$guard" --stdin
[[ $(grep -c '^repair --address 0xaaa$' "$FAKE_CALL_LOG") -eq 1 ]]
grep -Fq -- \
  'dispatch movetoworkspacesilent special:tray,address:0xbbb' "$FAKE_CALL_LOG"
if grep -Fq -- 'special:tray,address:0xccc' "$FAKE_CALL_LOG"; then
  printf 'A real-size explorer surface was hidden as a tray helper.\n' >&2
  exit 1
fi

doctor_json=$(env \
  KAKAOTALK_DOCTOR_FLATPAK="$fake_bin/flatpak" \
  KAKAOTALK_DOCTOR_HYPRCTL="$fake_bin/hyprctl" \
  KAKAOTALK_DOCTOR_SYSTEMCTL="$fake_bin/systemctl" \
  KAKAOTALK_DOCTOR_PROFILE="$fake_bin/kakaotalk-profile" \
  bash "$doctor" --json)
jq -e '
  .healthy and .profile_verified and .input_style_root and
  .dependencies_verified and
  .tray_proxy_active and .focus_guard_active and
  (.windows | length) == 1 and .windows[0].address == "0xaaa"
' <<<"$doctor_json" >/dev/null

grep -Fq 'mainMod .. " + CTRL + K"' "$hyprland"
grep -Fq 'name = "route-kakaotalk-main"' "$hyprland"
grep -Fq 'title = "^카카오톡$"' "$hyprland"
if grep -Fq 'name = "hide-wine-shell-surface"' "$hyprland"; then
  printf 'The broad Wine explorer tray rule is still configured.\n' >&2
  exit 1
fi
grep -Fq 'target: "kakaofocus"' "$shell_qml"
grep -Fq '"label": "입력 포커스 복구"' "$shell_qml"
# shellcheck disable=SC2016 # Match the literal command in the managed helper.
grep -Fq '"$socat_bin" -u "UNIX-CONNECT:$socket" STDOUT' "$guard"
grep -Fxq 'Restart=always' "$guard_service"
grep -Fxq 'BindsTo=waybar.service' "$tray_service"

printf 'KakaoTalk desktop integration tests passed.\n'
