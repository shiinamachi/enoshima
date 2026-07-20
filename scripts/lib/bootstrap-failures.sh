#!/usr/bin/env bash

declare -a bootstrap_failures=()
# Read by the sourcing bootstrap after each isolated step.
# shellcheck disable=SC2034
bootstrap_last_step_status=0
bootstrap_report_written=false

bootstrap_report_slug() {
  LC_ALL=C sed -E \
    -e 's/[^[:alnum:]]+/-/g' \
    -e 's/^-+|-+$//g' \
    -e 's/.*/\L&/' <<<"$1"
}

bootstrap_record_step() {
  local label=$1 status=$2 duration=$3 log_path=${4:-}

  [[ -n ${bootstrap_report_state_file:-} ]] || return 0
  printf '%s\t%s\t%s\t%s\n' \
    "$label" "$status" "$duration" "$log_path" >>"$bootstrap_report_state_file"
}

bootstrap_write_report() {
  local result=${1:-complete}

  [[ -n ${bootstrap_report_dir:-} ]] || return 0
  [[ ${bootstrap_report_written:-false} == false ]] || return 0
  bootstrap_report_written=true

  /usr/bin/python - \
    "$bootstrap_report_state_file" \
    "$bootstrap_report_dir" \
    "${bootstrap_report_format:-text}" \
    "$result" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

state_path = Path(sys.argv[1])
report_dir = Path(sys.argv[2])
report_format = sys.argv[3]
result = sys.argv[4]
steps = []
if state_path.exists():
    for raw_line in state_path.read_text(encoding="utf-8").splitlines():
        label, status, duration, log_path = raw_line.split("\t", 3)
        steps.append(
            {
                "label": label,
                "status": "pass" if int(status) == 0 else "fail",
                "exit_code": int(status),
                "duration_seconds": int(duration),
                "log": log_path or None,
            }
        )

payload = {
    "schema": 1,
    "result": "failed" if any(step["exit_code"] for step in steps) else result,
    "summary": {
        "pass": sum(step["exit_code"] == 0 for step in steps),
        "fail": sum(step["exit_code"] != 0 for step in steps),
    },
    "steps": steps,
}

if report_format == "json":
    destination = report_dir / "bootstrap.json"
    destination.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
else:
    destination = report_dir / "bootstrap.txt"
    lines = [f"Bootstrap result: {payload['result']}"]
    lines.extend(
        f"[{step['status'].upper()}] {step['label']} "
        f"({step['duration_seconds']}s, exit {step['exit_code']})"
        for step in steps
    )
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

bootstrap_record_failure() {
  local label=$1 status=$2
  bootstrap_failures+=("$label (exit $status)")
  printf 'FAILURE: %s exited with status %s; continuing with independent steps.\n' \
    "$label" "$status" >&2
}

bootstrap_run_step() {
  local label=$1 status had_errexit=false start_time duration log_path=
  shift

  printf '==> %s\n' "$label"
  start_time=$(date +%s)
  if [[ -n ${bootstrap_report_dir:-} ]]; then
    log_path=$bootstrap_report_dir/steps/$(bootstrap_report_slug "$label").log
    install -d -m 0700 "${log_path%/*}"
  fi
  [[ $- == *e* ]] && had_errexit=true
  set +e
  if [[ -n $log_path ]]; then
    (
      set -e
      "$@"
    ) > >(tee "$log_path") 2> >(tee -a "$log_path" >&2)
  else
    (
      set -e
      "$@"
    )
  fi
  status=$?
  duration=$(($(date +%s) - start_time))
  if [[ $had_errexit == true ]]; then
    set -e
  fi

  bootstrap_record_step "$label" "$status" "$duration" "$log_path"

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
    bootstrap_write_report failed
    return 1
  fi

  echo "==> Arch Linux configuration converged successfully"
  bootstrap_write_report passed
}
