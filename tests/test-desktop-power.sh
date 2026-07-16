#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-power
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

export HOME=$work/home
export XDG_STATE_HOME=$HOME/.local/state
export XDG_CONFIG_HOME=$HOME/.config
export XDG_SESSION_ID=test-session
export DESKTOP_POWER_STATE_HOME=$XDG_STATE_HOME
export DESKTOP_POWER_BOOT_ID_FILE=$work/boot-id
export DESKTOP_POWER_SYSTEMCTL=$work/bin/systemctl
export DESKTOP_POWER_SYSTEMD_RUN=$work/bin/systemd-run
export DESKTOP_POWER_LOGINCTL=$work/bin/loginctl
export DESKTOP_POWER_BUSCTL=$work/bin/busctl
export DESKTOP_POWER_HYPRSHUTDOWN=$work/bin/hyprshutdown
export DESKTOP_POWER_JOURNALCTL=$work/bin/journalctl
export DESKTOP_POWER_INHIBIT=$work/bin/systemd-inhibit
export DESKTOP_POWER_SELF=$helper
export POWER_TEST_LOG=$work/commands.log
mkdir -p "$HOME" "$work/bin"
printf 'boot-a\n' >"$DESKTOP_POWER_BOOT_ID_FILE"

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
case $method in
  CanSuspend) answer=${POWER_CAN_SUSPEND:-yes} ;;
  CanReboot) answer=${POWER_CAN_REBOOT:-yes} ;;
  CanPowerOff) answer=${POWER_CAN_POWEROFF:-challenge} ;;
  CanHibernate) answer=${POWER_CAN_HIBERNATE:-no} ;;
  *) answer=unknown ;;
esac
printf 's "%s"\n' "$answer"
FAKE

for command in systemctl loginctl journalctl systemd-inhibit systemd-run; do
  cat >"$work/bin/$command" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
name=${0##*/}
printf '%s' "$name" >>"${POWER_TEST_LOG:?}"
for argument in "$@"; do printf ' %q' "$argument" >>"$POWER_TEST_LOG"; done
printf '\n' >>"$POWER_TEST_LOG"
if [[ $name == systemd-run && ${POWER_SYSTEMD_RUN_FAIL:-false} == true ]]; then
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
[[ ${POWER_HYPRSHUTDOWN_FAIL:-false} != true ]]
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

printf '%s\n' '==> reboot records a checkpoint before graceful session shutdown'
reset_log
run_power reboot
pending=$XDG_STATE_HOME/enoshima/power/pending.json
jq -e '
  .schema == 1 and .action == "reboot" and .phase == "requested" and
  .boot_id_before == "boot-a" and .session == "test-session"
' "$pending" >/dev/null || fail 'reboot checkpoint is invalid'
grep -Fq 'systemd-run --user --quiet --collect --unit=enoshima-desktop-power-reboot --property=Type=exec --property=Slice=background.slice -- ' "$POWER_TEST_LOG" ||
  fail 'reboot did not use an independent user systemd unit'
grep -Fq 'hyprshutdown --no-fork --verbose --post-cmd ' "$POWER_TEST_LOG" ||
  fail 'reboot did not request a foreground graceful shutdown'

printf '%s\n' '==> the post command records systemctl dispatch before rebooting'
run_power finalize-transition reboot
jq -e '.phase == "systemctl_dispatched" and (.systemctl_dispatched_at | type == "string")' \
  "$pending" >/dev/null || fail 'systemctl dispatch was not checkpointed'
grep -Fxq 'systemctl reboot' "$POWER_TEST_LOG" || fail 'reboot did not reach systemctl'

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

printf '%s\n' '==> an unrelated boot change is not mistaken for a successful reboot'
printf 'boot-b\n' >"$DESKTOP_POWER_BOOT_ID_FILE"
run_power reboot
printf 'boot-c\n' >"$DESKTOP_POWER_BOOT_ID_FILE"
if run_power verify-last-action >/dev/null; then
  fail 'boot change without systemctl dispatch unexpectedly succeeded'
fi
jq -e '.status == "boot_changed_without_dispatch" and .phase == "requested"' \
  "$XDG_STATE_HOME/enoshima/power/last-result.json" >/dev/null ||
  fail 'boot change without dispatch was not identified'

printf '%s\n' '==> dispatch failure is explicit and does not retain a stale checkpoint'
if POWER_HYPRSHUTDOWN_FAIL=true POWER_SYSTEMD_RUN_FAIL=true run_power reboot 2>/dev/null; then
  fail 'failed systemd-run dispatch unexpectedly succeeded'
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

printf 'Desktop power controller tests passed.\n'
