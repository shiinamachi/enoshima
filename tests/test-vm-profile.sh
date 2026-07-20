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
    .enoshima_capabilities.wwan
  ] | all(. == false))
' <<<"$inventory_json" >/dev/null || fail 'VM capability contract is invalid'

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
