#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-scaling-status
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p -- "$test_root/bin"
cat >"$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == clients && ${2-} == -j ]]
exec /usr/bin/cat "$CLIENTS_JSON"
EOF
chmod +x -- "$test_root/bin/hyprctl"

export PATH=$test_root/bin:/usr/bin:/bin
export CLIENTS_JSON=$test_root/clients.json

cat >"$CLIENTS_JSON" <<'EOF'
[
  {"class":"discord","xwayland":false,"title":"private channel"},
  {"class":"Slack","xwayland":false,"title":"private workspace"},
  {"class":"thunderbird","xwayland":false,"title":"private message"},
  {"class":"parsec","xwayland":true,"title":"private host"}
]
EOF
output=$(bash "$helper")
[[ $output != *private* ]]
[[ $(grep -c '^PASS' <<<"$output") -eq 4 ]]

sed -i 's/"discord","xwayland":false/"discord","xwayland":true/' "$CLIENTS_JSON"
if bash "$helper" >"$test_root/failure.out"; then
  printf 'expected a native Wayland mismatch to fail\n' >&2
  exit 1
else
  [[ $? -eq 1 ]]
fi
[[ $(<"$test_root/failure.out") != *private* ]]

sed -i 's/"discord","xwayland":true/"discord","xwayland":false/' "$CLIENTS_JSON"
jq 'map(select(.class != "parsec"))' "$CLIENTS_JSON" >"$test_root/missing.json"
mv -- "$test_root/missing.json" "$CLIENTS_JSON"
if bash "$helper" >"$test_root/missing.out"; then
  printf 'expected missing clients to defer\n' >&2
  exit 1
else
  [[ $? -eq 2 ]]
fi

printf 'Desktop scaling status tests passed.\n'
