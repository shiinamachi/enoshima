#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
desktop=$repo_root/tests/vm/suites/desktop.yaml
login=$repo_root/tests/vm/suites/login.yaml
service=$repo_root/tests/vm/src/enoshima_vm/service.py
watchdog=$repo_root/tests/vm/src/enoshima_vm/watchdog.py

fail() {
  printf 'VM desktop contract test failed: %s\n' "$*" >&2
  exit 1
}

for output in HEADLESS-INTERNAL HEADLESS-EXTERNAL; do
  grep -Fq "name: $output" "$desktop" ||
    fail "desktop suite omits virtual output $output"
done
grep -Fq 'keys: [KEY_LEFTMETA, KEY_ENTER]' "$desktop" ||
  fail 'desktop suite does not exercise the terminal binding'
grep -Fq 'wait_for_client:' "$desktop" ||
  fail 'desktop suite does not prove that the terminal appeared'
grep -Fq 'active_workspace: "2"' "$desktop" ||
  fail 'desktop suite does not prove workspace input routing'
grep -Fq 'namespace: cyberlauncher' "$desktop" ||
  fail 'desktop suite does not prove the launcher layer appeared'

grep -Fq -- '- prepare_login' "$login" ||
  fail 'login suite does not create a disposable password'
grep -Fq -- '- login_greetd' "$login" ||
  fail 'login suite does not exercise the real greetd session'
grep -Fq 'secrets.token_hex(16)' "$service" ||
  fail 'greetd password is not generated uniquely per run'
grep -Fq 'record.pop("login_password", None)' "$service" ||
  fail 'normal cleanup retains the greetd password reference'
grep -Fq 'record.pop("login_password", None)' "$watchdog" ||
  fail 'watchdog cleanup retains the greetd password reference'
grep -Fq 'captured compositor evidence is not a PNG' "$service" ||
  fail 'compositor screenshots are not structurally validated'

printf 'VM desktop and greetd contract tests passed.\n'
