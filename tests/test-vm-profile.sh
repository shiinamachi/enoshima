#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'VM profile test failed: %s\n' "$*" >&2
  exit 1
}

inventory_json=$(ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
  ansible-inventory \
  --inventory "$repo_root/ansible/inventory/hosts.yml" \
  --host enoshima-vm)

jq -e '
  .enoshima_environment == "vm" and
  .enoshima_capabilities.graphical_session == true and
  .enoshima_capabilities.virtual_gpu_3d == true and
  ([
    .enoshima_capabilities.battery,
    .enoshima_capabilities.boot_artifacts,
    .enoshima_capabilities.camera,
    .enoshima_capabilities.fingerprint,
    .enoshima_capabilities.hibernation,
    .enoshima_capabilities.secure_boot,
    .enoshima_capabilities.thunderbolt,
    .enoshima_capabilities.tpm,
    .enoshima_capabilities.vm_test_host,
    .enoshima_capabilities.wwan
  ] | all(. == false))
' <<<"$inventory_json" >/dev/null || fail 'VM capability contract is invalid'

# shellcheck source=../scripts/lib/inventory-capabilities.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/inventory-capabilities.sh"
inventory_capability '{"enoshima_capabilities":{"battery":true}}' battery ||
  fail 'an explicitly enabled capability was disabled'
if inventory_capability '{"enoshima_capabilities":{"battery":false}}' battery; then
  fail 'an explicitly disabled capability was enabled'
fi
inventory_capability '{"enoshima_capabilities":{}}' battery ||
  fail 'a missing capability did not preserve the compatibility default'
inventory_capability '{}' battery ||
  fail 'a missing capability map did not preserve the compatibility default'

for package in cloud-image-utils edk2-ovmf libvirt qemu-desktop swtpm; do
  grep -Fxq "$package" "$repo_root/packages/vm-host.txt" ||
    fail "VM host package manifest omits $package"
  if grep -Fxq "$package" "$repo_root/packages/native.txt"; then
    fail "VM host-only package leaks into every guest: $package"
  fi
done
grep -Fq 'enoshima_capabilities.vm_test_host | bool' \
  "$repo_root/ansible/roles/packages/tasks/main.yml" ||
  fail 'VM host package installation is not capability-gated'
grep -Fq 'Ensure the SDDM configuration drop-in directory exists' \
  "$repo_root/ansible/roles/desktop_expansion/tasks/sddm.yml" ||
  fail 'desktop expansion does not create the SDDM drop-in directory'
jq -e '
  .zram_size_expression == "min(ram / 4, 8192)" and
  .zram_compression_algorithm == "zstd" and
  .zram_swap_priority == 100
' <<<"$inventory_json" >/dev/null || fail 'VM zram policy is incomplete'
for retry_result in desired_packages_install optional_packages_install; do
  grep -Fq "until: $retry_result is succeeded" \
    "$repo_root/ansible/roles/packages/tasks/main.yml" ||
    fail "package convergence does not retry transient downloads: $retry_result"
done
grep -Fxq '  - electron39' "$repo_root/ansible/inventory/host_vars/enoshima-vm.yml" ||
  fail 'VM profile omits the pinned Electron qualification runtime'
if grep -Fxq electron39 "$repo_root/packages/native.txt"; then
  fail 'Electron qualification runtime leaked into the physical workstation manifest'
fi
grep -Fq '+ (additional_native_packages | default([]))' \
  "$repo_root/ansible/roles/packages/tasks/main.yml" ||
  fail 'package convergence ignores profile-scoped native packages'

for option in --inventory --report-dir --report-format; do
  "$repo_root/bootstrap.sh" --help | grep -Fq -- "$option" ||
    fail "bootstrap help omits $option"
done
for option in --inventory --profile --format --output; do
  "$repo_root/scripts/postflight.sh" --help | grep -Fq -- "$option" ||
    fail "postflight help omits $option"
done

# shellcheck source=../scripts/lib/bootstrap-failures.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/bootstrap-failures.sh"
bootstrap_report_dir=$work/report
# Read dynamically by bootstrap_write_report from the sourced helper.
# shellcheck disable=SC2034
bootstrap_report_format=json
bootstrap_report_state_file=$bootstrap_report_dir/.bootstrap-steps.tsv
install -d -m 0700 "$bootstrap_report_dir"
: >"$bootstrap_report_state_file"

bootstrap_run_step "successful stage" true >/dev/null
bootstrap_run_step "failed stage" false >/dev/null 2>&1
if bootstrap_finish >/dev/null 2>&1; then
  fail 'reporting test did not preserve the failed aggregate result'
fi

jq -e '
  .schema == 1 and
  .result == "failed" and
  .summary == {"pass": 1, "fail": 1} and
  (.steps | length) == 2 and
  .steps[0].label == "successful stage" and
  .steps[1].exit_code == 1
' "$bootstrap_report_dir/bootstrap.json" >/dev/null ||
  fail 'bootstrap JSON report is incomplete'

printf 'VM profile and structured reporting tests passed.\n'
