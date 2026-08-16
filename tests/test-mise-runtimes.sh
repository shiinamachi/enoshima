#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/home/dot_config/mise/config.toml"

python - "$config" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)

assert config["min_version"] == "2026.7.5"
assert config["tools"] == {
    "node": "24",
    "python": "3.14",
    "go": "1.26",
    "rust": {"version": "1.97.0", "profile": "default"},
    "uv": "0.11",
}
assert config["settings"]["idiomatic_version_file_enable_tools"] == [
    "node",
    "python",
    "go",
    "rust",
]
PY

# These are literal source-code invariants, not shell expansions.
# shellcheck disable=SC2016
grep -Fq 'MISE_CONFIG_FILE="$mise_config_source" timeout' \
  "$repo_root/bootstrap.sh"
grep -Fq -- '--signal=TERM' "$repo_root/bootstrap.sh"
grep -Fq -- '--kill-after=30s' "$repo_root/bootstrap.sh"
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$mise_command" -C "$isolated_config_dir" install --yes' \
  "$repo_root/bootstrap.sh"
grep -Fq 'MISE_INSTALL_TIMEOUT_SECONDS:-600' "$repo_root/bootstrap.sh"
grep -Fq 'MISE_INSTALL_MAX_ATTEMPTS:-4' "$repo_root/bootstrap.sh"
grep -Fq 'MISE_INSTALL_RETRY_DELAY_SECONDS:-10' "$repo_root/bootstrap.sh"

timeout_work=$(mktemp -d)
trap 'rm -rf -- "$timeout_work"' EXIT
mkdir -p -- "$timeout_work/bin"
# shellcheck disable=SC2016 # The generated mock expands these values at runtime.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'count=0' \
  '[[ ! -f $MISE_TIMEOUT_ATTEMPT_FILE ]] || read -r count <"$MISE_TIMEOUT_ATTEMPT_FILE"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$MISE_TIMEOUT_ATTEMPT_FILE"' \
  'sleep 5' >"$timeout_work/bin/mise"
chmod +x "$timeout_work/bin/mise"
retry_helper=$(sed -n '/^run_with_bounded_retries()/,/^}/p' "$repo_root/bootstrap.sh")
mise_once=$(sed -n '/^install_mise_runtimes_once()/,/^}/p' "$repo_root/bootstrap.sh")
mise_retry=$(sed -n '/^install_mise_runtimes()/,/^}/p' "$repo_root/bootstrap.sh")
if (
  eval "$retry_helper"
  eval "$mise_once"
  eval "$mise_retry"
  export PATH="$timeout_work/bin:$PATH"
  export MISE_TIMEOUT_ATTEMPT_FILE=$timeout_work/attempts
  export MISE_INSTALL_MAX_ATTEMPTS=2
  export MISE_INSTALL_RETRY_DELAY_SECONDS=0
  export MISE_INSTALL_TIMEOUT_SECONDS=1
  # shellcheck disable=SC2034 # Consumed by the extracted helper.
  mise_config_source=$config
  # shellcheck disable=SC2034 # Consumed by the extracted helper.
  mise_command=$timeout_work/bin/mise
  install_mise_runtimes
) >"$timeout_work/output" 2>&1; then
  printf 'FAIL: timed-out mise runtime installation was accepted\n' >&2
  exit 1
fi
[[ $(<"$timeout_work/attempts") == 2 ]] || {
  printf 'FAIL: mise per-attempt timeout did not consume the bounded retry budget\n' >&2
  exit 1
}
grep -Fq 'mise runtime installation attempt 1/2 failed' "$timeout_work/output"
grep -Fq 'mise runtime installation exhausted 2 attempts' "$timeout_work/output"
# shellcheck disable=SC2016
grep -Fq 'RUSTUP_TOOLCHAIN="$rust_toolchain"' \
  "$repo_root/bootstrap.sh"
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq 'LOCAL_PACKAGE_RUST_TOOLCHAIN_ROOT="$rust_toolchain_root"' \
  "$repo_root/bootstrap.sh"
grep -Fq '/usr/bin/env -i' "$repo_root/bootstrap.sh"
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq 'MISE_CONFIG_DIR="$mise_config_dir"' "$repo_root/bootstrap.sh"
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$rustup_home/toolchains/$rust_toolchain-x86_64-unknown-linux-gnu"' \
  "$repo_root/bootstrap.sh"
grep -Fq '/build/rust-toolchain/bin/rustc -vV' \
  "$repo_root/scripts/install-local-packages.sh"
grep -Fq '/build/rust-toolchain/bin/cargo -Vv' \
  "$repo_root/scripts/install-local-packages.sh"
grep -Fq '.build.rustToolchain.rustcCommit' \
  "$repo_root/scripts/install-local-packages.sh"
grep -Fq '.build.rustToolchain.cargoCommit' \
  "$repo_root/scripts/install-local-packages.sh"
# shellcheck disable=SC2016
if grep -Fq 'mise exec -- "$repo_root/scripts/install-local-packages.sh"' \
  "$repo_root/bootstrap.sh"; then
  printf 'FAIL: global mise PATH shadows pacman Python during local builds\n' >&2
  exit 1
fi

if rg -n 'rustup (toolchain|default|component)' \
  "$repo_root/ansible/roles/user_tools"; then
  printf 'FAIL: Ansible still selects a Rust runtime outside mise\n' >&2
  exit 1
fi

grep -Fq 'runtime_bins=(node python go rustc uv)' \
  "$repo_root/scripts/postflight.sh" || {
  printf 'FAIL: postflight does not verify all managed runtime tools\n' >&2
  exit 1
}

printf 'PASS: mise owns the workstation development runtime definitions\n'
