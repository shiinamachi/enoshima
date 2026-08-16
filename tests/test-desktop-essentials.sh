#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
# shellcheck source=../scripts/lib/vicinae-service-policy.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/vicinae-service-policy.sh"

for package in \
  gst-plugins-ugly \
  hyprpicker \
  hyprshot \
  kooha \
  xdg-desktop-portal-gtk \
  xdg-desktop-portal-hyprland; do
  grep -Fxq -- "$package" packages/native.txt
done
grep -Fxq -- desktop-file-utils packages/native.txt
if grep -Fxq -- hyprshell-bin packages/aur.txt; then
  echo 'Hyprshell must use the repository-pinned local source package.' >&2
  exit 1
fi
if grep -Fxq -- vicinae-bin packages/aur.txt; then
  echo 'Vicinae must use the repository-pinned local source package.' >&2
  exit 1
fi
if grep -Eq '^(hyprshell|vicinae)(-git)?$' packages/aur.txt; then
  echo 'Desktop essentials must not use unreviewed or prerelease AUR variants.' >&2
  exit 1
fi
grep -Fxq -- vicinae-bin-debug packages/absent.txt
grep -Fxq -- hyprshell-bin-debug packages/absent.txt

hyprshell_package_dir=packages/local/hyprshell-bin
grep -Fxq 'pkgver=4.10.8' "$hyprshell_package_dir/PKGBUILD"
grep -Fxq 'pkgrel=3' "$hyprshell_package_dir/PKGBUILD"
grep -Fxq '_commit=61ddaa30563c1f091ca5fbe5d7203c19f42b519c' \
  "$hyprshell_package_dir/PKGBUILD"
grep -Fxq "options=('!debug' '!lto')" "$hyprshell_package_dir/PKGBUILD"
grep -Fxq '  export CARGO_BUILD_JOBS=1' "$hyprshell_package_dir/PKGBUILD"
grep -Fxq '  export CARGO_PROFILE_RELEASE_LTO=false' \
  "$hyprshell_package_dir/PKGBUILD"
grep -Fxq '  export CARGO_PROFILE_RELEASE_DEBUG=0' \
  "$hyprshell_package_dir/PKGBUILD"
grep -Fxq '  export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=64' \
  "$hyprshell_package_dir/PKGBUILD"
grep -Fq 'EventControllerKey::new()' \
  "$hyprshell_package_dir/overview-direct-input.patch"
grep -Fq 'uses_direct_overview_input' \
  "$hyprshell_package_dir/overview-direct-input.patch"
grep -Fq 'HYPRSHELL_NO_LISTENERS' \
  "$hyprshell_package_dir/overview-direct-input.patch"

vicinae_package_dir=packages/local/vicinae-bin
grep -Fxq 'pkgver=0.25.0' "$vicinae_package_dir/PKGBUILD"
grep -Fxq 'pkgrel=10' "$vicinae_package_dir/PKGBUILD"
grep -Fxq "options=('!debug' '!lto')" "$vicinae_package_dir/PKGBUILD"
grep -Fq -- '-DQT_QML_NO_CACHEGEN=ON' "$vicinae_package_dir/PKGBUILD"
grep -Fq -- '-DVICINAE_PROVENANCE=arch_source' "$vicinae_package_dir/PKGBUILD"
grep -Fq 'qt_build_snapshot()' "$vicinae_package_dir/PKGBUILD"
grep -Fq 'schemaVersion: 2' "$vicinae_package_dir/PKGBUILD"
# shellcheck disable=SC2016
grep -Fq '"$pkgdir/usr/libexec/vicinae"' "$vicinae_package_dir/PKGBUILD"
grep -Fq 'install -Dm644 vicinae.desktop vicinae-url-handler.desktop' \
  "$vicinae_package_dir/PKGBUILD"
# shellcheck disable=SC2016
grep -Fq '"$pkgdir/usr/share/licenses/vicinae-bin/LICENSE"' \
  "$vicinae_package_dir/PKGBUILD"
if grep -Fq -- '--appimage-extract' "$vicinae_package_dir/PKGBUILD"; then
  echo 'Vicinae packaging must not retain an AppImage extraction path.' >&2
  exit 1
fi
grep -Fq 'Environment=VICINAE_NODE_BIN=/usr/bin/node HOME=%h XDG_CONFIG_HOME=%h/.config XDG_DATA_HOME=%h/.local/share XDG_STATE_HOME=%h/.local/state XDG_CACHE_HOME=%h/.cache' \
  home/dot_config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf
grep -Fq 'UnsetEnvironment=QT_NO_GLIB LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT' \
  home/dot_config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf
[[ ! -e $vicinae_package_dir/vicinae-bin.install ]]
scripts/check-vicinae-provenance

