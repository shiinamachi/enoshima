#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

for package in atop iotop-c nvtop resources sysprof sysstat; do
  grep -Fxq -- "$package" packages/native.txt
done

main_tasks=ansible/roles/system/tasks/main.yml
observability=ansible/roles/system/tasks/observability.yml
handlers=ansible/roles/system/handlers/main.yml
postflight=scripts/postflight.sh

grep -Fq 'ansible.builtin.import_tasks: observability.yml' "$main_tasks"
grep -Fq 'Storage=persistent' "$observability"
grep -Fq 'SystemMaxUse=1G' "$observability"
grep -Fq 'SystemKeepFree=2G' "$observability"
grep -Fq 'MaxRetentionSec=30day' "$observability"
grep -Fq 'DefaultIOAccounting=yes' "$observability"
if grep -Fq 'DefaultCPUAccounting' "$observability"; then
  echo 'DefaultCPUAccounting is deprecated and must not be configured.' >&2
  exit 1
fi
grep -Fq '60-enoshima-retention.conf' "$observability"
grep -Fq '60-enoshima-accounting.conf' "$observability"
grep -Fq 'mode: "0700"' "$observability"
grep -Fq 'UMask=0077' "$observability"
grep -Fq 'Restart=on-failure' "$observability"
grep -Fq 'StartLimitIntervalSec=60s' "$observability"
grep -Fq 'StartLimitBurst=5' "$observability"
grep -Fq '{ key: ATOPACCT, value: '\''""'\'' }' "$observability"
grep -Fq 'name: Disable atop process accounting' "$observability"
if grep -Fq 'BindsTo=atopacct.service' "$observability" ||
  grep -Fq 'ExecStartPre=/usr/bin/systemctl is-active --quiet atopacct.service' \
    "$observability"; then
  echo 'Atop must not depend on process accounting.' >&2
  exit 1
fi
grep -Fq 'OnCalendar=*-*-* *:*:00/30' "$observability"
grep -Fq 'AccuracySec=1s' "$observability"
grep -Fq 'name: atopacct.service' "$observability"
grep -Fq 'path: /var/cache/atop.d' "$observability"
grep -Fq 'path: /var/cache/atop.d/atop.acct' "$observability"
grep -Fq 'path: /var/log/sa' "$observability"
grep -Fq '{ key: SADC_OPTIONS, value: '\''"-S DISK,POWER"'\'' }' "$observability"
grep -Fq '{ key: UMASK, value: "0077" }' "$observability"
grep -Fq "name: Discover today's sysstat history file" "$observability"
grep -Fq 'sysstat_current_history.stat.exists' "$observability"
grep -Fq "name: Inspect today's sysstat history schema" "$observability"
grep -Fq '/var/log/sa/.enoshima-migrated-' "$observability"
grep -Fq 'name: Discover expired sysstat schema migration archives' "$observability"
grep -Fq 'patterns: ".enoshima-migrated-*"' "$observability"
grep -Fq 'age: 28d' "$observability"
grep -Fq 'name: Remove expired sysstat schema migration archives' "$observability"
grep -Fq 'name: Preserve the incompatible current sysstat history' "$observability"
grep -Fq 'name: Create a current sysstat sample with the managed schema' "$observability"
grep -Fq 'name: Resume sysstat collection after schema migration' "$observability"
if sed -n \
  '/name: Migrate an incompatible current sysstat history file/,/name: Discover expired sysstat schema migration archives/p' \
  "$observability" | grep -Eq 'state:[[:space:]]+absent'; then
  echo 'Sysstat schema migration must preserve existing history.' >&2
  exit 1
