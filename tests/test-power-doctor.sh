#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
doctor=$repo_root/home/dot_local/bin/executable_enoshima-power-doctor
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/state"
printf 'boot-test\n' >"$work/boot-id"

for command in systemctl loginctl sleep; do
  cat >"$work/bin/$command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${0##*/}" "$*" >>"$POWER_DOCTOR_LOG"
if [[ ${0##*/} == loginctl && ${1:-} == list-sessions ]]; then
  exit 0
fi
EOF
done
chmod 0700 "$work/bin"/*

export POWER_DOCTOR_LOG=$work/commands.log
export ENOSHIMA_POWER_DOCTOR_STATE_HOME=$work/state
export ENOSHIMA_POWER_DOCTOR_SYSTEMCTL=$work/bin/systemctl
export ENOSHIMA_POWER_DOCTOR_LOGINCTL=$work/bin/loginctl
export ENOSHIMA_POWER_DOCTOR_SLEEP=$work/bin/sleep
export ENOSHIMA_POWER_DOCTOR_BOOT_ID_FILE=$work/boot-id

bash "$doctor" capture --output "$work/capture.txt" >/dev/null
grep -Fq '[Sleep modes]' "$work/capture.txt"
grep -Fq '[Intel PMC residency]' "$work/capture.txt"

jq -e '.kind == "suspend" and .resumed_same_boot == true' \
  < <(bash "$doctor" test-suspend) >/dev/null
grep -Fxq 'loginctl lock-session' "$POWER_DOCTOR_LOG"
grep -Fxq 'systemctl suspend' "$POWER_DOCTOR_LOG"

jq -e '.kind == "hibernate" and .resumed_same_boot == true' \
  < <(bash "$doctor" test-hibernate) >/dev/null
grep -Fxq 'systemctl hibernate' "$POWER_DOCTOR_LOG"

jq -e '.kind == "lid"' \
  < <(bash "$doctor" measure-lid --duration 30m) >/dev/null
grep -Fxq 'sleep 30m' "$POWER_DOCTOR_LOG"

jq -e '.schema == 1 and .runs == 3 and .same_boot_resumes == 3' \
  < <(bash "$doctor" report) >/dev/null

printf 'Power doctor tests passed.\n'
