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
/usr/bin/python - "$repo_root" <<'PY'
from pathlib import Path
import json
import re
import sys
import tomllib
import xml.etree.ElementTree as ET
import yaml

root = Path(sys.argv[1])
yaml_paths = set(root.rglob("*.yml")) | set(root.rglob("*.yaml"))
for path in sorted(yaml_paths):
    if ".git" in path.parts or ".venv" in path.parts:
        continue
    with path.open("r", encoding="utf-8") as handle:
        yaml.safe_load(handle)
    print(path.relative_to(root))

ET.parse(
    root
    / "ansible"
    / "roles"
    / "desktop_expansion"
    / "templates"
    / "60-desktop-fonts.conf.j2"
)


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
vm_host = manifest(root / "packages" / "vm-host.txt")
optional = manifest(root / "packages" / "optional-deps.txt")
absent = manifest(root / "packages" / "absent.txt")
aur = manifest(root / "packages" / "aur.txt")

for package in aur:
    assert re.fullmatch(r"[a-z0-9@._+-]+", package), (
        f"invalid AUR package base in approval manifest: {package}"
    )

pacman_desired = native | management | vm_host | optional
local_package_names = {
    path.parent.name
    for path in (root / "packages" / "local").glob("*/PKGBUILD")
}
all_desired = pacman_desired | aur | local_package_names
assert not (all_desired & absent), (
    "packages cannot be both desired and absent: "
    + ", ".join(sorted(all_desired & absent))
)
assert not (pacman_desired & local_package_names), (
    "packages cannot be managed by both native manifests and local PKGBUILD: "
    + ", ".join(sorted(pacman_desired & local_package_names))
)
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

group_vars = yaml.safe_load(
    (root / "ansible/inventory/group_vars/all.yml").read_text(encoding="utf-8")
)
required_capabilities = set(group_vars["enoshima_required_capabilities"])
inventory = yaml.safe_load(
    (root / "ansible/inventory/hosts.yml").read_text(encoding="utf-8")
)
for host in inventory["all"]["hosts"]:
    host_vars = yaml.safe_load(
        (root / f"ansible/inventory/host_vars/{host}.yml").read_text(
            encoding="utf-8"
        )
    )
    capabilities = host_vars["enoshima_capabilities"]
    assert set(capabilities) == required_capabilities, (
        f"{host} capability keys do not match the inventory contract"
    )
    assert all(isinstance(value, bool) for value in capabilities.values()), (
        f"{host} capabilities must be explicit booleans"
    )

with (root / ".codex/config.toml").open("rb") as handle:
    codex_config = tomllib.load(handle)
vm_mcp = codex_config["mcp_servers"]["enoshima_vm"]
assert vm_mcp["command"] == "uv"
assert vm_mcp["default_tools_approval_mode"] == "writes"
assert vm_mcp["tools"]["vm_destroy"]["approval_mode"] == "prompt"
PY

if command -v actionlint >/dev/null 2>&1; then
  echo "==> Checking GitHub Actions workflows"
  actionlint
fi

echo "==> Checking repository-local design skills"
/usr/bin/python - "$repo_root" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
skills_root = root / ".agents" / "skills"
sources_path = skills_root / "sources.json"

expected = {
    "design-taste-frontend": {
        "repository": "https://github.com/Leonxlnx/taste-skill",
        "commit": "b17742737e796305d829b3ad39eda3add0d79060",
        "source_tree": "a6d128e53b4ec0238baee751dde33bf707adb5ec",
        "source_skill_sha256": (
            "aa194351b246b8b4799099d4ed7b033d29eab6e6e3d58d8d2172978be7b3ec89"
        ),
    },
    "ui-ux-pro-max": {
        "repository": "https://github.com/nextlevelbuilder/ui-ux-pro-max-skill",
        "commit": "f8ac5e1266dba8354ea96e19994d9f4345e7ec31",
        "source_tree": "e36b015761c3bd5e2b6977323db9b105b4cd8d5f",
        "source_skill_sha256": (
            "305a7527fcb2f5b6e4129ab22cd839b5172d26df7f14d3324bfdec8fc1763560"
        ),
    },
}
repository_owned = {"enoshima-concept-art"}

sources = json.loads(sources_path.read_text(encoding="utf-8"))
assert sources["schema"] == 1
assert sources["reviewed_at"] == "2026-07-15"
source_by_name = {entry["name"]: entry for entry in sources["skills"]}
assert set(source_by_name) == set(expected)

