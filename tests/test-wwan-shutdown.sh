#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tasks=$repo_root/ansible/roles/system/tasks/network.yml
helper=$repo_root/ansible/roles/system/templates/enoshima-wwan-quiesce.sh.j2
unit=$repo_root/ansible/roles/system/templates/enoshima-wwan-quiesce.service.j2
dropin=$repo_root/ansible/roles/system/templates/modemmanager-stop-timeout.conf.j2
host_vars=$repo_root/ansible/inventory/host_vars/tpx1c13.yml
doctor=$repo_root/home/dot_local/bin/executable_enoshima-shutdown-doctor

fail() {
  printf 'test-wwan-shutdown: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'After=NetworkManager.service ModemManager.service' "$unit" ||
  fail 'quiesce unit is not ordered after the WWAN services'
grep -Fq 'ExecStop=/usr/local/libexec/enoshima-wwan-quiesce' "$unit" ||
  fail 'quiesce is not executed during stop ordering'
grep -Fq 'TimeoutStopSec=12s' "$unit" || fail 'quiesce unit is not bounded'
grep -Fq 'readonly global_budget_cs=1000' "$helper" ||
  fail 'quiesce helper does not enforce one global deadline'
grep -Fq 'status=$?' "$helper" || fail 'timeout exit status is not preserved'
grep -Fq 'RESULT=$result' "$helper" || fail 'structured result is not journaled'
grep -Fq 'EXIT_STATUS=$status' "$helper" || fail 'structured exit status is not journaled'
grep -Fq 'ELAPSED_MS=$elapsed_ms' "$helper" || fail 'elapsed time is not journaled'
grep -Fq 'run_bounded modem-disable 4' "$helper" || fail 'modem disable budget drifted'
grep -Fq 'run_bounded wwan-radio-off 2' "$helper" || fail 'radio-off budget drifted'
bash -n "$helper"
grep -Fq 'timeout --signal=TERM --kill-after=1s "${step_budget}s"' "$helper" ||
  fail 'modem operations are not individually bounded'
grep -Fq '/usr/bin/mmcli -m any --disable' "$helper" ||
  fail 'modem disable is missing'
grep -Fq '/usr/bin/nmcli radio wwan off' "$helper" ||
  fail 'NetworkManager autoconnect is not stopped'
grep -Fq 'TimeoutStopSec={{ wwan_modemmanager_stop_timeout }}' "$dropin" ||
  fail 'ModemManager timeout is not host-configurable'
grep -Fq 'dest: /etc/systemd/system/ModemManager.service.d/20-enoshima-stop-timeout.conf' "$tasks" ||
  fail 'ModemManager drop-in is not managed'
grep -Fq '  - enoshima-wwan-quiesce.service' "$host_vars" ||
  fail 'quiesce service is not enabled on the WWAN host'
grep -Fq 'journalctl -b -1 -u ModemManager.service' "$doctor" ||
  fail 'shutdown doctor does not collect previous-boot evidence'
grep -Fq '(equipment-identifier|device-identifier|own-numbers|operator-code|operator-name|sim-path)' "$doctor" ||
  fail 'shutdown doctor does not redact private modem identifiers'

printf 'WWAN shutdown policy tests passed.\n'
