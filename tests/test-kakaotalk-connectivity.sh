#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_kakaotalk-connectivity-check
setup_helper=$repo_root/home/dot_local/bin/executable_kakaotalk-setup
launcher=$repo_root/home/dot_local/bin/executable_kakaotalk
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
  if [[ $* == *'Bottles 64.1 dispatches repository callbacks'* ]]; then
    : >"${FAKE_BOTTLE_CREATED:?}"
    exit 0
  fi

  if [[ $* == *'manager.dependency_manager.install'* ||
    $* == *'manager.versioning_manager.create_state'* ||
    $* == *'config.Language = "ko_KR"'* ||
    $* == *'Using KakaoTalk-compatible runner'* ]]; then
    exit 0
  fi

  if [[ $* == *--env=RES_OPTIONS=single-request-reopen* ]]; then
    probe_state=${FAKE_RESOLVER_COMPAT_HTTPS:-${FAKE_SANDBOX_HTTPS:-ok}}
  else
    probe_state=${FAKE_SANDBOX_HTTPS:-ok}
  fi

  if [[ $probe_state == ok ]]; then
    printf 'HTTP 200\n'
    exit 0
  fi
  printf 'pycurl error 28: Connection timed out\n' >&2
  exit 1
fi

if [[ ${1:-} == run && $* == *--command=bottles-cli* ]]; then
  if [[ $* == *'--version'* ]]; then
    printf 'Bottles %s\n' "${FAKE_BOTTLES_VERSION:-64.1}"
  elif [[ $* == *'--json list bottles'* ]]; then
    if [[ ${FAKE_BOTTLE_STATE:-installed} == missing &&
      ! -e ${FAKE_BOTTLE_CREATED:-} ]]; then
      printf '{}\n'
      exit 0
    fi
    printf '%s\n' '{"KakaoTalk":{"Arch":"win64","Environment":"application","Runner":"wine-11.8-staging-amd64","Language":"ko_KR","Parameters":{"wayland":false,"dxvk":false,"vkd3d":false},"Environment_Variables":{"XMODIFIERS":"@im=fcitx"},"Installed_Dependencies":["cjkfonts","vcredist2022","riched20","msftedit"]}}'
  elif [[ $* == *'--json programs'* ]]; then
    printf '[{"name":"KakaoTalk","path":"C:\\\\KakaoTalk.exe"}]\n'
  elif [[ $* == *'reg query'* ]]; then
    printf 'InputStyle    REG_SZ    root\n'
  elif [[ $* == *' new '* ]]; then
    : >"${FAKE_BOTTLE_CREATED:?}"
  fi
fi
EOF

cat >"$fake_bin/xdg-user-dir" <<'EOF'
#!/usr/bin/env bash
printf '%s/Downloads\n' "${HOME:?}"
EOF

cat >"$fake_bin/setxkbmap" <<'EOF'
#!/usr/bin/env bash
printf 'setxkbmap %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
EOF

chmod +x \
  "$fake_bin/getent" \
  "$fake_bin/curl" \
  "$fake_bin/flatpak" \
  "$fake_bin/setxkbmap" \
  "$fake_bin/xdg-user-dir"

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
assert_contains "$success_output" 'Bottles exact online check reaches the endpoint (HTTP 200)'
assert_contains "$success_output" 'Bottles connectivity preflight passed.'

sandbox_failure_output=$test_root/sandbox-failure.out
if run_probe "$sandbox_failure_output" env FAKE_SANDBOX_HTTPS=fail; then
  printf 'Sandbox HTTPS failure unexpectedly passed.\n' >&2
  exit 1
fi
assert_contains "$sandbox_failure_output" "Bottles' exact pycurl HTTPS path fails"
assert_contains "$sandbox_failure_output" "Rerun \`kakaotalk-connectivity-check\`"

resolver_compat_output=$test_root/resolver-compat.out
if run_probe "$resolver_compat_output" env \
  FAKE_SANDBOX_HTTPS=fail FAKE_RESOLVER_COMPAT_HTTPS=ok; then
  printf 'Resolver compatibility diagnosis unexpectedly passed.\n' >&2
  exit 1
