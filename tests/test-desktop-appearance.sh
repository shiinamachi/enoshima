#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_desktop-appearance
package_tasks=$repo_root/ansible/roles/packages/tasks/main.yml
site_playbook=$repo_root/ansible/site.yml
postflight=$repo_root/scripts/postflight.sh
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'Desktop appearance test failed: %s\n' "$*" >&2
  exit 1
}

mapfile -t accessibility_packages < <(
  sed -E -e 's/[[:space:]]+#.*$//' -e '/^[[:space:]]*(#|$)/d' \
    "$repo_root/packages/accessibility.txt"
)
[[ ${accessibility_packages[*]} == orca ]] ||
  fail 'accessibility package manifest must contain only Orca'
for manifest in packages/native.txt packages/optional-deps.txt; do
  if grep -Fxq orca "$repo_root/$manifest"; then
    fail "Orca leaked into default manifest $manifest"
  fi
done
jq -e '.desktop_accessibility_profile_enabled == false' < <(
  ANSIBLE_CONFIG="$repo_root/ansible/ansible.cfg" ansible-inventory \
    --inventory "$repo_root/ansible/inventory/hosts.yml" --host tpx1c13
) >/dev/null || fail 'physical host Orca opt-in is not boolean false by default'
grep -Fq 'packages/accessibility.txt' "$package_tasks" ||
  fail 'package role does not read the accessibility manifest'
grep -Fq 'if desktop_accessibility_profile_enabled | bool' "$package_tasks" ||
  fail 'accessibility packages are not gated by the opt-in boolean'
grep -Fq 'desktop_accessibility_profile_enabled is boolean' "$site_playbook" ||
  fail 'playbook does not reject non-boolean accessibility profile values'
grep -Fq 'check "opt-in Orca screen reader package installed" pacman -Q orca' \
  "$postflight" || fail 'postflight does not check enabled Orca package state'
grep -Fq 'check "opt-in Orca screen reader executable responds" orca --version' \
  "$postflight" || fail 'postflight does not check the enabled Orca executable'
grep -Fq 'pacman -Ql orca' "$postflight" ||
  fail 'postflight does not discover the packaged Orca desktop entry'
# shellcheck disable=SC2016
grep -Fq 'check "opt-in Orca desktop entry is installed" test -n "$orca_desktop_entry"' \
  "$postflight" ||
  fail 'postflight does not reject a missing Orca desktop entry'
# shellcheck disable=SC2016
grep -Fq 'desktop-file-validate "$orca_desktop_entry"' "$postflight" ||
  fail 'postflight does not validate the packaged Orca desktop entry'
grep -Fq 'vicinae_accessibility_scripts_valid()' "$postflight" ||
  fail 'postflight does not validate the two accessibility Script Commands'
grep -Fq 'desktop_accessibility_profile_enabled is false' "$postflight" ||
  fail 'postflight does not record the disabled Orca skip'

external_contract=$(yq '.external_surfaces["accessibility-screen-reader"]' \
  "$repo_root/docs/ui-surfaces.yaml")
jq -e '
  .implementation == [
    "packages/accessibility.txt",
    "ansible/inventory/group_vars/all.yml",
    "ansible/inventory/host_vars/tpx1c13.yml",
    "ansible/roles/packages/tasks/main.yml",
    "home/dot_config/quickshell/cyberdock/shell.qml",
    "home/dot_local/bin/executable_desktop-appearance",
    "home/dot_local/share/vicinae/scripts/executable_accessibility-appearance.sh",
    "home/dot_local/share/vicinae/scripts/executable_accessibility-default.sh"
  ] and
  .render_owner == "upstream" and
  .tools == ["orca", "vicinae", "gtk3", "gtk4"] and
  .verification.mode == "t5-physical" and
  .verification.gate == "accessibility-screen-reader" and
  .verification.procedure == "docs/DESKTOP-EXPANSION-OPERATIONS.md" and
  .verification.required_displays == ["internal", "external"] and
  (has("concept") | not) and
  (has("evidence") | not)
' <<<"$external_contract" >/dev/null ||
  fail 'accessibility external-surface contract drifted'

for script in \
  home/dot_local/share/vicinae/scripts/executable_accessibility-appearance.sh \
  home/dot_local/share/vicinae/scripts/executable_accessibility-default.sh; do
  grep -Fq '# @vicinae.schemaVersion 1' "$repo_root/$script"
  grep -Fq '# @vicinae.packageName Accessibility' "$repo_root/$script"
  grep -Fq '# @vicinae.mode silent' "$repo_root/$script"
  [[ -x $repo_root/$script ]] ||
    fail "Vicinae accessibility command is not executable: $script"
  if command -v vicinae >/dev/null 2>&1; then
    vicinae script check "$repo_root/$script"
  fi
done
grep -Fxq 'exec desktop-appearance accessible' \
  "$repo_root/home/dot_local/share/vicinae/scripts/executable_accessibility-appearance.sh"
grep -Fxq 'exec desktop-appearance default' \
  "$repo_root/home/dot_local/share/vicinae/scripts/executable_accessibility-default.sh"

