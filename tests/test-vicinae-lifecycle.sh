#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
guard_source=$repo_root/packages/local/vicinae-bin/vicinae-qt-guard
compatibility_source=$repo_root/packages/local/vicinae-bin/vicinae-build-compatible
provenance_checker=$repo_root/scripts/check-vicinae-provenance
fixture_root=$(mktemp -d)
direct_pid=

cleanup() {
  [[ -z $direct_pid ]] || {
    kill "$direct_pid" 2>/dev/null || true
    wait "$direct_pid" 2>/dev/null || true
  }
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

fail() {
  echo "Vicinae Qt guard test failed: $*" >&2
  exit 1
}

# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq 'runtime_mask=$user_unit_runtime/vicinae.service' "$guard_source" ||
  fail 'the guard does not use systemd native global runtime masking'
grep -Fq 'mask_ownership_record=native-runtime-mask-owned-v1' "$guard_source" ||
  fail 'the guard cannot distinguish its mask from an administrator mask'
grep -Fq 'release-if-compatible' "$guard_source" ||
  fail 'the stable release CLI is missing'
grep -Fq 'hold)' "$guard_source" || fail 'the stable hold CLI is missing'
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq 'manager_systemctl "$user" 20 stop vicinae.service' "$guard_source" ||
  fail 'managed stop is not bounded'
grep -Fq 'no_direct_vicinae_processes' "$guard_source" ||
  fail 'direct Vicinae processes are not checked'
legacy_state_pattern='/var/lib/enoshima/vicinae|resume-users|initial-install-intent|enable-after-policy|vicinae-qt-lifecycle|vicinae-qt-transition|10-enoshima-qt-transition|ConditionPathExists'
if grep -Eq "$legacy_state_pattern" \
  "$guard_source" \
  "$compatibility_source" \
  "$repo_root/bootstrap.sh" \
  "$repo_root/scripts/install-local-packages.sh" \
  "$repo_root/scripts/postflight.sh" \
  "$repo_root/packages/local/vicinae-bin/40-vicinae-qt-pre.hook" \
  "$repo_root/packages/local/vicinae-bin/40-vicinae-qt-post.hook" \
  "$repo_root/packages/local/vicinae-bin/41-vicinae-package-pre.hook" \
  "$repo_root/packages/local/vicinae-bin/vicinae.hook"; then
  fail 'legacy persistent lifecycle state remains in a managed execution path'
fi
for legacy_fragment in \
  /var/lib/enoshima/vicinae \
  resume-users \
  initial-install-intent \
  enable-after-policy; do
  grep -Fq "\"$legacy_fragment\"" "$provenance_checker" ||
    fail "the provenance checker no longer rejects legacy state: $legacy_fragment"
done
if grep -Eq '[[:space:]](start|enable)[[:space:]]+vicinae\.service' "$guard_source"; then
  fail 'the root guard can start or enable the user service'
fi
grep -Fq '(($# == 0)) || exit 255' "$compatibility_source" ||
  fail 'the compatibility helper is not a pure zero-argument check'

create_fakes() {
  local root=$1
  mkdir -p "$root/fakes"
  cat >"$root/fakes/loginctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == list-users ]] || exit 64
[[ ! -e $GUARD_TEST_ROOT/loginctl-fails ]] || exit 1
[[ ! -f $GUARD_TEST_ROOT/users ]] || cat "$GUARD_TEST_ROOT/users"
SH
  cat >"$root/fakes/id" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1:$2:${3-}" in
  -nu:--:1001) echo alice ;;
  -nu:--:1002) echo bob ;;
  -u:--:alice) echo 1001 ;;
  -u:--:bob) echo 1002 ;;
  *) exit 1 ;;
esac
SH
  cat >"$root/fakes/getent" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1-} == passwd ]] || exit 1
case ${2-} in
  1001) echo 'alice:x:1001:1001::/home/alice:/bin/bash' ;;
  1002) echo 'bob:x:1002:1002::/home/bob:/bin/bash' ;;
  *) exit 1 ;;
esac
SH
  cat >"$root/fakes/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