vicinae_desktop=$vicinae_package_dir/vicinae.desktop
vicinae_uri_desktop=$vicinae_package_dir/vicinae-url-handler.desktop
desktop-file-validate "$vicinae_desktop" "$vicinae_uri_desktop"
grep -Fxq 'Exec=vicinae-control toggle' "$vicinae_desktop"
grep -Fxq 'TryExec=vicinae-control' "$vicinae_desktop"
grep -Fxq 'Exec=vicinae-control uri %u' "$vicinae_uri_desktop"
grep -Fxq 'TryExec=vicinae-control' "$vicinae_uri_desktop"
grep -Fxq 'NoDisplay=true' "$vicinae_uri_desktop"
grep -Fxq \
  'MimeType=x-scheme-handler/vicinae;x-scheme-handler/raycast;x-scheme-handler/com.raycast;' \
  "$vicinae_uri_desktop"
if grep -Fq 'server --replace' "$vicinae_desktop" "$vicinae_uri_desktop"; then
  echo 'Managed Vicinae desktop entries must not launch the server directly.' >&2
  exit 1
fi
for section_value in \
  'x-scheme-handler/vicinae=vicinae-url-handler.desktop' \
  'x-scheme-handler/raycast=vicinae-url-handler.desktop' \
  'x-scheme-handler/com.raycast=vicinae-url-handler.desktop'; do
  [[ $(grep -Fxc "$section_value" home/dot_config/mimeapps.list) == 1 ]]
  [[ $(grep -Fxc "$section_value;" home/dot_config/mimeapps.list) == 1 ]]
done

vicinae_hook=$vicinae_package_dir/vicinae.hook
grep -Fq -- '/usr/bin/timeout --signal=TERM --kill-after=5s 90s' "$vicinae_hook"
grep -Fq -- '/usr/libexec/vicinae/vicinae-qt-guard release-if-compatible' \
  "$vicinae_hook"
grep -Fq 'Target = usr/lib/libQt6*.so.6' \
  "$vicinae_package_dir/40-vicinae-qt-pre.hook"
grep -Fq 'AbortOnFail' "$vicinae_package_dir/41-vicinae-package-pre.hook"

hyprland=home/dot_config/hypr/hyprland.lua
for binding in \
  'hyprshot -m output -m active' \
  'hyprshot -m window' \
  'hyprshot -m region --freeze' \
  'swappy -f -' \
  'hyprpicker -a' \
  'uwsm app -- kooha' \
  'vicinae-control toggle' \
  "vicinae-control deeplink 'vicinae://launch/clipboard/history?toggle=true'" \
  "vicinae-control deeplink 'vicinae://launch/core/search-emojis?toggle=true'"; do
  grep -Fq -- "$binding" "$hyprland"
done
grep -Fq 'hl.env("HYPRSHOT_DIR", home .. "/Pictures/Screenshots")' "$hyprland"
grep -Fxq '[Default]' home/dot_config/swappy/config
# shellcheck disable=SC2016
grep -Fxq 'save_dir=$HOME/Pictures/Screenshots' home/dot_config/swappy/config
grep -Fxq 'save_filename_format=Screenshot_%Y-%m-%d_%H-%M-%S.png' \
  home/dot_config/swappy/config
grep -Fq 'hl.bind(mainMod .. " + SPACE"' "$hyprland"
grep -Fq 'hl.bind(mainMod .. " + R"' "$hyprland"
if grep -Fxq wf-recorder packages/native.txt; then
  echo 'Kooha must remain the sole managed screen-recording frontend.' >&2
  exit 1
fi

external_contract=$(
  yq '.external_surfaces["desktop-capture-recording"]' docs/ui-surfaces.yaml
)
jq -e '
  .implementation == [
    "home/dot_config/hypr/hyprland.lua",
    "home/dot_config/swappy/config",
    "home/dot_config/xdg-desktop-portal/hyprland-portals.conf"
  ] and
  .render_owner == "upstream" and
  .tools == [
    "hyprshot", "slurp", "grim", "swappy", "hyprpicker", "kooha",
    "xdg-desktop-portal-hyprland"
  ] and
  .verification.mode == "t5-physical" and
  .verification.gate == "desktop-capture-recording" and
  .verification.procedure == "docs/DESKTOP-EXPANSION-OPERATIONS.md" and
  .verification.required_displays == ["internal", "external"] and
  (has("concept") | not) and
  (has("evidence") | not)
' <<<"$external_contract" >/dev/null

hyprshell_config=home/dot_config/hyprshell/config.ron
hyprshell_css=home/dot_config/hyprshell/styles.css
hyprshell_dropin=home/dot_config/systemd/user/hyprshell.service.d/60-enoshima-stable.conf
grep -Fq 'items_per_row: 3' "$hyprshell_config"
grep -Fq 'scale: 11.6' "$hyprshell_config"
grep -Fq 'version: 4' "$hyprshell_config"
grep -Fq 'top_offset: 48' "$hyprshell_config"
grep -Fq 'width: 1' "$hyprshell_config"
grep -Fq 'max_items: 1' "$hyprshell_config"
grep -Fq 'show_when_empty: false' "$hyprshell_config"
grep -Fq 'windows: (' "$hyprshell_config"
grep -Fq 'overview: (' "$hyprshell_config"
if grep -Eq '(windows|overview):[[:space:]]*Some\(' "$hyprshell_config"; then
  echo 'Hyprshell config must use the stable parser implicit-Some syntax.' >&2
  exit 1
