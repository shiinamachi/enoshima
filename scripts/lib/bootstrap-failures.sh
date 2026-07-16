#!/usr/bin/env bash

declare -a bootstrap_failures=()
# Read by the sourcing bootstrap after each isolated step.
# shellcheck disable=SC2034
bootstrap_last_step_status=0

bootstrap_record_failure() {
  local label=$1 status=$2
  bootstrap_failures+=("$label (exit $status)")
  printf 'FAILURE: %s exited with status %s; continuing with independent steps.\n' \
    "$label" "$status" >&2
}

bootstrap_run_step() {
  local label=$1 status had_errexit=false
  shift

  printf '==> %s\n' "$label"
  [[ $- == *e* ]] && had_errexit=true
  set +e
  (
    set -e
    "$@"
  )
  status=$?
  if [[ $had_errexit == true ]]; then
    set -e
  fi

  # shellcheck disable=SC2034
  bootstrap_last_step_status=$status
  if ((status == 0)); then
    printf 'SUCCESS: %s\n' "$label"
  else
    bootstrap_record_failure "$label" "$status"
  fi

  return 0
}

bootstrap_finish() {
  if ((${#bootstrap_failures[@]} > 0)); then
    printf '==> Bootstrap completed with %d FAILURE(S):\n' \
      "${#bootstrap_failures[@]}" >&2
    printf '  %s\n' "${bootstrap_failures[@]}" >&2
    return 1
  fi

  echo "==> Arch Linux configuration converged successfully"
}