user=
for argument in "$@"; do
  [[ $argument != --machine=* ]] || user=${argument#--machine=}
done
user=${user%@.host}
case " $* " in
  *' --global --runtime mask vicinae.service '*)
    printf 'mask\n' >>"$GUARD_TEST_ROOT/events"
    ln -s -- /dev/null "$GUARD_TEST_ROOT/run/systemd/user/vicinae.service"
    ;;
  *' --global --runtime unmask vicinae.service '*)
    printf 'unmask\n' >>"$GUARD_TEST_ROOT/events"
    rm -f -- "$GUARD_TEST_ROOT/run/systemd/user/vicinae.service"
    ;;
  *' show-environment '*)
    [[ ! -f $GUARD_TEST_ROOT/fail-reload || $(<"$GUARD_TEST_ROOT/fail-reload") != "$user" ]]
    ;;
  *' daemon-reload '*)
    printf 'reload:%s\n' "$user" >>"$GUARD_TEST_ROOT/events"
    [[ ! -f $GUARD_TEST_ROOT/fail-reload || $(<"$GUARD_TEST_ROOT/fail-reload") != "$user" ]]
    ;;
  *' stop vicinae.service '*)
    printf 'stop:%s\n' "$user" >>"$GUARD_TEST_ROOT/events"
    [[ ! -f $GUARD_TEST_ROOT/fail-stop || $(<"$GUARD_TEST_ROOT/fail-stop") != "$user" ]] || exit 1
    : >"$GUARD_TEST_ROOT/stopped-$user"
    ;;
  *' show vicinae.service '*)
    if [[ -e $GUARD_TEST_ROOT/shadow-$user ]]; then
      load_state=loaded
    elif [[ -L $GUARD_TEST_ROOT/run/systemd/user/vicinae.service ]]; then
      load_state=masked
    else
      load_state=loaded
    fi
    if [[ -e $GUARD_TEST_ROOT/stopped-$user ]]; then
      active_state=inactive
    else
      active_state=active
    fi
    printf 'LoadState=%s\nActiveState=%s\n' "$load_state" "$active_state"
    ;;
  *) exit 64 ;;
esac
SH
  cat >"$root/compatibility" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit "$(<"$GUARD_TEST_ROOT/compat-status")"
SH
  chmod 0755 "$root/fakes/"* "$root/compatibility"
}

new_case() {
  local name=$1 root uid gid

  root=$fixture_root/$name
  uid=$(id -u)
  gid=$(id -g)
  mkdir -p "$root/run/systemd"
  chmod 0755 "$root/run" "$root/run/systemd"
  : >"$root/users"
  : >"$root/events"
  printf '0\n' >"$root/compat-status"
  create_fakes "$root"
  sed \
    -e "s|^filesystem_root=.*|filesystem_root=$root|" \
    -e "s|^run_root=.*|run_root=$root/run|" \
    -e "s|^compatibility_helper=.*|compatibility_helper=$root/compatibility|" \
    -e "s|^systemctl_command=.*|systemctl_command=$root/fakes/systemctl|" \
    -e "s|^loginctl_command=.*|loginctl_command=$root/fakes/loginctl|" \
    -e "s|^id_command=.*|id_command=$root/fakes/id|" \
    -e "s|^getent_command=.*|getent_command=$root/fakes/getent|" \
    -e "s|^vicinae_executable=.*|vicinae_executable=$root/direct-vicinae|" \
    -e "s|^vicinae_server_executable=.*|vicinae_server_executable=$root/direct-server|" \
    -e "s|^legacy_vicinae_root=.*|legacy_vicinae_root=$root/legacy-vicinae|" \
    -e "s|^temporary_root=.*|temporary_root=$root/tmp|" \
    -e "s|^root_uid=0$|root_uid=$uid|" \
    -e "s|^root_gid=0$|root_gid=$gid|" \
    "$guard_source" >"$root/guard"
  chmod 0755 "$root/guard"
  printf '%s\n' "$root"
}

run_guard() {
  local root=$1
  shift
  GUARD_TEST_ROOT=$root "$root/guard" "$@"
}

success_root=$(new_case success)
printf '1001 alice yes active\n1002 bob no online\n' >"$success_root/users"
run_guard "$success_root" hold || fail 'a valid hold failed'
mask=$success_root/run/systemd/user/vicinae.service
lock=$success_root/run/enoshima/vicinae-qt-guard.lock
[[ -L $mask && $(readlink -- "$mask") == /dev/null ]] ||
  fail 'hold did not publish the native global runtime mask'