fi
grep -Fq 'key: "Tab"' "$hyprshell_config"
grep -Fq 'modifier: "super"' "$hyprshell_config"
grep -Fq 'filter_by: []' "$hyprshell_config"
grep -Fq 'exclude_workspaces: "special:.*"' "$hyprshell_config"
grep -Fq 'switch: None' "$hyprshell_config"
grep -Fq 'switch_2: None' "$hyprshell_config"
/usr/bin/python - "$hyprshell_config" <<'PY'
import math
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?m)^\s*scale:\s*([0-9]+(?:\.[0-9]+)?),\s*$", text)
if match is None:
    raise SystemExit("Hyprshell overview scale is missing")
scale = float(match.group(1))
if not scale < 15:
    raise SystemExit("Hyprshell overview scale must remain below its divisor")
card_width = math.floor(1280 / (15 - scale))
group_width = 3 * (card_width + 12) + 20
if group_width > 1184:
    raise SystemExit(
        f"Hyprshell overview group is {group_width}px; 48px side margins require <=1184px"
    )
PY
for plugin in applications terminal shell websearch calc path actions; do
  grep -Fq -- "$plugin: None" "$hyprshell_config"
done
grep -Fq '.workspace.active' "$hyprshell_css"
grep -Fq '.client.active' "$hyprshell_css"
if grep -Eq '\.window \.launcher|\.launcher-input|caret-color' "$hyprshell_css"; then
  echo 'Hyprshell direct-input overview must not retain a hidden launcher surface.' >&2
  exit 1
fi
grep -Fxq 'UnsetEnvironment=HYPRSHELL_EXPERIMENTAL' "$hyprshell_dropin"
if grep -Eq \
  'animation:[[:space:]]|transition:[[:space:]]|backdrop-filter|filter:[[:space:]]*blur' \
  "$hyprshell_css"; then
  echo 'Hyprshell styling must remain solid and motion-free.' >&2
  exit 1
fi
if /usr/bin/python -c \
  'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' \
  >/dev/null 2>&1; then
  /usr/bin/python - "$hyprshell_css" <<'PY'
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

probe_errors = []
probe = Gtk.CssProvider()
probe.connect(
    "parsing-error",
    lambda _provider, _section, error: probe_errors.append(error.message),
)
probe.load_from_string(".enoshima-parser-probe { definitely-not-a-property: nope; }")
if not probe_errors:
    print("GTK4 CSS parser probe did not report an invalid property", file=sys.stderr)
    raise SystemExit(1)

errors = []
provider = Gtk.CssProvider()


def record_error(_provider, section, error):
    location = section.get_start_location()
    errors.append(
        f"{location.lines + 1}:{location.line_chars + 1}: {error.message}"
    )


provider.connect("parsing-error", record_error)
provider.load_from_path(sys.argv[1])
if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
fi

