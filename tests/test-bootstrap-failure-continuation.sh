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

printf 'Bootstrap failure continuation tests passed.\n'