[[ -f $lock && ! -L $lock && $(stat -c '%a' "$lock") == 600 ]] ||
  fail 'the guard lock and ownership record are unsafe'
grep -Eq '^native-runtime-mask-owned-v1 [0-9]+:[0-9]+$' "$lock" ||
  fail 'the guard did not record ownership of the mask it created'
mask_line=$(grep -n '^mask$' "$success_root/events" | head -n1 | cut -d: -f1)
reload_line=$(grep -n '^reload:alice$' "$success_root/events" | head -n1 | cut -d: -f1)
stop_line=$(grep -n '^stop:alice$' "$success_root/events" | head -n1 | cut -d: -f1)
[[ -n $mask_line && -n $reload_line && -n $stop_line &&
  $mask_line -lt $reload_line && $reload_line -lt $stop_line ]] ||
  fail 'hold did not load the native mask before stopping the service'
run_guard "$success_root" hold || fail 'an idempotent repeated hold failed'

: >"$success_root/events"
printf '1\n' >"$success_root/compat-status"
run_guard "$success_root" release-if-compatible ||
  fail 'ordinary ABI mismatch should retain a successful hold without failing post-transaction'
[[ -L $mask ]] || fail 'ABI mismatch released the hold'
if grep -Eq '^(start|enable):' "$success_root/events"; then
  fail 'incompatible release started or enabled Vicinae'
fi

: >"$success_root/events"
printf '0\n' >"$success_root/compat-status"
run_guard "$success_root" release-if-compatible || fail 'compatible release failed'
[[ ! -e $mask && ! -L $mask && ! -s $lock ]] ||
  fail 'compatible release retained runtime state'
grep -q '^reload:' "$success_root/events" ||
  fail 'compatible release did not reload reachable managers'
if grep -Eq '^(start|enable):' "$success_root/events"; then
  fail 'compatible release started or enabled Vicinae'
fi

stop_failure_root=$(new_case stop-failure)
printf '1001 alice yes active\n' >"$stop_failure_root/users"
printf 'alice\n' >"$stop_failure_root/fail-stop"
if run_guard "$stop_failure_root" hold >/dev/null 2>&1; then
  fail 'a failed managed stop was accepted'
fi
[[ -L $stop_failure_root/run/systemd/user/vicinae.service ]] ||
  fail 'a failed stop did not remain fail-closed'

reload_failure_root=$(new_case reload-failure)
printf '1001 alice yes active\n' >"$reload_failure_root/users"
printf 'alice\n' >"$reload_failure_root/fail-reload"
if run_guard "$reload_failure_root" hold >/dev/null 2>&1; then
  fail 'a failed manager reload was accepted'
fi
[[ -L $reload_failure_root/run/systemd/user/vicinae.service ]] ||
  fail 'a failed reload removed the native mask'
grep -Fxq 'stop:alice' "$reload_failure_root/events" ||
  fail 'a reload failure prevented the remaining safety pass'

invalid_user_root=$(new_case invalid-user)
printf '1001 --evil yes active\n' >"$invalid_user_root/users"
if run_guard "$invalid_user_root" hold >/dev/null 2>&1; then
  fail 'an argument-injecting username was accepted'
fi
[[ $(<"$invalid_user_root/events") == mask ]] ||
  fail 'an invalid username reached a user manager command'
[[ -L $invalid_user_root/run/systemd/user/vicinae.service ]] ||
  fail 'invalid manager metadata did not leave the native mask held'

symlink_root=$(new_case symlink-ancestor)
mkdir "$symlink_root/redirect"
ln -s "$symlink_root/redirect" "$symlink_root/run/enoshima"
if run_guard "$symlink_root" hold >/dev/null 2>&1; then
  fail 'a symlinked /run ancestor was accepted'
fi
[[ -z $(find "$symlink_root/redirect" -mindepth 1 -print -quit) ]] ||
  fail 'the guard wrote through a symlinked ancestor'

mode_root=$(new_case writable-ancestor)
mkdir "$mode_root/run/enoshima"
chmod 0775 "$mode_root/run/enoshima"
if run_guard "$mode_root" hold >/dev/null 2>&1; then
  fail 'a group-writable runtime ancestor was accepted'
