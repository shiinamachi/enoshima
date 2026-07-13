#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
wrapper="$repo_root/scripts/sudo-noninteractive"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fake_sudo="$test_root/fake-sudo"
output="$test_root/arguments"

# These variables belong to the generated shim.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"$SUDO_TEST_OUTPUT"\n' >"$fake_sudo"
chmod +x "$fake_sudo"

assert_arguments() {
  local expected=$1
  local actual
  actual=$(<"$output")
  if [[ $actual != "$expected" ]]; then
    printf '[FAIL] sudo wrapper arguments\nExpected:\n%s\nActual:\n%s\n' \
      "$expected" "$actual" >&2
    exit 1
  fi
}

echo "==> makepkg's leading reset flag is removed"
SUDO_REAL_COMMAND="$fake_sudo" SUDO_TEST_OUTPUT="$output" \
  "$wrapper" -k /usr/bin/pacman -U package.pkg.tar.zst
assert_arguments $'-n\n/usr/bin/pacman\n-U\npackage.pkg.tar.zst'

echo "==> command arguments after -- remain unchanged"
SUDO_REAL_COMMAND="$fake_sudo" SUDO_TEST_OUTPUT="$output" \
  "$wrapper" -- /usr/bin/example -k --reset-timestamp
assert_arguments $'-n\n--\n/usr/bin/example\n-k\n--reset-timestamp'

echo "Sudo wrapper tests passed."