vicinae_config=home/dot_config/vicinae/settings.json
jq -e '
  .telemetry.system_info == false and
  .input_server.enabled == false and
  .global_shortcuts.toggle == "" and
  all(.providers[]?.entrypoints[]?; (.shortcut // "") == "") and
  .search_files_in_root == false and
  .encrypt_sensitive_data == true and
  .consider_preedit == true and
  .favicon_service == "none" and
  .font.rendering == "native" and
  .font.normal.family == "Pretendard" and
  .theme.light.name == "tokyo-night" and
  .theme.light.icon_theme == "Papirus-Dark" and
  .theme.dark.name == "tokyo-night" and
  .theme.dark.icon_theme == "Papirus-Dark" and
  .launcher_window.opacity == 1 and
  .launcher_window.material == "none" and
  .launcher_window.rounding == 12 and
  .launcher_window.blur.enabled == false and
  .launcher_window.client_side_decorations.enabled == true and
  .launcher_window.client_side_decorations.border_width == 2 and
  .launcher_window.client_side_decorations.shadow_size == 0 and
  .launcher_window.size.width == 770 and
  .launcher_window.size.height == 480 and
  .launcher_window.layer_shell.enabled == true and
  .launcher_window.layer_shell.keyboard_interactivity == "on_demand" and
  .launcher_window.layer_shell.layer == "top" and
  .favorites == ["clipboard:history", "core:search-emojis"] and
  .fallbacks == [] and
  .providers.clipboard.preferences.monitoring == true and
  .providers.clipboard.preferences.ignorePasswords == true and
  .providers.clipboard.preferences.eraseOnStartup == true and
  .providers.clipboard.entrypoints.history.enabled == true and
  .providers.clipboard.entrypoints.history.preferences.defaultAction == "copy" and
  .providers.files.enabled == false and
  .providers.files.preferences.autoIndexing == false and
  .providers.core.entrypoints["search-emojis"].enabled == true and
  .providers.core.entrypoints["search-emojis"].preferences.defaultAction == "copy"
' "$vicinae_config" >/dev/null

grep -Fq 'if systemctl --user cat hyprshell.service' \
  home/run_after_30-enable-custom-user-services.sh.tmpl
if grep -Eq 'systemctl --user .*(start|restart|enable|disable|mask|unmask).*vicinae\.service' \
  home/run_after_30-enable-custom-user-services.sh.tmpl; then
  echo 'The chezmoi run-after hook must not change Vicinae service state.' >&2
  exit 1
fi
grep -Fq "Bootstrap alone owns Vicinae's mask" \
  home/run_after_30-enable-custom-user-services.sh.tmpl
reload_line=$(grep -n -m1 'systemctl --user daemon-reload' \
  home/run_after_30-enable-custom-user-services.sh.tmpl | cut -d: -f1)
probe_line=$(grep -n -m1 'if systemctl --user cat hyprshell.service' \
  home/run_after_30-enable-custom-user-services.sh.tmpl | cut -d: -f1)
((reload_line < probe_line))
grep -Fq 'community.general.capabilities:' \
  ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq '/usr/bin/realpath' ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq "['/usr/libexec/vicinae/vicinae-input-server']" \
  ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq 'path: "{{ vicinae_input_server.stdout }}"' \
  ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq 'capability: cap_dac_override+ep' \
  ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq 'state: absent' ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq -- '- /usr/lib/modules-load.d/vicinae.conf' \
  ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq -- '- /etc/pacman.d/hooks/95-enoshima-vicinae-capability.hook' \
  ansible/roles/desktop_expansion/tasks/vicinae.yml
grep -Fq -- '- /usr/local/libexec/enoshima-vicinae-unprivileged' \
  ansible/roles/desktop_expansion/tasks/vicinae.yml

vicinae_control=home/dot_local/bin/executable_vicinae-control
vicinae_keyring=home/dot_local/libexec/executable_vicinae-keyring-ready
vicinae_server_ready=home/dot_local/libexec/executable_vicinae-server-ready
vicinae_dropin=home/dot_config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf
bash -n "$vicinae_control" "$vicinae_keyring" "$vicinae_server_ready"
# shellcheck disable=SC2016
grep -Fq 'timeout --signal=TERM --kill-after=1s 5s /usr/bin/vicinae "${action[@]}"' \
  "$vicinae_control"
# shellcheck disable=SC2016
grep -Fq '[[ $ready == true ]] || exit 1' "$vicinae_control"
grep -Fq '0 | 124) exit 0' "$vicinae_control"
grep -Fq 'org.freedesktop.Secret.Service.ReadAlias login' "$vicinae_keyring"
grep -Fq 'org.freedesktop.Secret.Collection Locked' "$vicinae_keyring"
grep -Fq '/usr/bin/secret-tool store' "$vicinae_keyring"
grep -Fq '/usr/bin/secret-tool lookup' "$vicinae_keyring"
grep -Fq '/usr/bin/secret-tool clear' "$vicinae_keyring"
# shellcheck disable=SC2016
grep -Fq 'probe-id "$probe_id"' "$vicinae_keyring"
grep -Fq '/usr/bin/vicinae ping' "$vicinae_server_ready"
grep -Fq 'readonly startup_window_seconds=35' "$vicinae_server_ready"
# shellcheck disable=SC2016 # Assertion intentionally matches literal helper source.
grep -Fq 'deadline=$((SECONDS + startup_window_seconds))' "$vicinae_server_ready"
grep -Fq 'while ((SECONDS < deadline))' "$vicinae_server_ready"
grep -Fxq 'ExecCondition=%h/.local/libexec/vicinae-keyring-ready' "$vicinae_dropin"
grep -Fxq 'ExecStartPost=%h/.local/libexec/vicinae-server-ready' "$vicinae_dropin"
grep -Fxq 'Restart=on-failure' "$vicinae_dropin"
grep -Fxq 'KillMode=control-group' "$vicinae_dropin"
grep -Fxq 'TimeoutStartSec=40' "$vicinae_dropin"
grep -Fxq 'TimeoutStopSec=10' "$vicinae_dropin"
grep -Fxq 'StartLimitBurst=2' "$vicinae_dropin"

test_vicinae_control_readiness() {
  local fake_bin state_dir uri
  state_dir=$(mktemp -d)
  fake_bin=$state_dir/bin
  mkdir -p -- "$fake_bin"

  cat >"$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat >"$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat >"$fake_bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
  if [[ $argument == ping ]]; then
    count=$(cat "$VICINAE_TEST_PING_COUNT" 2>/dev/null || printf '0\n')
    count=$((count + 1))
    printf '%s\n' "$count" >"$VICINAE_TEST_PING_COUNT"
    ((count >= VICINAE_TEST_READY_AFTER))
    exit
  fi
done

record=false
for argument in "$@"; do
  if [[ $record == true ]]; then
    printf '%s\n' "$argument" >>"$VICINAE_TEST_ACTION_LOG"
  elif [[ $argument == /usr/bin/vicinae ]]; then
    record=true
  fi
done
[[ $record == true ]]
exit "${VICINAE_TEST_ACTION_STATUS:-0}"
SH
  chmod +x "$fake_bin/systemctl" "$fake_bin/sleep" "$fake_bin/timeout"

  if PATH="$fake_bin:$PATH" \
    VICINAE_TEST_PING_COUNT="$state_dir/ping-count" \
    VICINAE_TEST_READY_AFTER=21 \
    VICINAE_TEST_ACTION_LOG="$state_dir/action-log" \
    bash "$vicinae_control" toggle; then
    echo 'Vicinae control must fail when every readiness probe times out.' >&2
    rm -rf -- "$state_dir"
    return 1
  fi
  [[ ! -e $state_dir/action-log ]]

  rm -f -- "$state_dir/ping-count"
  PATH="$fake_bin:$PATH" \
    VICINAE_TEST_PING_COUNT="$state_dir/ping-count" \
    VICINAE_TEST_READY_AFTER=2 \
    VICINAE_TEST_ACTION_LOG="$state_dir/action-log" \
    VICINAE_TEST_ACTION_STATUS=124 \
    bash "$vicinae_control" toggle
  [[ $(cat "$state_dir/action-log") == toggle ]]

  for uri in \
    'raycast://oauth?code=oauth-code_1&state=abcdefghijklmnop' \
    'com.raycast:/oauth?state=abcdefghijklmnop&code=oauth-code_1'; do
    rm -f -- "$state_dir/ping-count" "$state_dir/action-log"
    PATH="$fake_bin:$PATH" \
      VICINAE_TEST_PING_COUNT="$state_dir/ping-count" \
      VICINAE_TEST_READY_AFTER=1 \
      VICINAE_TEST_ACTION_LOG="$state_dir/action-log" \
      bash "$vicinae_control" uri "$uri"
    [[ $(cat "$state_dir/action-log") == "$uri" ]]
  done

  for uri in \
    'https://example.invalid' \
    'vicinae://launch/system/run?arguments=%7B%22command%22%3A%22%2Fbin%2Fsh%22%7D' \
    'vicinae://launch/system/power-off' \
    'vicinae://kill' \
    'vicinae://api/extensions/develop/start?id=evil' \
    'raycast://oauth?code=missing-state' \
    'com.raycast:/oauth?code=a&state=short' \
    'com.raycast://launch/system/run'; do
    rm -f -- "$state_dir/ping-count" "$state_dir/action-log"
    if PATH="$fake_bin:$PATH" \
      VICINAE_TEST_PING_COUNT="$state_dir/ping-count" \
      VICINAE_TEST_READY_AFTER=1 \
      VICINAE_TEST_ACTION_LOG="$state_dir/action-log" \
      bash "$vicinae_control" uri "$uri"; then
      printf 'Vicinae control accepted an unsafe external URI: %s\n' "$uri" >&2
      rm -rf -- "$state_dir"
      return 1
    fi
    [[ ! -e $state_dir/ping-count && ! -e $state_dir/action-log ]]
  done
  if bash "$vicinae_control" uri >/dev/null 2>&1 ||
    bash "$vicinae_control" uri vicinae://example extra >/dev/null 2>&1; then
    echo 'Vicinae control accepted an invalid URI argument count.' >&2
    rm -rf -- "$state_dir"
    return 1
  fi

  rm -rf -- "$state_dir"
}

test_vicinae_control_readiness

test_vicinae_server_readiness() {
  local fake_bin state_dir
  state_dir=$(mktemp -d)
  fake_bin=$state_dir/bin
  mkdir -p -- "$fake_bin"
  cat >"$fake_bin/timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "$VICINAE_TEST_PING_COUNT" 2>/dev/null || printf '0\n')
count=$((count + 1))
printf '%s\n' "$count" >"$VICINAE_TEST_PING_COUNT"
((count >= VICINAE_TEST_READY_AFTER))
SH
  chmod +x "$fake_bin/timeout"

  sleep() {
    SECONDS=$((SECONDS + 1))
  }
  export -f sleep

  PATH="$fake_bin:$PATH" \
    VICINAE_TEST_PING_COUNT=$state_dir/ping-count \
    VICINAE_TEST_READY_AFTER=8 \
    bash "$vicinae_server_ready"
  [[ $(<"$state_dir/ping-count") == 8 ]]

  rm -f -- "$state_dir/ping-count"
  if PATH="$fake_bin:$PATH" \
    VICINAE_TEST_PING_COUNT=$state_dir/ping-count \
    VICINAE_TEST_READY_AFTER=100000 \
    bash "$vicinae_server_ready" >/dev/null 2>&1; then
    echo 'Vicinae server readiness accepted a permanently unavailable IPC server.' >&2
    rm -rf -- "$state_dir"
    return 1
  fi
  (($(<"$state_dir/ping-count") > 8))

  unset -f sleep
  rm -rf -- "$state_dir"
}

test_vicinae_server_readiness

test_vicinae_effective_service_policy() {
  local keyring_helper=/home/test/.local/libexec/vicinae-keyring-ready
  local server_helper=/home/test/.local/libexec/vicinae-server-ready
  local properties

  properties=$(
    cat <<EOF
Restart=on-failure
RestartUSec=1min
TimeoutStartUSec=40s
TimeoutStopUSec=10s
StartLimitIntervalUSec=5min
StartLimitBurst=2
ExecStart={ path=/usr/bin/vicinae ; argv[]=/usr/bin/vicinae server --replace ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
ExecStartPost={ path=$server_helper ; argv[]=$server_helper ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
Environment=VICINAE_NODE_BIN=/usr/bin/node HOME=/home/test XDG_CONFIG_HOME=/home/test/.config XDG_DATA_HOME=/home/test/.local/share XDG_STATE_HOME=/home/test/.local/state XDG_CACHE_HOME=/home/test/.cache
UnsetEnvironment=QT_NO_GLIB LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT QT_PLUGIN_PATH QML_IMPORT_PATH QML2_IMPORT_PATH QT_QPA_PLATFORM_PLUGIN_PATH VICINAE_OVERRIDES
ExecCondition={ path=/usr/libexec/vicinae/vicinae-build-compatible ; argv[]=/usr/libexec/vicinae/vicinae-build-compatible ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
ExecCondition={ path=$keyring_helper ; argv[]=$keyring_helper ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }
FragmentPath=/usr/lib/systemd/user/vicinae.service
DropInPaths=/usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf /home/test/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf
KillMode=control-group
EOF
  )
  vicinae_effective_service_policy_valid \
    "$properties" "$keyring_helper" "$server_helper"
  if vicinae_effective_service_policy_valid \
    "${properties/path=\/usr\/bin\/vicinae/path=\/tmp\/vicinae}" \
    "$keyring_helper" "$server_helper"; then
    echo 'Vicinae policy parser accepted an unmanaged executable path.' >&2
    return 1
  fi
  if vicinae_effective_service_policy_valid \
    "$properties"$'\nEnvironmentFiles=/tmp/vicinae.env (ignore_errors=no)' \
    "$keyring_helper" "$server_helper"; then
    echo 'Vicinae policy parser accepted a non-empty EnvironmentFiles.' >&2
    return 1
  fi
  if vicinae_effective_service_policy_valid \
    "${properties/FragmentPath=\/usr\/lib\/systemd\/user\/vicinae.service/FragmentPath=\/run\/systemd\/user\/vicinae.service}" \
    "$keyring_helper" "$server_helper"; then
    echo 'Vicinae policy parser accepted a leftover native runtime mask.' >&2
    return 1
  fi
  if vicinae_effective_service_policy_valid \
    "${properties/UnsetEnvironment=QT_NO_GLIB LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT QT_PLUGIN_PATH QML_IMPORT_PATH QML2_IMPORT_PATH QT_QPA_PLATFORM_PLUGIN_PATH VICINAE_OVERRIDES/UnsetEnvironment=LD_PRELOAD}" \
    "$keyring_helper" "$server_helper"; then
    echo 'Vicinae policy parser accepted an unsafe UnsetEnvironment.' >&2
    return 1
  fi
  if vicinae_effective_service_policy_valid \
    "$(printf '%s\n' "$properties" | sed '/^KillMode=/d')" \
    "$keyring_helper" "$server_helper"; then
    echo 'Vicinae policy parser accepted a missing required property.' >&2
    return 1
  fi
  while IFS='|' read -r expected replacement label; do
    if vicinae_effective_service_policy_valid \
      "${properties/$expected/$replacement}" \
      "$keyring_helper" "$server_helper"; then
      printf 'Vicinae policy parser accepted an unsafe %s.\n' "$label" >&2
      return 1
    fi
  done <<'EOF'
RestartUSec=1min|RestartUSec=0|restart delay
TimeoutStartUSec=40s|TimeoutStartUSec=infinity|startup timeout
TimeoutStopUSec=10s|TimeoutStopUSec=infinity|stop timeout
StartLimitIntervalUSec=5min|StartLimitIntervalUSec=infinity|start-limit interval
StartLimitBurst=2|StartLimitBurst=0|start-limit burst
EOF
}

test_vicinae_effective_service_policy

postflight=scripts/postflight.sh
grep -Fq 'check "Hyprshot CLI is callable" hyprshot --help' "$postflight"
grep -Fq 'test -f /usr/share/applications/io.github.seadve.Kooha.desktop' "$postflight"
grep -Fq 'Hyprshell overview configuration parses' "$postflight"
grep -Fq 'Hyprshell is the pinned direct-input source build' "$postflight"
grep -Fq 'Hyprshell package source and patch provenance are pinned' "$postflight"
grep -Fq 'hyprshell_source_build_identity_valid' "$postflight"
grep -Fq "hyprshell-bin 4.10.8-3" "$postflight"
grep -Fq 'getcap -n /usr/bin/hyprshell' "$postflight"
grep -Fq 'readelf -d /usr/bin/hyprshell' "$postflight"
# shellcheck disable=SC2016 # Assertion intentionally matches literal source.
grep -Fq '"$repo_root/scripts/check-hyprshell-provenance" --root "$repo_root"' \
  "$postflight"
grep -Fq 'vicinae_performance_scripts_valid()' "$postflight"
grep -Fq 'vicinae_input_server_unprivileged()' "$postflight"
grep -Fq 'vicinae_source_build_identity_valid()' "$postflight"
grep -Fq 'vicinae_native_runtime_valid()' "$postflight"
grep -Fq 'vicinae_native_linkage_valid()' "$postflight"
grep -Fq "resolved=\$(readlink -e -- \"\$resolved\")" "$postflight"
if grep -Fq '/usr/libexec/vicinae/*' "$postflight"; then
  echo 'Vicinae ELF linkage must not include package lifecycle shell helpers.' >&2
  exit 1
fi
for executable in \
  /usr/bin/vicinae \
  /usr/libexec/vicinae/vicinae-browser-link \
  /usr/libexec/vicinae/vicinae-data-control-server \
  /usr/libexec/vicinae/vicinae-file-indexer \
  /usr/libexec/vicinae/vicinae-input-server \
  /usr/libexec/vicinae/vicinae-server; do
  grep -Fq "$executable" "$postflight"
done
grep -Fq 'vicinae_system_qt_glib_valid()' "$postflight"
grep -Fq '/run/systemd/user/vicinae.service' "$postflight"
grep -Fq 'vicinae_desktop_entries_valid()' "$postflight"
grep -Fq 'vicinae_uri_associations_valid()' "$postflight"
grep -Fq 'vicinae_service_policy_valid()' "$postflight"
grep -Fq 'systemctl --user show vicinae.service --no-pager' "$postflight"
if grep -Fq 'org.freedesktop.systemd1.Manager RefUnit' "$postflight"; then
  echo 'Vicinae policy check must not use a short-lived RefUnit call.' >&2
  exit 1
fi
if grep -Fq 'org.freedesktop.systemd1.Manager UnrefUnit' "$postflight"; then
  echo 'Vicinae policy check must not unref another D-Bus connection.' >&2
  exit 1
fi
grep -Fq "[[ \$(pacman -Q vicinae-bin) == 'vicinae-bin 0.25.0-10' ]]" \
  "$postflight"
grep -Fq 'Provenance: arch_source' "$postflight"
grep -Fq 'QEventDispatcherGlib13processEvents' "$postflight"
grep -Fq 'Vicinae package and ephemeral Qt guard hooks are pinned' "$postflight"
grep -Fq 'Vicinae server responds after login' "$postflight"
grep -Fq 'timeout --signal=TERM --kill-after=1s 5s /usr/bin/vicinae ping' \
  "$postflight"
grep -Fq 'vicinae_active_runtime_mapping_valid()' "$postflight"
grep -Fq 'vicinae_bundled_notices_valid()' "$postflight"
grep -Fq 'Vicinae shortcut IPC is bounded' "$postflight"
grep -Fq 'Vicinae packaged service has the effective bounded keyring guard' \
  "$postflight"
grep -Fq -- '--property=EnvironmentFiles' "$postflight"
grep -Fq -- '--property=UnsetEnvironment' "$postflight"
grep -Fq -- '--property=RestartUSec' "$postflight"
grep -Fq -- '--property=ExecCondition' "$postflight"
grep -Fq -- '--property=ExecStartPost' "$postflight"
grep -Fq -- '--property=TimeoutStartUSec' "$postflight"
grep -Fq -- '--property=StartLimitIntervalUSec' "$postflight"
grep -Fq -- '--property=StartLimitBurst' "$postflight"
# shellcheck disable=SC2016
grep -Fq '"$properties" "$keyring_helper" "$server_helper"' \
  "$postflight"
grep -Fq 'Vicinae package and ephemeral Qt guard hooks are pinned' "$postflight"
grep -Fq 'for unit in hyprshell.service vicinae.service' "$postflight"
for gate in \
  desktop-capture-recording \
  command-palette-staged-rollout \
  overview-keyboard-mixed-dpi; do
  grep -Fq -- "$gate" tests/verification-map.yaml
  grep -Fq -- "$gate" docs/VM-TESTING.md
done
# Backticks below are literal Markdown acceptance text, not command substitutions.
# shellcheck disable=SC2016
for acceptance_text in \
  'Applications에서 `Ghostty`' \
  'Windows provider' \
  'Calculator에 `2+2`' \
  'wl-paste --list-types' \
  '`text/uri-list`' \
  '`image/png`' \
  '`text/html`' \
  '`text/plain`' \
  '복합 MIME 집합이 유지' \
  'resume·unlock 후 같은 두 selector' \
  'stale portal dialog나 black stream'; do
  grep -Fq -- "$acceptance_text" docs/DESKTOP-EXPANSION-OPERATIONS.md
done

script_count=$(find home/dot_local/share/vicinae/scripts -maxdepth 1 \
  -type f -name 'executable_performance-*.sh' | wc -l)
[[ $script_count -eq 8 ]]
while IFS= read -r script; do
  grep -Fq '# @vicinae.schemaVersion 1' "$script"
  grep -Fq '# @vicinae.mode silent' "$script"
  grep -Fq '# @vicinae.packageName Performance' "$script"
  grep -Eq '^# @vicinae\.icon /usr/share/icons/Papirus/64x64/.+\.svg$' "$script"
  grep -Fq 'exec uwsm app -t service -- ' "$script"
  if command -v vicinae >/dev/null 2>&1; then
    vicinae script check "$script"
  fi
done < <(
  find home/dot_local/share/vicinae/scripts -maxdepth 1 \
    -type f -name 'executable_performance-*.sh' | sort
)
grep -Fxq '# @vicinae.title Resources' \
  home/dot_local/share/vicinae/scripts/executable_performance-resources.sh
grep -Fxq '# @vicinae.description 시스템 리소스 모니터' \
  home/dot_local/share/vicinae/scripts/executable_performance-resources.sh
grep -Fxq '# @vicinae.title atop 기록' \
  home/dot_local/share/vicinae/scripts/executable_performance-atop-history.sh
grep -Fxq '# @vicinae.description 시스템 리소스 기록' \
  home/dot_local/share/vicinae/scripts/executable_performance-atop-history.sh
grep -Fxq 'exec uwsm app -t service -- ghostty --title="Atop history" -e sudo atop -r' \
  home/dot_local/share/vicinae/scripts/executable_performance-atop-history.sh
grep -Fxq '# @vicinae.title I/O 확인' \
  home/dot_local/share/vicinae/scripts/executable_performance-io.sh
grep -Fxq '# @vicinae.description 디스크 I/O 모니터' \
  home/dot_local/share/vicinae/scripts/executable_performance-io.sh
grep -Fxq 'exec uwsm app -t service -- ghostty --title="I/O pressure" -e sudo iotop --only --processes --accumulated' \
  home/dot_local/share/vicinae/scripts/executable_performance-io.sh
grep -Fxq '# @vicinae.title GPU 확인' \
  home/dot_local/share/vicinae/scripts/executable_performance-gpu.sh
grep -Fxq '# @vicinae.description GPU 사용량 모니터' \
  home/dot_local/share/vicinae/scripts/executable_performance-gpu.sh
grep -Fxq 'exec uwsm app -t service -- ghostty --title="GPU usage" -e nvtop' \
  home/dot_local/share/vicinae/scripts/executable_performance-gpu.sh
grep -Fxq '# @vicinae.title Sysprof 캡처' \
  home/dot_local/share/vicinae/scripts/executable_performance-sysprof.sh
grep -Fxq '# @vicinae.description 성능 프로파일링 캡처' \
  home/dot_local/share/vicinae/scripts/executable_performance-sysprof.sh
grep -Fxq 'exec uwsm app -t service -- sysprof' \
  home/dot_local/share/vicinae/scripts/executable_performance-sysprof.sh
grep -Fxq 'exec uwsm app -t service -- resources' \
  home/dot_local/share/vicinae/scripts/executable_performance-resources.sh
grep -Fxq '# @vicinae.title sysstat 기록' \
  home/dot_local/share/vicinae/scripts/executable_performance-sysstat-history.sh
# shellcheck disable=SC2016
grep -Fq 'history_file="/var/log/sa/sa$(date +%d)"' \
  home/dot_local/share/vicinae/scripts/executable_performance-sysstat-history.sh
# shellcheck disable=SC2016
grep -Fq '  -e sudo sar -A -f "$history_file"' \
  home/dot_local/share/vicinae/scripts/executable_performance-sysstat-history.sh
grep -Fxq '# @vicinae.title CPU·열 상태' \
  home/dot_local/share/vicinae/scripts/executable_performance-cpu-thermal.sh
grep -Fxq 'exec uwsm app -t service -- ghostty --title="CPU and thermal status" -e s-tui' \
  home/dot_local/share/vicinae/scripts/executable_performance-cpu-thermal.sh
grep -Fxq '# @vicinae.title 전력 분석' \
  home/dot_local/share/vicinae/scripts/executable_performance-power.sh
grep -Fxq 'exec uwsm app -t service -- ghostty --title="Power analysis" -e sudo powertop' \
  home/dot_local/share/vicinae/scripts/executable_performance-power.sh

hyprshell_bin=${HYPRSHELL_BIN:-}
if [[ -z $hyprshell_bin ]] && command -v hyprshell >/dev/null 2>&1; then
  hyprshell_bin=$(command -v hyprshell)
fi
if [[ -n $hyprshell_bin ]]; then
  "$hyprshell_bin" -c "$hyprshell_config" config check
fi

printf 'Desktop essentials tests passed.\n'