fi

target_root=$(new_case symlink-target)
mkdir "$target_root/run/systemd/user"
ln -s "$target_root/redirect" \
  "$target_root/run/systemd/user/vicinae.service"
if run_guard "$target_root" hold >/dev/null 2>&1; then
  fail 'a native mask with an unexpected symlink target was replaced'
fi
[[ -L $target_root/run/systemd/user/vicinae.service &&
  $(readlink -- "$target_root/run/systemd/user/vicinae.service") == "$target_root/redirect" ]] ||
  fail 'the unsafe target was unexpectedly mutated'

direct_root=$(new_case direct-process)
cp /usr/bin/sleep "$direct_root/direct-vicinae"
chmod 0755 "$direct_root/direct-vicinae"
"$direct_root/direct-vicinae" 30 &
direct_pid=$!
if run_guard "$direct_root" hold >/dev/null 2>&1; then
  fail 'a directly launched Vicinae process was accepted'
fi
[[ -L $direct_root/run/systemd/user/vicinae.service ]] ||
  fail 'a direct process failure removed the hold'
kill "$direct_pid" 2>/dev/null || true
wait "$direct_pid" 2>/dev/null || true
direct_pid=

legacy_root=$(new_case legacy-direct-process)
mkdir -p "$legacy_root/legacy-vicinae"
cp /usr/bin/sleep "$legacy_root/legacy-vicinae/vicinae"
chmod 0755 "$legacy_root/legacy-vicinae/vicinae"
"$legacy_root/legacy-vicinae/vicinae" 30 &
direct_pid=$!
if run_guard "$legacy_root" hold >/dev/null 2>&1; then
  fail 'a legacy /opt-style Vicinae process was accepted'
fi
[[ -L $legacy_root/run/systemd/user/vicinae.service ]] ||
  fail 'a legacy direct process failure removed the hold'
kill "$direct_pid" 2>/dev/null || true
wait "$direct_pid" 2>/dev/null || true
direct_pid=

appimage_root=$(new_case appimage-direct-process)
mkdir -p "$appimage_root/tmp/.mount_vicinaeTEST"
cp /usr/bin/sleep "$appimage_root/tmp/.mount_vicinaeTEST/AppRun"
chmod 0755 "$appimage_root/tmp/.mount_vicinaeTEST/AppRun"
"$appimage_root/tmp/.mount_vicinaeTEST/AppRun" 30 &
direct_pid=$!
if run_guard "$appimage_root" hold >/dev/null 2>&1; then
  fail 'a Vicinae AppImage mount process was accepted'
fi
kill "$direct_pid" 2>/dev/null || true
wait "$direct_pid" 2>/dev/null || true
direct_pid=

shadow_root=$(new_case shadowed-global-mask)
printf '1001 alice yes active\n' >"$shadow_root/users"
: >"$shadow_root/shadow-alice"
if run_guard "$shadow_root" hold >/dev/null 2>&1; then
  fail 'a user unit shadowing the global native mask was accepted'
fi
[[ -L $shadow_root/run/systemd/user/vicinae.service ]] ||
  fail 'a shadowed native mask was not retained fail-closed'

external_root=$(new_case external-mask)
mkdir "$external_root/run/systemd/user"
ln -s -- /dev/null "$external_root/run/systemd/user/vicinae.service"
printf '1001 alice yes active\n' >"$external_root/users"
run_guard "$external_root" hold || fail 'a safe administrator mask was rejected'
printf '0\n' >"$external_root/compat-status"
run_guard "$external_root" release-if-compatible ||
  fail 'compatible release failed while preserving an administrator mask'
[[ -L $external_root/run/systemd/user/vicinae.service ]] ||
  fail 'compatible release removed a pre-existing administrator mask'
[[ ! -s $external_root/run/enoshima/vicinae-qt-guard.lock ]] ||
  fail 'the guard claimed ownership of a pre-existing administrator mask'

usage_root=$(new_case usage)
if run_guard "$usage_root" unsupported >/dev/null 2>&1; then
  fail 'an unsupported guard command was accepted'
else
  status=$?
fi
[[ $status == 2 ]] || fail 'unsupported guard commands do not return status 2'

echo 'Vicinae Qt guard tests passed.'
