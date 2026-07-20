#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-power
power_menu=$repo_root/home/dot_config/quickshell/cyberdock/PowerMenu.qml
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export HOME=$work/home
export XDG_STATE_HOME=$HOME/.local/state
export XDG_CONFIG_HOME=$HOME/.config
export XDG_SESSION_ID=test-session
export DESKTOP_POWER_STATE_HOME=$XDG_STATE_HOME
export DESKTOP_POWER_BOOT_ID_FILE=$work/boot-id
export DESKTOP_POWER_SYSTEMCTL=$work/bin/systemctl
export DESKTOP_POWER_LOGINCTL=$work/bin/loginctl
export DESKTOP_POWER_BUSCTL=$work/bin/busctl
export DESKTOP_POWER_HYPRSHUTDOWN=$work/bin/hyprshutdown
export DESKTOP_POWER_HYPRCTL=$work/bin/hyprctl
export DESKTOP_POWER_JOURNALCTL=$work/bin/journalctl
export DESKTOP_POWER_INHIBIT=$work/bin/systemd-inhibit
export POWER_TEST_LOG=$work/commands.log
export POWER_CLIENT_STATE=$work/client-count
mkdir -p "$HOME" "$work/bin"
printf 'boot-a\n' >"$DESKTOP_POWER_BOOT_ID_FILE"
printf '2\n' >"$POWER_CLIENT_STATE"

fail() {
  printf 'test-desktop-power: %s\n' "$*" >&2
  exit 1
}

cat >"$DESKTOP_POWER_BUSCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'busctl' >>"${POWER_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$POWER_TEST_LOG"; done
printf '\n' >>"$POWER_TEST_LOG"
method=${@: -1}
if [[ $method == true && $# -ge 3 ]]; then
  method=${@: -3:1}
  if [[ ${POWER_BUSCTL_DISPATCH_FAIL:-false} == true ]]; then
    exit 1
  fi
fi
case $method in
  CanSuspend) answer=${POWER_CAN_SUSPEND:-yes} ;;
  CanReboot) answer=${POWER_CAN_REBOOT:-yes} ;;
  CanPowerOff) answer=${POWER_CAN_POWEROFF:-challenge} ;;
  CanHibernate) answer=${POWER_CAN_HIBERNATE:-no} ;;
  *) answer=unknown ;;
esac
printf 's "%s"\n' "$answer"
FAKE

for command in systemctl loginctl journalctl systemd-inhibit; do
  cat >"$work/bin/$command" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
name=${0##*/}
printf '%s' "$name" >>"${POWER_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$POWER_TEST_LOG"; done
printf '\n' >>"$POWER_TEST_LOG"
if [[ $name == systemctl && ${POWER_SYSTEMCTL_FAIL:-false} == true ]]; then
  exit 1
fi
FAKE
done

cat >"$DESKTOP_POWER_HYPRSHUTDOWN" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'hyprshutdown' >>"${POWER_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$POWER_TEST_LOG"; done
printf '\n' >>"$POWER_TEST_LOG"
sleep "${POWER_HYPRSHUTDOWN_DELAY:-0}"
[[ ${POWER_HYPRSHUTDOWN_FAIL:-false} != true ]]
FAKE

cat >"$DESKTOP_POWER_HYPRCTL" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == 'clients -j' ]]
count=$(<"${POWER_CLIENT_STATE:?}")
printf '['
for ((index=0; index<count; ++index)); do
  ((index == 0)) || printf ','
  printf '{"address":"0x%x","mapped":true}' "$((0xabc + index))"
done
printf ']\n'
if [[ ${POWER_CLIENTS_DECREMENT:-false} == true && $count -gt 0 ]]; then
  printf '%s\n' "$((count - 1))" >"$POWER_CLIENT_STATE"
fi
FAKE

