#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

echo "==> Checking shell syntax"
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find . -path './.git' -prune -o -type f -name '*.sh' -print0)

if command -v shellcheck >/dev/null 2>&1; then
  mapfile -d '' shell_scripts < <(
    find . -path './.git' -prune -o -type f -name '*.sh' -print0
  )
  shellcheck "${shell_scripts[@]}"
fi

if command -v shfmt >/dev/null 2>&1; then
  shfmt -d -i 2 -ci bootstrap.sh scripts
fi

echo "==> Parsing YAML"
python - "$repo_root" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
for path in sorted(root.rglob("*.yml")):
    if ".git" in path.parts:
        continue
    with path.open("r", encoding="utf-8") as handle:
        yaml.safe_load(handle)
    print(path.relative_to(root))

def manifest(path: Path) -> set[str]:
    result = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line:
            result.add(line)
    return result

state = root / "state" / "tpx1c13"
if state.exists():
    native_desired = manifest(root / "packages" / "native.txt")
    native_observed = set((state / "native-explicit.txt").read_text().splitlines())
    assert native_desired == native_observed, "native package manifest drift"

    aur_desired = manifest(root / "packages" / "aur.txt")
    foreign_observed = {
        package.removesuffix("-debug")
        for package in (state / "foreign-explicit.txt").read_text().splitlines()
    }
    assert aur_desired == foreign_observed, "AUR package-base manifest drift"

    optional_desired = manifest(root / "packages" / "optional-deps.txt")
    optional_observed = set((state / "optional-deps.txt").read_text().splitlines())
    assert optional_desired == optional_observed, "optional dependency manifest drift"

    with (root / "ansible" / "inventory" / "host_vars" / "tpx1c13.yml").open() as handle:
        host_vars = yaml.safe_load(handle)
    system_desired = set(host_vars["system_units_started"] + host_vars["system_units_enabled_only"])
    system_observed = set((state / "system-units-enabled.txt").read_text().splitlines())
    assert system_desired == system_observed, "system unit manifest drift"

    user_desired = set(host_vars["user_units_started"])
    user_observed = set((state / "user-units-enabled.txt").read_text().splitlines())
    assert user_desired == user_observed, "user unit manifest drift"
PY

echo "==> Parsing Lua and JSON configuration"
while IFS= read -r -d '' lua_file; do
  luac -p "$lua_file"
done < <(find home -type f -name '*.lua' -print0)

if [[ -f home/dot_config/waybar/config.jsonc ]]; then
  jq empty home/dot_config/waybar/config.jsonc
fi

echo "==> Checking package manifests"
for manifest in packages/*.txt; do
  invalid=$(sed -E -e 's/[[:space:]]+#.*$//' -e '/^[[:space:]]*(#|$)/d' "$manifest" |
    grep -Ev '^[a-zA-Z0-9@._+:-]+$' || true)
  if [[ -n $invalid ]]; then
    echo "Invalid package entries in $manifest:" >&2
    echo "$invalid" >&2
    exit 1
  fi
done

echo "==> Checking chezmoi source state"
chezmoi --config /dev/null --config-format toml --source "$repo_root" managed >/dev/null
chezmoi --config /dev/null --config-format toml --source "$repo_root" diff >/dev/null
chezmoi --config /dev/null --config-format toml --source "$repo_root" --dry-run apply >/dev/null

echo "==> Looking for accidentally committed key material"
if rg -n --hidden --glob '!.git/**' \
  '(BEGIN (OPENSSH |RSA |EC )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,})' .; then
  echo "Potential credential material found." >&2
  exit 1
fi

if command -v ansible-playbook >/dev/null 2>&1; then
  echo "==> Running Ansible syntax check"
  ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
    ansible-playbook --syntax-check \
    --inventory "$repo_root/ansible/inventory/hosts.yml" \
    "$repo_root/ansible/site.yml"
else
  echo "==> Skipping Ansible syntax check: ansible-playbook is not installed"
fi

if [[ -d .git ]]; then
  git diff --check
fi

echo "Validation completed successfully."
