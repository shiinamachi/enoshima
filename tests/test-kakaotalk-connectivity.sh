#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_kakaotalk-connectivity-check
setup_helper=$repo_root/home/dot_local/bin/executable_kakaotalk-setup
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fake_bin=$test_root/bin
mkdir -- "$fake_bin"

cat >"$fake_bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ ${FAKE_HOST_DNS:-ok} == ok ]]
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ ${FAKE_HOST_HTTPS:-ok} == ok ]]
EOF

cat >"$fake_bin/flatpak" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'flatpak %s\n' "$*" >>"${FAKE_CALL_LOG:?}"

if [[ ${1:-} == info ]]; then
  [[ ${FAKE_APP_STATE:-installed} == installed ]]
  exit
fi

if [[ ${1:-} == run && $* == *--command=getent* ]]; then
  [[ ${FAKE_SANDBOX_DNS:-ok} == ok ]]
  exit
fi

if [[ ${1:-} == run && $* == *--command=python3* ]]; then
  if [[ ${FAKE_SANDBOX_HTTPS:-ok} == ok ]]; then
    printf 'HTTP 200\n'
    exit 0
  fi
  printf 'pycurl error 28: Connection timed out\n' >&2
  exit 1
fi

if [[ ${1:-} == run && $* == *--command=bottles-cli* ]]; then
  if [[ $* == *'--json list bottles'* ]]; then
    printf '{"KakaoTalk":{"Arch":"win64","Environment":"application"}}\n'
  elif [[ $* == *'--json programs'* ]]; then
    printf '[{"name":"KakaoTalk","path":"C:\\\\KakaoTalk.exe"}]\n'
  fi
fi
EOF

cat >"$fake_bin/xdg-user-dir" <<'EOF'
#!/usr/bin/env bash
printf '%s/Downloads\n' "${HOME:?}"
EOF

chmod +x "$fake_bin/getent" "$fake_bin/curl" "$fake_bin/flatpak" "$fake_bin/xdg-user-dir"

run_probe() {
  local output_file=$1
  shift
  env \
    PATH="$fake_bin:/usr/bin" \
    FAKE_CALL_LOG="$test_root/calls.log" \
    "$@" \
    bash "$helper" >"$output_file" 2>&1
}

assert_contains() {
  local path=$1
  local pattern=$2
  grep -Fq -- "$pattern" "$path" || {
    printf 'Expected %s to contain: %s\n' "$path" "$pattern" >&2
    sed -n '1,240p' "$path" >&2
    exit 1
  }
}

success_output=$test_root/success.out
run_probe "$success_output" env
assert_contains "$success_output" 'Bottles sandbox pycurl reaches the endpoint (HTTP 200)'
assert_contains "$success_output" 'Bottles connectivity preflight passed.'

sandbox_failure_output=$test_root/sandbox-failure.out
if run_probe "$sandbox_failure_output" env FAKE_SANDBOX_HTTPS=fail; then
  printf 'Sandbox HTTPS failure unexpectedly passed.\n' >&2
  exit 1
fi
assert_contains "$sandbox_failure_output" "Bottles' own pycurl HTTPS path fails"
assert_contains "$sandbox_failure_output" "Rerun \`kakaotalk-connectivity-check\`"

dns_failure_output=$test_root/dns-failure.out
if run_probe "$dns_failure_output" env FAKE_HOST_DNS=fail FAKE_SANDBOX_DNS=fail; then
  printf 'DNS failure unexpectedly passed.\n' >&2
  exit 1
fi
assert_contains "$dns_failure_output" 'the host DNS path is failing'

missing_output=$test_root/missing.out
set +e
run_probe "$missing_output" env FAKE_APP_STATE=missing
missing_status=$?
set -e
[[ $missing_status -eq 2 ]] || {
  printf 'Missing Bottles returned %d instead of 2.\n' "$missing_status" >&2
  exit 1
}
assert_contains "$missing_output" 'user-scoped Bottles Flatpak is not installed'

cat >"$fake_bin/kakaotalk-connectivity-check" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file=${FAKE_CONNECTIVITY_COUNT:?}
count=0
[[ ! -f $count_file ]] || read -r count <"$count_file"
count=$((count + 1))
printf '%d\n' "$count" >"$count_file"
printf 'connectivity %d\n' "$count" >>"${FAKE_CALL_LOG:?}"
((count >= 2))
EOF
chmod +x "$fake_bin/kakaotalk-connectivity-check"

setup_output=$test_root/setup.out
connectivity_count=$test_root/connectivity-count
printf -v setup_command \
  'env PATH=%q HOME=%q WAYLAND_DISPLAY=%q FAKE_CALL_LOG=%q FAKE_CONNECTIVITY_COUNT=%q bash %q' \
  "$fake_bin:/usr/bin" \
  "$test_root/home" \
  wayland-test \
  "$test_root/setup-calls.log" \
  "$connectivity_count" \
  "$setup_helper"
printf 'y\nr\n' | script --quiet --return --command "$setup_command" /dev/null \
  >"$setup_output" 2>&1

[[ $(<"$connectivity_count") == 2 ]] || {
  printf 'Setup did not retry connectivity exactly once.\n' >&2
  exit 1
}
second_probe_line=$(grep -n '^connectivity 2$' "$test_root/setup-calls.log" | cut -d: -f1)
first_bottles_call_line=$(grep -n -- '--command=bottles-cli' "$test_root/setup-calls.log" | head -n1 | cut -d: -f1)
[[ -n $second_probe_line && -n $first_bottles_call_line &&
  $second_probe_line -lt $first_bottles_call_line ]] || {
  printf 'Bottles state was accessed before connectivity passed.\n' >&2
  sed -n '1,240p' "$test_root/setup-calls.log" >&2
  exit 1
}
assert_contains "$setup_output" 'No bottle has been created or changed.'
assert_contains "$setup_output" 'KakaoTalk setup is complete.'

printf 'KakaoTalk connectivity tests passed.\n'
