#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-scaling-status
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p -- "$test_root/bin" "$test_root/proc"
cat >"$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case ${1:-} in
  clients | monitors)
    [[ ${2:-} == -j ]]
    exec /usr/bin/cat "${SCALING_TEST_ROOT:?}/$1.json"
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x -- "$test_root/bin/hyprctl"

export PATH=$test_root/bin:/usr/bin:/bin
export SCALING_TEST_ROOT=$test_root
export DESKTOP_SCALING_HYPRCTL=$test_root/bin/hyprctl
export DESKTOP_SCALING_POLICY_FILE=$repo_root/home/dot_config/enoshima/app-display-policy.json
export DESKTOP_SCALING_PROC_ROOT=$test_root/proc

cat >"$test_root/monitors.json" <<'EOF'
[
  {"id":0,"name":"eDP-1","description":"Samsung OLED","scale":1.5},
  {"id":1,"name":"DP-1","description":"Dell U2725QE","scale":1.5}
]
EOF
cat >"$test_root/clients.json" <<'EOF'
[
  {"class":"google-chrome","xwayland":false,"title":"private search","monitor":0,"pid":101},
  {"class":"notion","xwayland":false,"title":"private workspace","monitor":1,"pid":102},
  {"class":"discord","xwayland":false,"title":"private channel","monitor":0,"pid":103},
  {"class":"Slack","xwayland":false,"title":"private team","monitor":1,"pid":104},
  {"class":"thunderbird","xwayland":false,"title":"private message","monitor":0,"pid":105},
  {"class":"parsec","xwayland":true,"title":"private host","monitor":1,"pid":106}
]
EOF
for pid in {101..106}; do
  mkdir -p -- "$test_root/proc/$pid"
  printf '/usr/bin/application\0--ozone-platform=wayland\0' >"$test_root/proc/$pid/cmdline"
  printf 'LANG=en_US.UTF-8\0' >"$test_root/proc/$pid/environ"
done

output=$(bash "$helper")
[[ $output != *private* ]]
[[ $(grep -c '^PASS' <<<"$output") -eq 8 ]]

printf '%s\n' '==> native launchers leave output scaling to the compositor'
for launcher in \
  home/dot_local/bin/executable_discord-wayland \
  home/dot_local/bin/executable_slack-wayland \
  home/dot_local/bin/executable_thunderbird-wayland \
  home/dot_config/chrome-flags.conf \
  home/dot_config/notion-flags.conf \
  home/dot_config/obsidian/user-flags.conf; do
  if rg -n 'GDK_(DPI_)?SCALE|QT_(SCALE_FACTOR|FONT_DPI)|force-device-scale-factor' \
    "$repo_root/$launcher"; then
    printf 'native launcher contains a fixed global scale: %s\n' "$launcher" >&2
    exit 1
  fi
done
jq -e '
  any(.applications[]; .label == "KakaoTalk" and .scaling == "application-144-dpi-internal")
  and any(.applications[]; .label == "Parsec" and .scaling == "zero-scaled-sharp-exception")
' "$DESKTOP_SCALING_POLICY_FILE" >/dev/null

sed -i 's/"discord","xwayland":false/"discord","xwayland":true/' "$test_root/clients.json"
if bash "$helper" >"$test_root/failure.out"; then
  printf 'expected a native Wayland mismatch to fail\n' >&2
  exit 1
else
  [[ $? -eq 1 ]]
fi
[[ $(<"$test_root/failure.out") != *private* ]]

sed -i 's/"discord","xwayland":true/"discord","xwayland":false/' "$test_root/clients.json"
jq 'map(select(.class != "parsec"))' "$test_root/clients.json" >"$test_root/missing.json"
mv -- "$test_root/missing.json" "$test_root/clients.json"
if bash "$helper" >"$test_root/missing.out"; then
  printf 'expected missing required clients to defer\n' >&2
  exit 1
else
  [[ $? -eq 2 ]]
fi

jq '. + [{"class":"parsec","xwayland":true,"title":"private host","monitor":1,"pid":106}]' \
  "$test_root/clients.json" >"$test_root/restored.json"
mv -- "$test_root/restored.json" "$test_root/clients.json"
jq 'map(if .name == "eDP-1" then .scale = 2 else . end)' \
  "$test_root/monitors.json" >"$test_root/wrong-scale.json"
mv -- "$test_root/wrong-scale.json" "$test_root/monitors.json"
if bash "$helper" >"$test_root/scale.out"; then
  printf 'expected the legacy internal scale to fail\n' >&2
  exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'expected scale=1.5' "$test_root/scale.out"

jq 'map(if .name == "eDP-1" then .scale = 1.5 else . end)' \
  "$test_root/monitors.json" >"$test_root/correct-scale.json"
mv -- "$test_root/correct-scale.json" "$test_root/monitors.json"
printf 'LANG=en_US.UTF-8\0QT_SCALE_FACTOR=2\0' >"$test_root/proc/103/environ"
if bash "$helper" >"$test_root/environment.out"; then
  printf 'expected a forbidden process scale environment to fail\n' >&2
  exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'exports forbidden QT_SCALE_FACTOR' "$test_root/environment.out"
[[ $(<"$test_root/environment.out") != *'QT_SCALE_FACTOR=2'* ]]

printf 'LANG=en_US.UTF-8\0' >"$test_root/proc/103/environ"
printf '/usr/bin/discord\0--force-device-scale-factor=2\0' >"$test_root/proc/103/cmdline"
if bash "$helper" >"$test_root/argument.out"; then
  printf 'expected a forbidden process scale argument to fail\n' >&2
  exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'uses forbidden --force-device-scale-factor' "$test_root/argument.out"
[[ $(<"$test_root/argument.out") != *'--force-device-scale-factor=2'* ]]

printf 'Desktop scaling status tests passed.\n'
