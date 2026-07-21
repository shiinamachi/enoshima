#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
desktop=$repo_root/tests/vm/suites/desktop.yaml
login=$repo_root/tests/vm/suites/login.yaml
service=$repo_root/tests/vm/src/enoshima_vm/service.py
watchdog=$repo_root/tests/vm/src/enoshima_vm/watchdog.py
electron_fixture=$repo_root/tests/vm/fixtures/electron-window

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
grep -Fq 'disable_unlisted: true' "$desktop" ||
  fail 'desktop suite leaves the QEMU scanout in the mixed-DPI evidence layout'
grep -Fq 'monitor_count: 2' "$desktop" ||
  fail 'desktop suite does not prove the exact output topology'
grep -Fq 'hyprctl eval' "$service" ||
  fail 'desktop output configuration does not invoke Hyprland eval'
grep -Fq '_monitor_eval_expression' "$service" ||
  fail 'desktop output configuration does not use the Hyprland Lua evaluator'
grep -Fq '_decoration_allowlist_expression' "$service" ||
  fail 'titlebar fixture allowlist does not use the Hyprland Lua evaluator'
grep -Fq 'VM workspaces are confined to the reviewed virtual outputs' \
  "$repo_root/scripts/postflight.sh" ||
  fail 'postflight applies physical monitor assertions to VM-only outputs'

grep -Fq -- '- prepare_login' "$login" ||
  fail 'login suite does not create a disposable password'
grep -Fq -- '- login_greetd' "$login" ||
  fail 'login suite does not exercise the real greetd session'
grep -Fq 'secrets.token_hex(16)' "$service" ||
  fail 'greetd password is not generated uniquely per run'
grep -Fq 'gnome-keyring-daemon --unlock' "$service" ||
  fail 'the disposable login keyring is not initialized before greetd login'
grep -Fq 'guest.upload_file(password_path, REMOTE_LOGIN_PASSWORD)' "$service" ||
  fail 'the keyring is not initialized with the raw disposable password'
grep -Fq 'sudo chpasswd < {REMOTE_LOGIN_CREDENTIAL}' "$service" ||
  fail 'chpasswd does not receive its dedicated user:password credential'
grep -Fq 'secret-tool store' "$service" ||
  fail 'greetd login does not prove the Secret Service is unlocked'
grep -Fq 'unlock login keyring' "$service" ||
  fail 'greetd login does not reject a visible keyring unlock prompt'
grep -Fq 'record.pop("login_password", None)' "$service" ||
  fail 'normal cleanup retains the greetd password reference'
grep -Fq 'record.pop("login_password", None)' "$watchdog" ||
  fail 'watchdog cleanup retains the greetd password reference'
grep -Fq 'captured compositor evidence is not a PNG' "$service" ||
  fail 'compositor screenshots are not structurally validated'
grep -Fq 'junit.xml' "$service" ||
  fail 'suite steps are not exported as JUnit evidence'
grep -Fq '"main": "main.js"' "$electron_fixture/package.json" ||
  fail 'Electron qualification fixture has no application entry point'

printf 'VM desktop and greetd contract tests passed.\n'