active_skill_files = sorted(skills_root.glob("*/SKILL.md"))
assert [path.parent.name for path in active_skill_files] == sorted(
    set(expected) | repository_owned
)
assert sorted(skills_root.rglob("SKILL.md")) == active_skill_files, (
    "nested active skill found"
)

for name, source_expectation in expected.items():
    skill_dir = skills_root / name
    skill_path = skill_dir / "SKILL.md"
    raw_skill = skill_path.read_text(encoding="utf-8")
    assert raw_skill.startswith("---\n")
    _, frontmatter_text, body = raw_skill.split("---", 2)
    frontmatter = yaml.safe_load(frontmatter_text)
    assert frontmatter["name"] == name
    assert isinstance(frontmatter["description"], str)
    assert frontmatter["description"].strip()
    assert body.strip()

    metadata = yaml.safe_load(
        (skill_dir / "agents" / "openai.yaml").read_text(encoding="utf-8")
    )
    interface = metadata["interface"]
    assert interface["display_name"].strip()
    assert 25 <= len(interface["short_description"]) <= 64
    assert f"${name}" in interface["default_prompt"]
    assert (skill_dir / "LICENSE").read_text(encoding="utf-8").startswith(
        "MIT License\n"
    )

    source = source_by_name[name]
    for key, value in source_expectation.items():
        assert source[key] == value
    assert source["license"] == "MIT"

for path in skills_root.rglob("*"):
    assert not path.is_symlink(), f"repository design skill must not be a symlink: {path}"

taste_reference = (
    skills_root
    / "design-taste-frontend"
    / "references"
    / "taste-skill-v2.md"
)
reference_prefix = (
    "<!-- Vendored upstream reference; project-specific routing lives in "
    "../SKILL.md. -->\n\n"
)
reference_text = taste_reference.read_text(encoding="utf-8")
assert reference_text.startswith(reference_prefix)
reference_hash = sha256(reference_text[len(reference_prefix) :].encode()).hexdigest()
assert reference_hash == expected["design-taste-frontend"]["source_skill_sha256"]

ui_skill = (skills_root / "ui-ux-pro-max" / "SKILL.md").read_text(encoding="utf-8")
assert "CLAUDE_PLUGIN_ROOT" not in ui_skill
assert ".agents/skills/ui-ux-pro-max/scripts/search.py" in ui_skill
assert "Do not pass `--persist`" in ui_skill

concept_skill_dir = skills_root / "enoshima-concept-art"
concept_skill = (concept_skill_dir / "SKILL.md").read_text(encoding="utf-8")
_, concept_frontmatter_text, concept_body = concept_skill.split("---", 2)
concept_frontmatter = yaml.safe_load(concept_frontmatter_text)
assert concept_frontmatter["name"] == "enoshima-concept-art"
assert "docs/ui-surfaces.yaml" in concept_body
concept_interface = yaml.safe_load(
    (concept_skill_dir / "agents" / "openai.yaml").read_text(encoding="utf-8")
)["interface"]
assert 25 <= len(concept_interface["short_description"]) <= 64
assert "$enoshima-concept-art" in concept_interface["default_prompt"]
for required in (
    "references/visual-language.md",
    "references/prompt-template.md",
    "references/surface-checklist.md",
    "scripts/validate-concept-manifest",
):
    assert (concept_skill_dir / required).is_file(), required
PY

echo "==> Checking UI concept coverage"
"$repo_root/scripts/check-ui-concept-coverage"
"$repo_root/scripts/check-auth-theme"

PYTHONDONTWRITEBYTECODE=1 /usr/bin/python \
  .agents/skills/ui-ux-pro-max/scripts/validate_data.py
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python -m unittest discover \
  -s .agents/skills/ui-ux-pro-max/scripts/tests
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python \
  .agents/skills/ui-ux-pro-max/scripts/search.py \
  "desktop shell keyboard focus reduced motion contrast" \
  --domain ux -n 1 >/dev/null

echo "==> Parsing Lua and JSON configuration"
while IFS= read -r -d '' lua_file; do
  luac -p "$lua_file"
done < <(find home -type f -name '*.lua' -print0)

hyprland_command=$(command -v Hyprland || command -v hyprland || true)
if [[ -n $hyprland_command ]]; then
  env -u HYPRLAND_INSTANCE_SIGNATURE \
    "$hyprland_command" --verify-config -c home/dot_config/hypr/hyprland.lua
else
  echo "==> Skipping Hyprland semantic validation: Hyprland is not installed"
fi

while IFS= read -r -d '' json_file; do
  jq empty "$json_file"
done < <(find home -type f -name '*.json' -print0)

