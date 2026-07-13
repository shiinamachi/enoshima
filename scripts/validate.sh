#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

mapfile -t shell_scripts < <(
  # Ansible templates contain literal Jinja expressions until rendered. Their
  # rendered shell is checked separately below; feeding the source template to
  # bash or ShellCheck produces false syntax errors around {{ ... }}.
  rg -l --hidden \
    --glob '!.git/**' \
    --glob '!ansible/**/templates/**' \
    '^#!.*\b(bash|sh)\b' . | sort
)

echo "==> Checking shell syntax"
for script in "${shell_scripts[@]}"; do
  bash -n "$script"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${shell_scripts[@]}"
fi

if command -v shfmt >/dev/null 2>&1; then
  shfmt -d -i 2 -ci "${shell_scripts[@]}"
fi

echo "==> Rendering and checking shell templates"
render_dir=$(mktemp -d)
trap 'rm -rf -- "$render_dir"' EXIT

wwan_route_metric=$(
  awk '$1 == "wwan_route_metric:" { print $2; exit }' \
    ansible/inventory/host_vars/tpx1c13.yml
)
[[ $wwan_route_metric =~ ^[0-9]+$ ]] || {
  echo "Invalid or missing wwan_route_metric." >&2
  exit 1
}

while IFS= read -r -d '' template; do
  rendered="$render_dir/$(basename -- "$template" .j2)"

  if command -v ansible >/dev/null 2>&1; then
    # Render through Ansible's real template action. A textual substitution is
    # insufficient because Bash array-length expansion can be parsed as an
    # unterminated Jinja comment before variables are substituted.
    ANSIBLE_BECOME_ASK_PASS=false \
      ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" \
      ansible localhost \
      --inventory 'localhost,' \
      --connection local \
      --module-name ansible.builtin.template \
      --args "src=$template dest=$rendered mode=0600" \
      --extra-vars "wwan_route_metric=$wwan_route_metric ansible_become=false" \
      >/dev/null
  else
    if rg -n '\{#' "$template"; then
      echo "Cannot safely render a Jinja comment without Ansible: $template" >&2
      exit 1
    fi
    sed -E \
      "s/\{\{[[:space:]]*wwan_route_metric[[:space:]]*\}\}/$wwan_route_metric/g" \
      "$template" >"$rendered"
  fi

  if rg -n '\{\{|\{%' "$rendered"; then
    echo "Unrendered Jinja expression in shell template: $template" >&2
    exit 1
  fi

  bash -n "$rendered"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$rendered"
  fi
  if command -v shfmt >/dev/null 2>&1; then
    shfmt -d -i 2 -ci "$rendered"
  fi
done < <(
  rg -l --null --glob '*.j2' '^#!.*\b(bash|sh)\b' ansible/roles | sort -z
)

echo "==> Parsing YAML and checking desired-state invariants"
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
    if not path.exists():
        return set()
    result: set[str] = set()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line:
            if line in result:
                raise AssertionError(f"duplicate manifest entry in {path}: {line}")
            result.add(line)
    return result


native = manifest(root / "packages" / "native.txt")
management = manifest(root / "packages" / "management.txt")
optional = manifest(root / "packages" / "optional-deps.txt")
absent = manifest(root / "packages" / "absent.txt")
aur = manifest(root / "packages" / "aur.txt")

present = native | management | optional
assert not (present & absent), (
    "packages cannot be both present and absent: "
    + ", ".join(sorted(present & absent))
)

local_package_names = {
    path.parent.name
    for path in (root / "packages" / "local").glob("*/PKGBUILD")
}
assert not (aur & local_package_names), (
    "packages cannot be managed by both AUR and local PKGBUILD: "
    + ", ".join(sorted(aur & local_package_names))
)

# state/ is an immutable observation. Intentional desired-state changes must not
# be rejected merely because they differ from the original capture.
state = root / "state" / "tpx1c13"
if state.exists():
    for required in (
        "native-explicit.txt",
        "foreign-explicit.txt",
        "system-units-enabled.txt",
        "user-units-enabled.txt",
    ):
        assert (state / required).is_file(), f"missing observed-state file: {required}"
PY

echo "==> Parsing Lua and JSON configuration"
while IFS= read -r -d '' lua_file; do
  luac -p "$lua_file"
done < <(find home -type f -name '*.lua' -print0)

if command -v Hyprland >/dev/null 2>&1; then
  Hyprland --verify-config -c home/dot_config/hypr/hyprland.lua
else
  echo "==> Skipping Hyprland semantic validation: Hyprland is not installed"
fi

while IFS= read -r -d '' json_file; do
  jq empty "$json_file"
done < <(find home -type f -name '*.json' -print0)

if [[ -f home/dot_config/waybar/config.jsonc ]]; then
  jq empty home/dot_config/waybar/config.jsonc
fi

echo "==> Checking package manifests and local PKGBUILDs"
for manifest in packages/*.txt; do
  invalid=$(sed -E -e 's/[[:space:]]+#.*$//' -e '/^[[:space:]]*(#|$)/d' "$manifest" |
    grep -Ev '^[a-zA-Z0-9@._+:-]+$' || true)
  if [[ -n $invalid ]]; then
    echo "Invalid package entries in $manifest:" >&2
    echo "$invalid" >&2
    exit 1
  fi
done

while IFS= read -r -d '' pkgbuild; do
  bash -n "$pkgbuild"
  (
    cd "$(dirname -- "$pkgbuild")"
    makepkg --printsrcinfo >/dev/null
  )
done < <(find packages/local -type f -name PKGBUILD -print0 2>/dev/null)

if command -v desktop-file-validate >/dev/null 2>&1; then
  while IFS= read -r -d '' desktop_file; do
    desktop-file-validate "$desktop_file"
  done < <(find home -type f -name '*.desktop' -print0)
fi

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