fi
assert_contains "$resolver_compat_output" \
  'Bottles succeeds with its app-scoped resolver compatibility option'
assert_contains "$resolver_compat_output" \
  "\`kakaotalk-setup\` to apply the app-scoped resolver compatibility option."

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

cat >"$fake_bin/kakaotalk-profile" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'profile %s\n' "$*" >>"${FAKE_CALL_LOG:?}"
case ${1:-} in
  current)
    cat "${FAKE_PROFILE_JSON:?}"
    ;;
  install | verify)
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/kakaotalk-connectivity-check" "$fake_bin/kakaotalk-profile"

profile_json=$test_root/profile.json
cp -- "$repo_root/home/dot_config/enoshima/kakaotalk/profiles/wine-11.8-staging-candidate.json" \
  "$profile_json"

setup_output=$test_root/setup.out
connectivity_count=$test_root/connectivity-count
printf -v setup_command \
  'env PATH=%q HOME=%q WAYLAND_DISPLAY=%q FAKE_CALL_LOG=%q FAKE_CONNECTIVITY_COUNT=%q FAKE_PROFILE_JSON=%q bash %q' \
  "$fake_bin:/usr/bin" \
  "$test_root/home" \
  wayland-test \
  "$test_root/setup-calls.log" \
  "$connectivity_count" \
  "$profile_json" \
  "$setup_helper"
printf 'y\nr\n' | script --quiet --return --command "$setup_command" /dev/null \
  >"$setup_output" 2>&1

[[ $(<"$connectivity_count") == 2 ]] || {
  printf 'Setup did not retry connectivity exactly once.\n' >&2
  exit 1
}
second_probe_line=$(grep -n '^connectivity 2$' "$test_root/setup-calls.log" | cut -d: -f1)
first_bottles_call_line=$(grep -n -- '--command=bottles-cli' "$test_root/setup-calls.log" | head -n1 | cut -d: -f1)
profile_install_line=$(grep -n '^profile install ' "$test_root/setup-calls.log" | cut -d: -f1)
[[ -n $second_probe_line && -n $first_bottles_call_line &&
  -n $profile_install_line &&
  $second_probe_line -lt $profile_install_line &&
  $profile_install_line -lt $first_bottles_call_line ]] || {
  printf 'Bottles state was accessed before connectivity passed.\n' >&2
  sed -n '1,240p' "$test_root/setup-calls.log" >&2
  exit 1
}
assert_contains "$setup_output" 'No bottle has been created or changed.'
assert_contains "$setup_output" 'KakaoTalk setup is complete.'
assert_contains "$test_root/setup-calls.log" \
  'override --user --env=XMODIFIERS=@im=fcitx --env=RES_OPTIONS=single-request-reopen'
assert_contains "$setup_output" \
  'Configuring the KakaoTalk bottle for Korean text and locale.'
assert_contains "$setup_output" \
  'Configuring the KakaoTalk Wine runner and graphics compatibility.'
assert_contains "$test_root/setup-calls.log" \
  'profile install wine-11.8-staging-candidate'
assert_contains "$test_root/setup-calls.log" \
  'the pinned runner is unavailable'
assert_contains "$test_root/setup-calls.log" 'component=component,'
assert_contains "$test_root/setup-calls.log" 'remove=True,'
assert_contains "$test_root/setup-calls.log" 'key="Runner", value=runner'
assert_contains "$test_root/setup-calls.log" 'config.Language = "ko_KR"'
assert_contains "$test_root/setup-calls.log" 'Pretendard-Regular.ttf'
assert_contains "$test_root/setup-calls.log" '00000412'
assert_contains "$test_root/setup-calls.log" '"ACP", "949"'
assert_contains "$test_root/setup-calls.log" '"Graphics", "x11"'
assert_contains "$test_root/setup-calls.log" 'AppDefaults\kakaotalk.exe\X11 Driver'
assert_contains "$test_root/setup-calls.log" '"InputStyle", "root"'
assert_contains "$test_root/setup-calls.log" \
  'manager.dependency_manager.install(config, [dependency, manifest])'

