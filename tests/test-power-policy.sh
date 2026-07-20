#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
host_vars=$repo_root/ansible/inventory/host_vars/tpx1c13.yml
power_tasks=$repo_root/ansible/roles/system/tasks/power.yml
fstab=$repo_root/ansible/roles/system/templates/fstab.j2
kernel_cmdline=$repo_root/ansible/roles/system/templates/kernel-cmdline.j2
sleep_config=$repo_root/ansible/roles/system/templates/sleep-thinkpad.conf.j2
lid_config=$repo_root/ansible/roles/system/templates/logind-lid.conf.j2
tlp_config=$repo_root/ansible/roles/system/templates/tlp-thinkpad.conf.j2
hypridle=$repo_root/home/dot_config/hypr/hypridle.conf
doctor=$repo_root/home/dot_local/bin/executable_enoshima-power-doctor
uki_helper=$repo_root/ansible/roles/system/files/enoshima-rebuild-uki

fail() {
  printf 'test-power-policy: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'desktop_hibernation_enabled: true' "$host_vars" || fail 'hibernation is not enabled'
grep -Fq 'desktop_hibernation_swap_size_gib: 40' "$host_vars" || fail 'swap is not RAM-sized'
grep -Fq 'desktop_hibernate_delay: 30min' "$host_vars" || fail 'hibernate delay is not declared'
grep -Fq 'btrfs subvolume create /run/enoshima-btrfs-root/@swap' "$power_tasks" ||
  fail 'dedicated swap subvolume is not created'
grep -Fq '          - mkswapfile' "$power_tasks" || fail 'Btrfs swap helper is not used'
grep -Fq 'btrfs inspect-internal map-swapfile -r /swap/swapfile' "$power_tasks" ||
  fail 'resume offset is not calculated with the Btrfs helper'
grep -Fq 'Existing /swap/swapfile is smaller' "$power_tasks" ||
  fail 'existing swapfile replacement is not guarded'
grep -Fq 'subvol=@swap,noatime,compress=no' "$fstab" || fail '@swap is not mounted separately'
grep -Fq '/swap/swapfile none swap defaults,pri=10' "$fstab" || fail 'swapfile is not persistent'
grep -Fq 'resume=UUID={{ root_btrfs_uuid }}' "$kernel_cmdline" || fail 'resume device is missing'
grep -Fq 'resume_offset={{ hibernation_resume_offset.stdout | trim }}' "$kernel_cmdline" ||
  fail 'calculated resume offset is missing'

for contract in \
  'AllowHibernation={{' \
  'AllowSuspendThenHibernate={{' \
  'MemorySleepMode=s2idle' \
  'HibernateDelaySec={{ desktop_hibernate_delay }}' \
  "HibernateOnACPower={{ 'yes' if desktop_hibernate_on_ac_power | bool else 'no' }}"; do
  grep -Fq "$contract" "$sleep_config" || fail "sleep contract is missing: $contract"
done
grep -Fq "HandleLidSwitch={{ 'suspend-then-hibernate' if desktop_hibernation_enabled | bool else 'suspend' }}" "$lid_config" ||
  fail 'battery lid policy is wrong'
grep -Fxq 'HandleLidSwitchExternalPower=suspend' "$lid_config" || fail 'AC lid policy is wrong'
grep -Fxq 'HandleLidSwitchDocked=ignore' "$lid_config" || fail 'docked lid policy is wrong'
grep -Fq '/usr/bin/systemctl suspend-then-hibernate' "$hypridle" ||
  fail 'battery idle still uses suspend only'

if grep -Fq 'TLP_DISABLE_DEFAULTS=1' "$tlp_config"; then
  fail 'TLP laptop defaults remain disabled'
fi
for contract in \
  'PCIE_ASPM_ON_BAT=powersave' \
  'WIFI_PWR_ON_BAT=on' \
  'RUNTIME_PM_ON_BAT=auto' \
  'RUNTIME_PM_DENYLIST="{{ tlp_runtime_pm_denylist }}"' \
  'USB_AUTOSUSPEND=1' \
  'USB_DENYLIST="{{ tlp_usb_denylist }}"' \
  'USB_EXCLUDE_WWAN=1'; do
  grep -Fq "$contract" "$tlp_config" || fail "TLP contract is missing: $contract"
done

grep -Fq 'test-suspend)' "$doctor" || fail 'power doctor omits suspend qualification mode'
grep -Fq 'test-hibernate)' "$doctor" || fail 'power doctor omits hibernate qualification mode'
grep -Fq 'measure-lid)' "$doctor" || fail 'power doctor omits lid measurement mode'
grep -Fq 'report)' "$doctor" || fail 'power doctor omits summary mode'
grep -Fq '/sys/power/mem_sleep' "$doctor" || fail 'power doctor omits sleep mode'
grep -Fq 'systemd-inhibit --list' "$doctor" || fail 'power doctor omits inhibitors'
grep -Fq '/sys/kernel/debug/wakeup_sources' "$doctor" || fail 'power doctor omits wake sources'
grep -Fq '/sys/kernel/debug/pmc_core/' "$doctor" || fail 'power doctor omits S0ix evidence'
grep -Fq 'previous=${destination%/*}/${stem}-previous.efi' "$uki_helper" ||
  fail 'transactional UKI helper does not retain a rollback image'
grep -Fq '.cmdline=' "$uki_helper" || fail 'candidate UKI command line is not inspected'

printf 'Laptop power policy tests passed.\n'