if [[ -f home/dot_config/waybar/config.jsonc ]]; then
  jq empty home/dot_config/waybar/config.jsonc
fi

if command -v ghostty >/dev/null 2>&1; then
  ghostty +validate-config \
    --config-file="$repo_root/home/dot_config/ghostty/config.ghostty"
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

if git ls-files tests/vm | rg -q '\.(qcow2|iso)$'; then
  echo "Disposable VM media must not be tracked under tests/vm." >&2
  exit 1
fi

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

echo "==> Checking managed Git configuration"
git_config=$repo_root/home/dot_gitconfig
git config --file "$git_config" --list >/dev/null
mapfile -t managed_git_credential_helpers < <(
  git config --file "$git_config" --get-all credential.helper || true
)
if ((${#managed_git_credential_helpers[@]} != 1)) ||
  [[ ${managed_git_credential_helpers[0]:-} != store ]]; then
  echo "home/dot_gitconfig must define credential.helper exactly once as store" >&2
  exit 1
fi

tracked_git_credential_files=$(
  git ls-files |
    rg '^home/([^/]*dot_git-credentials|.*/git/[^/]*credentials)$' || true
)
if [[ -n $tracked_git_credential_files ]]; then
  echo "Plaintext Git credential stores must not be tracked:" >&2
  printf '%s\n' "$tracked_git_credential_files" >&2
  exit 1
fi

echo "==> Checking chezmoi source state"
chezmoi_validation_home="$render_dir/chezmoi-home"
mkdir -- "$chezmoi_validation_home"
chezmoi_validation_args=(
  --config /dev/null
  --config-format toml
  --source "$repo_root"
  --destination "$chezmoi_validation_home"
  --persistent-state "$render_dir/chezmoi-state.boltdb"
  --no-tty
)
chezmoi "${chezmoi_validation_args[@]}" managed >/dev/null
chezmoi "${chezmoi_validation_args[@]}" diff >/dev/null
chezmoi "${chezmoi_validation_args[@]}" --force --dry-run apply >/dev/null

echo "==> Testing dotfile conflict policies"
"$repo_root/tests/test-apply-dotfiles.sh"

echo "==> Testing single-authentication sudo wrapper"
"$repo_root/tests/test-sudo-wrapper.sh"

echo "==> Testing non-interactive bootstrap behavior"
"$repo_root/tests/test-bootstrap-noninteractive.sh"
"$repo_root/tests/test-bootstrap-failure-continuation.sh"
"$repo_root/tests/test-codex-desktop-install.sh"

echo "==> Testing desktop expansion behavior"
for test_script in \
  tests/test-bootstrap-desktop-expansion.sh \
  tests/test-audio-output-control.sh \
  tests/test-aur-desktop-apps.sh \
  tests/test-aur-allowlist.sh \
  tests/test-cyberpunk-library-theme.sh \
  tests/test-cyberdock-pins.sh \
  tests/test-cyberdock-state.sh \
  tests/test-desktop-display-mode.sh \
  tests/test-desktop-power.sh \
  tests/test-power-doctor.sh \
  tests/test-power-policy.sh \
  tests/test-transactional-uki.sh \
  tests/test-ui-evidence-gate.sh \
  tests/test-vm-boot-security.sh \
  tests/test-vm-ci.sh \
  tests/test-vm-desktop.sh \
  tests/test-vm-profile.sh \
  tests/test-wwan-shutdown.sh \
  tests/test-desktop-window-action.sh \
  tests/test-enoshima-snap-controller.sh \
  tests/test-enoshima-decoration.sh \
  tests/test-window-decoration-policy.sh \
  tests/test-hypr-mouse-binds.sh \
  tests/test-hyprlock-responsive.sh \
  tests/test-desktop-shell-helpers.sh \
  tests/test-desktop-appearance.sh \
  tests/test-desktop-scaling-status.sh \
  tests/test-graphics-workflow.sh \
  tests/test-kakaotalk-connectivity.sh \
  tests/test-kakaotalk-desktop-integration.sh \
  tests/test-kakaotalk-profile.sh \
  tests/test-login-manager.sh \
  tests/test-mise-runtimes.sh \
  tests/test-rclone-user-units.sh \
  tests/test-swaync-quick-setting.sh \
  tests/test-zsh-shell.sh \
  tests/test-workspace-output-route.sh; do
  "$repo_root/$test_script"
done

echo "==> Checking desktop expansion QML and user units"
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  /usr/lib/qt6/bin/qmllint --max-warnings 0 \
    home/dot_config/quickshell/cyberdock/shell.qml \
    home/dot_config/quickshell/cyberdock/DisplayModeOverlay.qml \
    home/dot_config/quickshell/cyberdock/PowerMenu.qml \
    home/dot_config/quickshell/cyberdock/FocusSentinel.qml \
    home/dot_config/quickshell/cyberdock/CyberLauncher.qml \
    home/dot_config/quickshell/cyberdock/CyberOsd.qml \
    home/dot_config/quickshell/cyberdock/EnoshimaWindowMenu.qml \
    home/dot_config/quickshell/cyberdock/EnoshimaSnapAssist.qml
  /usr/lib/qt6/bin/qmllint --max-warnings 0 \
    ansible/roles/desktop_expansion/files/sddm-cyberpunk/Main.qml
else
  echo "==> Skipping QML lint: Qt 6 qmllint is not installed yet"
fi
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate packages/local/rhwp-desktop/rhwp-desktop.desktop
fi
if command -v systemd-analyze >/dev/null 2>&1; then
  unit_dir=$render_dir/desktop-expansion-units
  mkdir -- "$unit_dir"
  for unit in \
    home/dot_config/systemd/user/enoshima-windowd.service \
    home/dot_config/systemd/user/cyberdock.service \
    home/dot_config/systemd/user/cyberdock-event-bridge.service \
    home/dot_config/systemd/user/desktop-display-events.service \
    home/dot_config/systemd/user/desktop-display-revert.service \
    home/dot_config/systemd/user/desktop-display-revert.timer \
    home/dot_config/systemd/user/desktop-power-verify.service \
    home/dot_config/systemd/user/hyprsunset-quick.service \
    home/dot_config/systemd/user/kakaotalk-focus-guard.service \
    home/dot_config/systemd/user/protonmail-bridge.service \
    home/dot_config/systemd/user/rclone-google-drive.service \
    home/dot_config/systemd/user/rclone-proton-drive.service; do
    sed -E \
      's#^(Exec(Start|Stop)(Pre|Post)?=).*#\1/usr/bin/true#' \
      "$unit" >"$unit_dir/$(basename -- "$unit")"
  done
  systemd-analyze --user verify "$unit_dir"/*.service
fi

echo "==> Checking desktop expansion security invariants"
for package in \
  adw-gtk-theme capitaine-cursors fcitx5-material-color fuse3 gimp hyprpwcenter libsecret \
  nwg-displays protonmail-bridge quickshell rclone socat thunderbird \
  ttf-caladea ttf-carlito ttf-liberation wev; do
  grep -Fxq -- "$package" packages/native.txt
done
for package in cloudflare-warp-bin onlyoffice-bin photogimp; do
  grep -Fxq -- "$package" packages/aur.txt
done
for package in rhwp-desktop ttf-jetendard; do
  test -f "packages/local/$package/PKGBUILD"
done
test ! -e packages/local/protonmail-bridge
grep -Fq 'ansible.builtin.import_tasks: rhwp.yml' \
  ansible/roles/desktop_expansion/tasks/main.yml
grep -Fq "['/opt/rhwp-desktop']" \
  ansible/roles/desktop_expansion/tasks/rhwp.yml
grep -Fq 'mode: "0755"' \
  ansible/roles/desktop_expansion/tasks/rhwp.yml
for directive in \
  'ExecStart=/usr/bin/protonmail-bridge-core --noninteractive' \
  'KillMode=process' \
  'PrivateTmp=true' \
  'ProtectSystem=full' \
  'NoNewPrivileges=true' \
  'ProtectControlGroups=true' \
  'ProtectKernelTunables=true' \
  'RestrictNamespaces=true' \
  'RestrictRealtime=true' \
  'SystemCallArchitectures=native'; do
  grep -Fxq "$directive" home/dot_config/systemd/user/protonmail-bridge.service
done

grep -Fq 'dest: /etc/fonts/conf.d/60-desktop-fonts.conf' \
  ansible/roles/desktop_expansion/tasks/fonts.yml
grep -Fq 'path: /etc/fonts/conf.d/60-jetendard.conf' \
  ansible/roles/desktop_expansion/tasks/fonts.yml
if grep -Fq '/etc/fonts/conf.avail' \
  ansible/roles/desktop_expansion/tasks/fonts.yml; then
  echo "Desktop expansion targets a non-existent Arch fontconfig directory." >&2
  exit 1
fi

desktop_fontconfig=ansible/roles/desktop_expansion/templates/60-desktop-fonts.conf.j2
grep -Fq '<string>Pretendard</string>' "$desktop_fontconfig"
grep -Fq '<string>Jetendard</string>' "$desktop_fontconfig"
if [[ $(grep -Fc 'mode="prepend_first" binding="strong"' "$desktop_fontconfig") -ne 2 ]]; then
  echo "Desktop font preferences must strongly prepend both primary families." >&2
  exit 1
fi
grep -Fq 'upstream/pretendard/Pretendard-*.ttf' \
  packages/local/ttf-jetendard/PKGBUILD
grep -Fq 'PRETENDARD-LICENSE' packages/local/ttf-jetendard/PKGBUILD

for ui_font_config in \
  home/.chezmoitemplates/dconf-interface.ini \
  home/dot_config/hypr/hyprlock.conf \
  home/dot_config/hypr/hyprtoolkit.conf \
  home/dot_config/quickshell/cyberdock/shell.qml \
  home/dot_config/swaync/style.css \
  home/dot_config/waybar/style.css \
  home/dot_config/zed/settings.json; do
  grep -Fq 'Pretendard' "$ui_font_config"
done
grep -Fq 'font-family = Jetendard' home/dot_config/ghostty/config.ghostty
grep -Fq '"buffer_font_family": "Jetendard"' home/dot_config/zed/settings.json

wallpaper_source_sha=406e63f4806eeff1c9644b16b7efe220bddfb5a068f9db0a27fa8090651d6c0c
printf '%s  %s\n' \
  "$wallpaper_source_sha" \
  home/dot_local/share/backgrounds/cyberpunk-city.png | sha256sum --check --status

grep -Fq 'sha256:94295aa3fe74ee505d115936edd5b8df7e5293a205e244be4301a31725bfdeb7' \
  docs/DESKTOP-EXPANSION.md
grep -Fq "'94295aa3fe74ee505d115936edd5b8df7e5293a205e244be4301a31725bfdeb7'" \
  packages/local/rhwp-desktop/PKGBUILD
grep -Fq "find \"\$pkgdir/opt/rhwp-desktop\" -type d -exec chmod 0755" \
  packages/local/rhwp-desktop/PKGBUILD
grep -Fq 'chmod 4755 ' packages/local/rhwp-desktop/PKGBUILD
if awk '!/^[[:space:]]*#/' packages/local/rhwp-desktop/rhwp-desktop.sh |
  grep -Fq -- '--no-sandbox'; then
  echo "RHWP launcher contains an unsafe sandbox bypass." >&2
  exit 1
fi

for required_flag in \
  '--vfs-cache-mode full' \
  '--vfs-cache-max-size 50Gi' \
  '--vfs-write-back 15m' \
  '--vfs-cache-min-free-space 5Gi' \
  '--protondrive-enable-caching=false'; do
  grep -Fq -- "$required_flag" home/dot_local/bin/executable_rclone-cloud-mount
done
if grep -Fq -- '--allow-other' home/dot_local/bin/executable_rclone-cloud-mount; then
  echo "rclone mount unexpectedly enables cross-user access." >&2
  exit 1
fi

if rg -n \
  '(1\.1\.1\.1|1\.0\.0\.1|2606:4700:4700|2606:4700:4700::1111)' \
  ansible/roles/desktop_expansion/tasks/cloudflare.yml \
  home/dot_local/bin/executable_cloudflare-one-{setup,status}; then
  echo "Cloudflare integration hard-codes a DNS address." >&2
  exit 1
fi

if git ls-files | rg -q \
  '(^|/)(rclone\.conf|prefs\.js|key4\.db|logins\.json|drive_c|Cookies)(/|$)'; then
  echo "A mutable account/profile artifact is tracked by Git." >&2
  exit 1
fi

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

mise_config=$repo_root/home/dot_config/mise/config.toml
if command -v mise >/dev/null 2>&1 &&
  MISE_CONFIG_FILE="$mise_config" mise which uv >/dev/null 2>&1; then
  echo "==> Running VM harness unit and lint checks"
  MISE_CONFIG_FILE="$mise_config" mise exec -- \
    uv lock --check --project tests/vm
  MISE_CONFIG_FILE="$mise_config" mise exec -- \
    uv run --locked --project tests/vm pytest
  MISE_CONFIG_FILE="$mise_config" mise exec -- \
    uv run --locked --project tests/vm ruff check tests/vm/src tests/vm/unit
else
  echo "==> Skipping VM harness checks: the managed uv runtime is not installed"
fi

if [[ -d .git ]]; then
  git diff --check
fi

echo "Validation completed successfully."