chmod 0700 "$work"/bin/*

run_power() {
  bash "$helper" "$@"
}

reset_log() {
  : >"$POWER_TEST_LOG"
}

printf '%s\n' '==> status reports logind capability and pending state'
reset_log
jq -e '
  .schema == 1 and
  .availability.suspend == "yes" and
  .availability.reboot == "yes" and
  .availability.poweroff == "challenge" and
  .availability.hibernate == "no" and
  (.pending | not)
' < <(run_power status --json) >/dev/null || fail 'power status is invalid'

printf '%s\n' '==> lock, logout, and suspend use their managed backends'
reset_log
run_power lock
run_power logout
run_power suspend
grep -Fxq 'loginctl lock-session' "$POWER_TEST_LOG" || fail 'lock did not use loginctl'
grep -Fxq 'hyprshutdown' "$POWER_TEST_LOG" || fail 'logout did not use hyprshutdown'
grep -Fxq 'systemctl suspend' "$POWER_TEST_LOG" || fail 'suspend did not use systemctl'

printf '%s\n' '==> reboot closes applications while the graphical session remains alive'
reset_log
printf '2\n' >"$POWER_CLIENT_STATE"
reboot_events=$(POWER_CLIENTS_DECREMENT=true run_power reboot)
pending=$XDG_STATE_HOME/enoshima/power/pending.json
jq -e '
  .schema == 1 and .action == "reboot" and .phase == "login1_dispatching" and
  .boot_id_before == "boot-a" and .session == "test-session"
' "$pending" >/dev/null || fail 'reboot checkpoint is invalid'
grep -Fxq 'hyprshutdown --no-exit --no-fork --verbose' "$POWER_TEST_LOG" ||
  fail 'reboot did not keep Hyprland alive during application close'
grep -Fxq 'busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager Reboot b true' "$POWER_TEST_LOG" ||
  fail 'reboot did not reach the login1 manager'
grep -Fq '"phase":"closing-apps"' <<<"$reboot_events" ||
  fail 'reboot does not stream the application-close phase'
grep -Fq '"phase":"dispatching"' <<<"$reboot_events" ||
  fail 'reboot does not stream the login1 dispatch phase'
grep -Fq '"remaining":1,"total":2' <<<"$reboot_events" ||
  fail 'reboot does not report real client-set convergence'
if grep -Fq 'systemd-run --user' "$POWER_TEST_LOG" || grep -Fq -- '--post-cmd' "$POWER_TEST_LOG"; then
  fail 'reboot still depends on a user-scoped post command'
fi

printf '%s\n' '==> the next boot proves a dispatched reboot by changing boot ID'
printf 'boot-b\n' >"$DESKTOP_POWER_BOOT_ID_FILE"
jq -e '.status == "succeeded" and .boot_id_after == "boot-b"' \
  < <(run_power verify-last-action) >/dev/null || fail 'successful reboot was not verified'
[[ ! -e $pending ]] || fail 'verified reboot retained its pending checkpoint'
jq -e '.status == "succeeded" and .action == "reboot"' \
  "$XDG_STATE_HOME/enoshima/power/last-result.json" >/dev/null ||
  fail 'successful reboot result was not persisted'

printf '%s\n' '==> a same-boot login records a request that did not complete'
run_power poweroff
if run_power verify-last-action >/dev/null; then
  fail 'same-boot poweroff verification unexpectedly succeeded'
fi
jq -e '.status == "not_completed" and .action == "poweroff"' \
  "$XDG_STATE_HOME/enoshima/power/last-result.json" >/dev/null ||
  fail 'incomplete poweroff was not recorded'

printf '%s\n' '==> application close failure is explicit and retains no stale checkpoint'
if POWER_HYPRSHUTDOWN_FAIL=true run_power reboot 2>/dev/null; then
  fail 'failed application close unexpectedly succeeded'
fi
[[ ! -e $pending ]] || fail 'dispatch failure retained a pending checkpoint'
jq -e '.status == "app_close_failed" and .app_close_exit_code == 1 and .action == "reboot"' \
  "$XDG_STATE_HOME/enoshima/power/last-result.json" >/dev/null ||
  fail 'application close failure was not persisted'

printf '%s\n' '==> application close can be cancelled before login1 dispatch'
rm -f -- "$pending"
reset_log
cancel_events=$work/cancel-events.jsonl
POWER_HYPRSHUTDOWN_DELAY=2 run_power reboot >"$cancel_events" &
transition_pid=$!
for _ in {1..100}; do
  [[ -f $pending ]] && break
  sleep 0.01
done
[[ -f $pending ]] || fail 'cancellable transition did not create a checkpoint'
cancel_request=$(jq -r '.request_id' "$pending")
jq -e '.accepted == true' < <(run_power cancel --request-id "$cancel_request") >/dev/null ||
  fail 'power cancellation was not accepted'
if wait "$transition_pid"; then
  fail 'cancelled power transition unexpectedly succeeded'
fi
grep -Fq '"phase":"cancelled"' "$cancel_events" || fail 'cancelled phase was not emitted'
[[ ! -e $pending ]] || fail 'cancelled transition retained its checkpoint'
if grep -Fq 'Manager Reboot b true' "$POWER_TEST_LOG"; then
  fail 'cancelled transition reached login1 dispatch'
fi

printf '%s\n' '==> systemctl is used only if direct login1 dispatch fails'
reset_log
POWER_BUSCTL_DISPATCH_FAIL=true run_power reboot
grep -Fxq 'systemctl reboot' "$POWER_TEST_LOG" || fail 'login1 fallback did not use systemctl'
rm -f -- "$pending"

printf '%s\n' '==> failure of both login1 paths is explicit'
if POWER_BUSCTL_DISPATCH_FAIL=true POWER_SYSTEMCTL_FAIL=true run_power reboot 2>/dev/null; then
  fail 'failed login1 dispatch unexpectedly succeeded'
fi
[[ ! -e $pending ]] || fail 'dispatch failure retained a pending checkpoint'
jq -e '.status == "dispatch_failed" and .dispatch_exit_code == 1 and .action == "reboot"' \
  "$XDG_STATE_HOME/enoshima/power/last-result.json" >/dev/null ||
  fail 'dispatch failure was not persisted'

printf '%s\n' '==> logind denial blocks suspend before systemctl is called'
reset_log
if POWER_CAN_SUSPEND=no run_power suspend 2>/dev/null; then
  fail 'logind-denied suspend unexpectedly succeeded'
fi
if grep -Fxq 'systemctl suspend' "$POWER_TEST_LOG"; then
  fail 'denied suspend still called systemctl'
fi

printf '%s\n' '==> no checkpoint verification is a clean no-op'
jq -e '.schema == 1 and (.pending | not)' \
  < <(run_power verify-last-action) >/dev/null || fail 'empty verification is invalid'

printf '%s\n' '==> power menu follows the approved grouped progress contract'
grep -Fq 'width: Math.min(parent.width - 48, 380)' "$power_menu" ||
  fail 'power card does not use the approved 380px width'
for group in session power system; do
  grep -Fq "\"group\": \"$group\"" "$power_menu" || fail "power group is missing: $group"
done
grep -Fq 'stdout: SplitParser' "$power_menu" || fail 'transition events are not consumed live'
grep -Fq 'function retryAction()' "$power_menu" || fail 'power failures have no retry path'
grep -Fq 'property string lastAttemptedAction' "$power_menu" ||
  fail 'power menu does not retain every failed action for retry'
grep -Fq 'function cancelAction()' "$power_menu" ||
  fail 'application close phase has no cancel path'
if grep -Fq 'execDetached(["desktop-power"' "$power_menu"; then
  fail 'a power action still bypasses the observable Process path'
fi

printf 'Desktop power controller tests passed.\n'
