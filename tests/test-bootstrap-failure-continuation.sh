#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/lib/bootstrap-failures.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/bootstrap-failures.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'Bootstrap failure continuation test failed: %s\n' "$*" >&2
  exit 1
}

failing_step() {
  printf 'failing step started\n' >>"$work/steps"
  false
  printf 'failing step continued internally\n' >>"$work/steps"
}

successful_step() {
  printf 'successful later step\n' >>"$work/steps"
}

bootstrap_run_step "intentional failure" failing_step \
  >"$work/output" 2>"$work/error"
# shellcheck disable=SC2154
[[ $bootstrap_last_step_status -eq 1 ]] ||
  fail 'the failed step status was not retained'
bootstrap_run_step "independent success" successful_step \
  >>"$work/output" 2>>"$work/error"

grep -Fxq 'failing step started' "$work/steps" ||
  fail 'the failing step was not attempted'
if grep -Fq 'failing step continued internally' "$work/steps"; then
  fail 'a failed step was not isolated with errexit'
fi
grep -Fxq 'successful later step' "$work/steps" ||
  fail 'a later independent step did not run'
grep -Fq \
  'FAILURE: intentional failure exited with status 1; continuing with independent steps.' \
  "$work/error" || fail 'the failure was not reported'

if bootstrap_finish >>"$work/output" 2>>"$work/error"; then
  fail 'the aggregate result hid an earlier failure'
fi
grep -Fq 'Bootstrap completed with 1 FAILURE(S):' "$work/error" ||
  fail 'the final failure summary is missing'

set +e
(
  # Reset the sourced helper's aggregate state for the independent hard-stop case.
  bootstrap_failures=()
  bootstrap_last_step_status=0
  bootstrap_run_step "unresolved installed package safety" bash -c 'exit 70'
  printf 'unsafe continuation\n' >"$work/security-mutation"
) >"$work/security-output" 2>"$work/security-error"
security_status=$?
set -e
[[ $security_status -eq 70 ]] ||
  fail 'unresolved installed package safety did not preserve exit status 70'
[[ ! -e $work/security-mutation ]] ||
  fail 'bootstrap continued mutation after unresolved installed package safety'
grep -Fq 'FATAL: unresolved installed package safety left a security-sensitive state' \
  "$work/security-error" ||
  fail 'unresolved installed safety did not report the hard stop'

set +e
(
  # shellcheck disable=SC2034 # Consumed by the sourced step runner.
  bootstrap_failures=()
  bootstrap_last_step_status=0
  # shellcheck disable=SC2034 # Consumed by the sourced step runner.
  bootstrap_report_state_file=$work
  bootstrap_run_step "hard stop with broken report sink" bash -c 'exit 70'
) >"$work/report-output" 2>"$work/report-error"
report_status=$?
set -e
[[ $report_status -eq 70 ]] ||
  fail 'a report write failure downgraded the security hard stop'

bootstrap_cleanup=$(
  sed -n '/^cleanup()/,/^}/p' "$repo_root/bootstrap.sh"
)
set +e
(
  eval "$bootstrap_cleanup"
  # shellcheck disable=SC2329 # Invoked by the extracted EXIT cleanup.
  rm() { return 1; }
  # shellcheck disable=SC2034 # Consumed by the extracted cleanup.
  sudo_keepalive_pid=
  # shellcheck disable=SC2034 # Consumed by the extracted cleanup.
  runtime_dir=$work/runtime
  # shellcheck disable=SC2034 # Consumed by the extracted cleanup.
  bootstrap_report_dir=
  trap cleanup EXIT
  exit 70
) >"$work/bootstrap-cleanup-output" 2>"$work/bootstrap-cleanup-error"
bootstrap_cleanup_status=$?
set -e
[[ $bootstrap_cleanup_status -eq 70 ]] ||
  fail 'top-level cleanup downgraded the security hard stop'

local_cleanup=$(
  sed -n '/^cleanup_local_package_build()/,/^}/p' \
    "$repo_root/scripts/install-local-packages.sh"
)
set +e
(
  eval "$local_cleanup"
  # shellcheck disable=SC2329 # Invoked by the extracted EXIT cleanup.
  cleanup_verified_local_install_stage() { return 1; }
  # shellcheck disable=SC2329 # Invoked by the extracted EXIT cleanup.
  cleanup_local_package_build_root() { return 1; }
  trap cleanup_local_package_build EXIT
  exit 70
) >"$work/local-cleanup-output" 2>"$work/local-cleanup-error"
local_cleanup_status=$?
set -e
[[ $local_cleanup_status -eq 70 ]] ||
  fail 'local-package cleanup downgraded the security hard stop'

printf 'Bootstrap failure continuation tests passed.\n'