new_setup_output=$test_root/new-setup.out
new_connectivity_count=$test_root/new-connectivity-count
bottle_created=$test_root/bottle-created
printf '1\n' >"$new_connectivity_count"
printf -v new_setup_command \
  'env PATH=%q HOME=%q WAYLAND_DISPLAY=%q FAKE_CALL_LOG=%q FAKE_CONNECTIVITY_COUNT=%q FAKE_BOTTLE_STATE=missing FAKE_BOTTLE_CREATED=%q FAKE_PROFILE_JSON=%q bash %q' \
  "$fake_bin:/usr/bin" \
  "$test_root/new-home" \
  wayland-test \
  "$test_root/new-setup-calls.log" \
  "$new_connectivity_count" \
  "$bottle_created" \
  "$profile_json" \
  "$setup_helper"
printf 'y\n' | script --quiet --return --command "$new_setup_command" /dev/null \
  >"$new_setup_output" 2>&1

[[ -e $bottle_created ]] || {
  printf 'Bottles 64.1 compatibility creator was not invoked.\n' >&2
  sed -n '1,240p' "$new_setup_output" >&2
  exit 1
}
assert_contains "$new_setup_output" 'Creating the dedicated KakaoTalk bottle.'
assert_contains "$test_root/new-setup-calls.log" \
  'the checksum-pinned runner is unavailable'
assert_contains "$test_root/new-setup-calls.log" 'runner=runner,'
assert_contains "$new_setup_output" \
  'Configuring the KakaoTalk bottle for Korean text and locale.'
assert_contains "$new_setup_output" 'KakaoTalk setup is complete.'
if grep -Fq -- '--environment application --arch win64' \
  "$test_root/new-setup-calls.log"; then
  printf 'Setup used the broken Bottles 64.1 new command.\n' >&2
  exit 1
fi

future_setup_output=$test_root/future-setup.out
future_connectivity_count=$test_root/future-connectivity-count
future_bottle_created=$test_root/future-bottle-created
printf '1\n' >"$future_connectivity_count"
printf -v future_setup_command \
  'env PATH=%q HOME=%q WAYLAND_DISPLAY=%q FAKE_CALL_LOG=%q FAKE_CONNECTIVITY_COUNT=%q FAKE_BOTTLE_STATE=missing FAKE_BOTTLE_CREATED=%q FAKE_BOTTLES_VERSION=64.2 FAKE_PROFILE_JSON=%q bash %q' \
  "$fake_bin:/usr/bin" \
  "$test_root/future-home" \
  wayland-test \
  "$test_root/future-setup-calls.log" \
  "$future_connectivity_count" \
  "$future_bottle_created" \
  "$profile_json" \
  "$setup_helper"
printf 'y\n' | script --quiet --return --command "$future_setup_command" /dev/null \
  >"$future_setup_output" 2>&1

[[ -e $future_bottle_created ]] || {
  printf 'Future Bottles CLI creator was not invoked.\n' >&2
  sed -n '1,240p' "$future_setup_output" >&2
  exit 1
}
assert_contains "$test_root/future-setup-calls.log" \
  '--bottle-name KakaoTalk --environment application --arch win64'
assert_contains "$future_setup_output" 'KakaoTalk setup is complete.'

launcher_call_log=$test_root/launcher-calls.log
env \
  PATH="$fake_bin:/usr/bin" \
  DISPLAY=:99 \
  FAKE_CALL_LOG="$launcher_call_log" \
  FAKE_PROFILE_JSON="$profile_json" \
  bash "$launcher"

assert_contains "$launcher_call_log" 'setxkbmap -option korean:ralt_hangul'
keymap_line=$(grep -n '^setxkbmap ' "$launcher_call_log" | cut -d: -f1)
launch_line=$(grep -n -- 'run -b KakaoTalk -p KakaoTalk' "$launcher_call_log" | tail -n1 | cut -d: -f1)
[[ -n $keymap_line && -n $launch_line && $keymap_line -lt $launch_line ]] || {
  printf 'XWayland keymap was not synchronized before KakaoTalk launched.\n' >&2
  sed -n '1,160p' "$launcher_call_log" >&2
  exit 1
}

printf 'KakaoTalk connectivity tests passed.\n'