mkdir -p "$test_root/bin" "$test_root/home"
log=$test_root/hyprctl.log
appearance_log=$test_root/appearance.log

cat >"$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_HYPRCTL_LOG"
case ${1:-} in
  monitors)
    printf '[]\n'
    ;;
  getoption)
    case ${2:-} in
      plugin:hyprfocus:enable)
        if [[ ${FAKE_PLUGIN_SCHEMA:-legacy} == modern ]]; then
          printf '{"option":"plugin:hyprfocus:enable","bool":true}\n'
        else
          printf 'no such option\n'
        fi
        ;;
      plugin:hyprfocus:mode)
        if [[ ${FAKE_PLUGIN_SCHEMA:-legacy} == legacy ]]; then
          printf '{"option":"plugin:hyprfocus:mode","str":"flash"}\n'
        else
          printf 'no such option\n'
        fi
        ;;
    esac
    ;;
esac
EOF
chmod +x "$test_root/bin/hyprctl"

for command in systemctl gsettings; do
  cat >"$test_root/bin/$command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "$*" >>"$FAKE_APPEARANCE_LOG"
EOF
  chmod +x "$test_root/bin/$command"
done

run_helper() {
  env \
    PATH="$test_root/bin:/usr/bin" \
    HOME="$test_root/home" \
    XDG_STATE_HOME="$test_root/state" \
    FAKE_HYPRCTL_LOG="$log" \
    FAKE_APPEARANCE_LOG="$appearance_log" \
    FAKE_PLUGIN_SCHEMA="${FAKE_PLUGIN_SCHEMA:-legacy}" \
    bash "$helper" "$@"
}

assert_logged() {
  grep -Fxq -- "$1" "$log" || fail "missing hyprctl call: $1"
}

assert_not_logged() {
  if grep -Fxq -- "$1" "$log"; then
    fail "unexpected hyprctl call: $1"
  fi
}

assert_appearance_logged() {
  grep -Fxq -- "$1" "$appearance_log" ||
    fail "missing appearance call: $1"
}

[[ $(run_helper status) == default ]] || fail 'default mode was not reported'

: >"$log"
[[ $(run_helper reduced-motion) == reduced-motion ]] || fail 'reduced-motion failed'
assert_logged reload
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'
assert_not_logged 'eval hl.config({ plugin = { hyprfocus = { enable = false } } })'
assert_not_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'
[[ $(stat -c %a "$test_root/state/desktop-appearance/mode") == 600 ]] ||
  fail 'stored mode is not private'

: >"$log"
[[ $(run_helper reduced-transparency) == reduced-transparency ]] ||
  fail 'reduced-transparency failed'
assert_logged reload
assert_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'
assert_not_logged 'eval hl.config({ animations = { enabled = false } })'

: >"$log"
: >"$appearance_log"
[[ $(run_helper accessible) == accessible ]] || fail 'accessible mode failed'
assert_logged reload
assert_logged 'setcursor capitaine-cursors 48'
assert_appearance_logged 'systemctl --user set-environment XCURSOR_SIZE=48 HYPRCURSOR_SIZE=48'
assert_appearance_logged 'gsettings set org.gnome.desktop.interface cursor-size 48'
assert_appearance_logged 'gsettings set org.gnome.desktop.a11y.interface high-contrast true'
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'
assert_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'

: >"$log"
: >"$appearance_log"
run_helper default >/dev/null
assert_logged reload
assert_logged 'setcursor capitaine-cursors 24'
assert_appearance_logged 'systemctl --user set-environment XCURSOR_SIZE=24 HYPRCURSOR_SIZE=24'
assert_appearance_logged 'gsettings set org.gnome.desktop.interface cursor-size 24'
assert_appearance_logged 'gsettings set org.gnome.desktop.a11y.interface high-contrast false'
assert_not_logged 'eval hl.config({ animations = { enabled = false } })'
assert_not_logged 'eval hl.config({ decoration = { blur = { enabled = false } } })'

: >"$log"
FAKE_PLUGIN_SCHEMA=none run_helper reduced-motion >/dev/null
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_not_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'
assert_not_logged 'eval hl.config({ plugin = { hyprfocus = { enable = false } } })'

: >"$log"
: >"$appearance_log"
FAKE_PLUGIN_SCHEMA=none run_helper apply
assert_not_logged reload
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_logged 'setcursor capitaine-cursors 24'
assert_appearance_logged 'gsettings set org.gnome.desktop.a11y.interface high-contrast false'

: >"$log"
FAKE_PLUGIN_SCHEMA=modern run_helper reduced-motion >/dev/null
assert_logged 'eval hl.config({ animations = { enabled = false } })'
assert_logged 'eval hl.config({ plugin = { hyprfocus = { enable = false } } })'
assert_not_logged 'eval hl.config({ plugin = { hyprfocus = { fade_opacity = 1.0 } } })'

if run_helper unsupported >/dev/null 2>&1; then
  fail 'unsupported mode unexpectedly succeeded'
fi

printf 'Desktop appearance accessibility tests passed.\n'