fi
grep -Fq 'name: atopgpu.service' "$observability"
grep -Fq 'name: Reload journald' "$handlers"
grep -Fq 'name: Flush journal to persistent storage' "$handlers"
grep -Fq '/usr/bin/journalctl --flush' "$handlers"
grep -Fq 'name: Reexecute systemd manager' "$handlers"
grep -Fq 'daemon_reexec: true' "$handlers"
grep -Fq 'name: Restart atop' "$handlers"
grep -Fq 'name: Restart sysstat collection timer' "$handlers"

grep -Fq 'effective_systemd_setting()' "$postflight"
grep -Fq 'atop_history_policy_configured()' "$postflight"
grep -Fq 'atop_process_accounting_disabled()' "$postflight"
grep -Fq 'sysstat_timer_policy_configured()' "$postflight"
grep -Fq 'systemctl show -P DefaultIOAccounting' "$postflight"
grep -Fq 'systemctl show atop.service -P UMask' "$postflight"
grep -Fq 'atop_history_recent_and_readable()' "$postflight"
grep -Fq 'sysstat_history_recent_and_readable()' "$postflight"
grep -Fq 'atop has written recent parseable local history' "$postflight"
grep -Fq 'sysstat has written recent parseable local history' "$postflight"
grep -Fq 'persistent journal contains a current-boot record' "$postflight"
grep -Fq 'TimersCalendar' "$postflight"
grep -Fq 'AccuracyUSec' "$postflight"
grep -Fq 'systemctl show atop.service -P StartLimitIntervalUSec' "$postflight"
grep -Fq 'unit_disabled_and_inactive atopacct.service' "$postflight"
grep -Fq "grep -Fxq 'ATOPACCT='" "$postflight"
# shellcheck disable=SC2016
grep -Fq 'sudo -n cat "/proc/$main_pid/environ" | tr' "$postflight"
grep -Fq 'atop fallback accounting directory is private' "$postflight"
# These assertions intentionally match the literal variable reference in the
# deployed postflight implementation.
# shellcheck disable=SC2016
grep -Fq '/usr/bin/sar -d -f "$latest"' "$postflight"
# shellcheck disable=SC2016
grep -Fq '/usr/bin/sar -m CPU,FREQ,TEMP -f "$latest"' "$postflight"
grep -Fq 'unit_disabled_and_inactive atopgpu.service' "$postflight"

grep -Fq '{ key: LOGINTERVAL, value: "60" }' "$observability"
grep -Fq '{ key: LOGGENERATIONS, value: "14" }' "$observability"
grep -Fq '{ key: HISTORY, value: "28" }' "$observability"

systemd-analyze calendar '*-*-* *:*:00/30' >/dev/null

test -f docs/PERFORMANCE-DIAGNOSTICS.md
grep -Fq '/var/log/atop/' docs/PERFORMANCE-DIAGNOSTICS.md
grep -Fq '/var/log/sa/' docs/PERFORMANCE-DIAGNOSTICS.md
grep -Fq 'migration archives older than that retention boundary' docs/PERFORMANCE-DIAGNOSTICS.md
grep -Fq 'uploaded or synchronized.' docs/PERFORMANCE-DIAGNOSTICS.md
grep -Fq 'performance-observability-history-overhead' tests/verification-map.yaml
grep -Fq 'performance-observability-history-overhead' docs/VM-TESTING.md
grep -Fq 'sudo sar -A -f /var/log/sa/saDD' docs/PERFORMANCE-DIAGNOSTICS.md
grep -Fq 'three collectors plus systemd cgroup IO accounting' docs/PERFORMANCE-DIAGNOSTICS.md
for direct_tool in 's-tui' 'sudo turbostat' 'sudo powertop'; do
  grep -Fxq -- "$direct_tool" docs/PERFORMANCE-DIAGNOSTICS.md
done

if find home/dot_config/systemd ansible/roles/system -type f \
  \( -iname '*performance-watcher*' -o -iname '*perf-watcher*' \) | grep -q .; then
  echo 'A custom performance watcher is outside the package-first design.' >&2
  exit 1
fi

printf 'Performance observability tests passed.\n'
