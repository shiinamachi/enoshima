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
    "rust": {"version": "1.97", "profile": "default"},
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
grep -Fq 'MISE_CONFIG_FILE="$mise_config_source" mise install --yes' \
  "$repo_root/bootstrap.sh"
# shellcheck disable=SC2016
grep -Fq 'mise exec -- "$repo_root/scripts/install-local-packages.sh"' \
  "$repo_root/bootstrap.sh"

if rg -n 'rustup (toolchain|default|component)' \
  "$repo_root/ansible/roles/user_tools"; then
  printf 'FAIL: Ansible still selects a Rust runtime outside mise\n' >&2
  exit 1
fi

printf 'PASS: mise owns the workstation development runtime definitions\n'
