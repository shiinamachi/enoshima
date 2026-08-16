#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/inventory-capabilities.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/inventory-capabilities.sh"
# shellcheck source=lib/vicinae-service-policy.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/lib/vicinae-service-policy.sh"
inventory=$repo_root/ansible/inventory/hosts.yml
profile=${PROFILE:-}
report_format=text
report_output=
failures=0
warnings=0
skips=0
results_file=$(mktemp)
report_stdout_fd=

usage() {
  cat <<'EOF'
Usage: scripts/postflight.sh [OPTIONS]

Options:
  --profile HOST            Read capabilities for an Ansible inventory host.
  --inventory PATH          Use an alternate Ansible inventory file or directory.
  --format text|json        Select output format (default: text).
  --output PATH             Write the report to PATH instead of standard output.
  -h, --help                Show this help.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 2
}

while (($# > 0)); do
  case $1 in
    --profile)
      (($# >= 2)) || die '--profile requires a value'
      profile=$2
      shift 2
      ;;
    --inventory)
      (($# >= 2)) || die '--inventory requires a value'
      inventory=$2
      shift 2
      ;;
    --format)
      (($# >= 2)) || die '--format requires a value'
      report_format=$2
      shift 2
      ;;
    --output)
      (($# >= 2)) || die '--output requires a value'
      report_output=$2
      shift 2
      ;;
    -h | --help)
      usage
      rm -f -- "$results_file"
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -e $inventory ]] || die "inventory does not exist: $inventory"
case $report_format in
  text | json) ;;
  *) die "invalid report format '$report_format' (use text or json)" ;;
esac

if [[ -z $profile ]]; then
  profile=$(hostnamectl --static 2>/dev/null || hostname)
fi

inventory_host_json='{}'
if command -v ansible-inventory >/dev/null 2>&1; then
  inventory_host_json=$(ansible-inventory \
    --inventory "$inventory" --host "$profile" 2>/dev/null) ||
    die "profile '$profile' is not present in $inventory"
fi

cleanup() {
  rm -f -- "$results_file" "$results_file.json"
}
trap cleanup EXIT

if [[ $report_format == json && -z $report_output ]]; then
  exec 3>&1
  report_stdout_fd=3
  exec 1>/dev/null
fi

check_id() {
  LC_ALL=C sed -E \
    -e 's/[^[:alnum:]]+/-/g' \
    -e 's/^-+|-+$//g' \
    -e 's/.*/\L&/' <<<"$1"
}

record_result() {
  local status=$1 description=$2 reason=${3:-} id=${4:-}
  [[ -n $id ]] || id=$(check_id "$description")
  /usr/bin/python - "$id" "$status" "$description" "$reason" >>"$results_file" <<'PY'
import json
import sys

print(json.dumps({
    "id": sys.argv[1],
    "status": sys.argv[2],
    "description": sys.argv[3],
    **({"reason": sys.argv[4]} if sys.argv[4] else {}),
}, ensure_ascii=False))
PY
}

capability() {
  inventory_capability "$inventory_host_json" "$1"
}

pass() {
  printf '[PASS] %s\n' "$1"
  record_result pass "$1" '' "${2:-}"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  failures=$((failures + 1))
  record_result fail "$1" '' "${2:-}"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
  warnings=$((warnings + 1))
  record_result warn "$1" "${2:-}" "${3:-}"
}

skip() {
  local description=$1 reason=$2 id=${3:-}
  printf '[SKIP] %s (%s)\n' "$description" "$reason"
  skips=$((skips + 1))
  record_result skip "$description" "$reason" "$id"
}

check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

check_or_warn() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$description"
  else
    warn "$description"
  fi
}

sha256_matches() {
  local path=$1
  local expected=$2
  local actual
  actual=$(sha256sum -- "$path") || return 1
  [[ ${actual%% *} == "$expected" ]]
}

filezilla_version_reports() {
  local output status

  output=$(timeout 15s filezilla --version 2>&1)
  status=$?

  # FileZilla 3.70.6 on Arch currently reports a valid version and then exits
  # with wxWidgets' generic failure code. Treat that known exit as healthy only
  # when the expected version banner was actually emitted.
  case $status in
    0 | 255) ;;
    *) return "$status" ;;
  esac

  grep -Eq '^FileZilla [0-9]+([.][0-9]+)+([,[:space:]]|$)' <<<"$output"
}

swaync_quick_settings_callable() {
  local helper=$HOME/.local/bin/swaync-quick-setting
  local setting state
  [[ -x $helper ]] || return 1

  for setting in wifi bluetooth night-light; do
    state=$("$helper" status "$setting") || return 1
    [[ $state == true || $state == false ]] || return 1
  done
}

lenovo_sar_run_succeeded() {
  local invocation result exit_status
  invocation=$(systemctl show lenovo-cfgservice.service \
    --property InvocationID --value 2>/dev/null) || return 1
  result=$(systemctl show lenovo-cfgservice.service \
    --property Result --value 2>/dev/null) || return 1
  exit_status=$(systemctl show lenovo-cfgservice.service \
    --property ExecMainStatus --value 2>/dev/null) || return 1
  [[ -n $invocation && $result == success && $exit_status == 0 ]]
}

manifest_entries() {
  sed -E \
    -e 's/[[:space:]]+#.*$//' \
    -e '/^[[:space:]]*(#|$)/d' \
    "$1"
}

zsh_developer_plugins_loaded() {
  # The single-quoted script must be evaluated by the child Zsh, not Bash.
  # shellcheck disable=SC2016
  FASTFETCH_SUPPRESS=1 zsh -ic '
    [[ ${plugins[-1]} == zsh-syntax-highlighting ]] || exit 10
    (( $+functions[fzf-tab-complete] )) || exit 11
    (( $+functions[_zsh_autosuggest_start] )) || exit 12
    (( $+functions[_zsh_highlight] )) || exit 13
    (( $+functions[history-substring-search-up] )) || exit 14
    (( $+functions[__zoxide_z] )) || exit 15
    (( $+functions[als] )) || exit 16
    (( $+functions[mise] )) || exit 17
    [[ $STARSHIP_SHELL == zsh ]] || exit 18
    [[ $(bindkey "^I") == *fzf-tab-complete* ]] || exit 19
    [[ ${aliases[ls]} == eza* ]] || exit 20
  ' </dev/null
}

hyprpm_state() {
  LC_ALL=C hyprpm list 2>/dev/null |
    sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g'
}

hyprpm_plugin_enabled() {
  local plugin=$1
  hyprpm_state | awk -v plugin="$plugin" '
    index($0, "Plugin " plugin) > 0 { found = 1; next }
    found && index($0, "enabled:") > 0 {
      enabled = ($NF == "true")
      exit
    }
    END { exit !(found && enabled) }
  '
}

hyprfocus_loaded() {
  hyprctl plugin list -j | jq -e '.[] | select(.name == "hyprfocus")'
}

enoshima_decoration_installed() {
  local abi plugin recorded
  abi=$(Hyprland --version | sed -n 's/^Version ABI string: //p')
  [[ $abi =~ ^[0-9a-f]{40}(_[[:alnum:]]+([.-][[:alnum:]]+)*)*$ ]] || return 1
  plugin=${XDG_DATA_HOME:-$HOME/.local/share}/enoshima/plugins/$abi/enoshima-decoration.so
  recorded=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/enoshima-decoration/hyprland-abi" 2>/dev/null) || return 1
  [[ $recorded == "$abi" && -s $plugin ]]
}

enoshima_decoration_loaded() {
  hyprctl plugin list -j | jq -e '.[] | select(.name == "enoshima-decoration")'
}

hyprfocus_configured() {
  local appearance_mode=default
  local animate_floating enable fade keyboard legacy_mode mouse

  if [[ -x $HOME/.local/bin/desktop-appearance ]]; then
    appearance_mode=$("$HOME/.local/bin/desktop-appearance" status 2>/dev/null || printf 'default\n')
  fi

  enable=$(hyprctl getoption plugin:hyprfocus:enable -j 2>/dev/null || true)
  if jq -e '.option == "plugin:hyprfocus:enable"' <<<"$enable" >/dev/null 2>&1; then
    animate_floating=$(hyprctl getoption plugin:hyprfocus:animate_floating -j 2>/dev/null) || return 1
    keyboard=$(hyprctl getoption plugin:hyprfocus:keyboard_focus_animation -j 2>/dev/null) || return 1
    mouse=$(hyprctl getoption plugin:hyprfocus:mouse_focus_animation -j 2>/dev/null) || return 1
    fade=$(hyprctl getoption plugin:hyprfocus:fade_opacity -j 2>/dev/null) || return 1

    jq -e '.bool == false' <<<"$animate_floating" >/dev/null || return 1
    jq -e '.str == "flash"' <<<"$keyboard" >/dev/null || return 1
    jq -e '.str == "none"' <<<"$mouse" >/dev/null || return 1
    jq -e '.float >= 0.939 and .float <= 0.941' <<<"$fade" >/dev/null || return 1

    case $appearance_mode in
      reduced-motion | accessible)
        jq -e '.bool == false' <<<"$enable" >/dev/null
        ;;
      *)
        jq -e '.bool == true' <<<"$enable" >/dev/null
        ;;
    esac
    return
  fi

  legacy_mode=$(hyprctl getoption plugin:hyprfocus:mode -j 2>/dev/null) || return 1
  fade=$(hyprctl getoption plugin:hyprfocus:fade_opacity -j 2>/dev/null) || return 1
  jq -e '.str == "flash"' <<<"$legacy_mode" >/dev/null || return 1

  case $appearance_mode in
    reduced-motion | accessible)
      jq -e '.float >= 0.999 and .float <= 1.0' <<<"$fade" >/dev/null
      ;;
    *)
      jq -e '.float >= 0.939 and .float <= 0.941' <<<"$fade" >/dev/null
      ;;
  esac
}

effective_systemd_setting() {
  local namespace=$1 wanted_section=$2 wanted_key=$3 expected=$4 actual

  actual=$(
    systemd-analyze cat-config "$namespace" 2>/dev/null |
      awk -v wanted_section="$wanted_section" -v wanted_key="$wanted_key" '
        function trim(value) {
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          return value
        }
        {
          line = trim($0)
          if (line == "" || line ~ /^[#;]/) next
          if (line ~ /^\[[^]]+\]$/) {
            section = substr(line, 2, length(line) - 2)
            next
          }
          separator = index(line, "=")
          if (!separator || section != wanted_section) next
          key = trim(substr(line, 1, separator - 1))
          if (key == wanted_key) {
            value = trim(substr(line, separator + 1))
            found = 1
          }
        }
        END {
          if (!found) exit 1
          print value
        }
      '
  ) || return 1

  [[ $actual == "$expected" ]]
}

atop_history_policy_configured() (
  unset LOGOPTS LOGINTERVAL LOGGENERATIONS LOGPATH ATOPACCT
  # shellcheck disable=SC1091
  source /etc/default/atop || return 1

  [[ ${LOGOPTS+x} && -z $LOGOPTS ]] &&
    [[ ${LOGINTERVAL-} == 60 ]] &&
    [[ ${LOGGENERATIONS-} == 14 ]] &&
    [[ ${LOGPATH-} == /var/log/atop ]] &&
    [[ ${ATOPACCT+x} && -z $ATOPACCT ]]
)

atop_process_accounting_disabled() {
  local environment main_pid

  main_pid=$(systemctl show atop.service -P MainPID) || return 1
  [[ $main_pid =~ ^[1-9][0-9]*$ ]] || return 1
  environment=$(sudo -n cat "/proc/$main_pid/environ" | tr '\0' '\n') || return 1
  grep -Fxq 'ATOPACCT=' <<<"$environment"
}

sysstat_history_policy_configured() (
  unset HISTORY SADC_OPTIONS UMASK
  # shellcheck disable=SC1091
  source /etc/conf.d/sysstat || return 1
  [[ ${HISTORY-} == 28 ]] &&
    [[ ${SADC_OPTIONS-} == '-S DISK,POWER' ]] &&
    [[ ${UMASK-} == 0077 ]]
)

sysstat_timer_policy_configured() {
  local calendar accuracy

  calendar=$(systemctl show sysstat-collect.timer -P TimersCalendar) || return 1
  accuracy=$(systemctl show sysstat-collect.timer -P AccuracyUSec) || return 1
  [[ $calendar == *"OnCalendar=*-*-* *:*:00/30"* ]] &&
    [[ $accuracy == 1s ]]
}

unit_disabled_and_inactive() {
  systemctl cat "$1" >/dev/null 2>&1 &&
    ! systemctl is-enabled --quiet "$1" &&
    ! systemctl is-active --quiet "$1"
}

history_file_recent() {
  local path=$1 maximum_age=$2 now modified age

  now=$(date +%s) || return 1
  modified=$(sudo -n stat -c %Y -- "$path") || return 1
  age=$((now - modified))
  ((age >= 0 && age <= maximum_age))
}

atop_history_recent_and_readable() {
  local latest

  latest=$(
    sudo -n find /var/log/atop -maxdepth 1 -type f \
      -name 'atop_*' -size +0c -printf '%T@ %p\n' |
      sort -nr | head -n 1 | cut -d ' ' -f 2-
  ) || return 1
  [[ -n $latest ]] || return 1
  history_file_recent "$latest" 180 || return 1
  sudo -n timeout 30 /usr/bin/atop -r "$latest" -PCPU >/dev/null
}

sysstat_history_recent_and_readable() {
  local latest

  latest=$(
    sudo -n find /var/log/sa -maxdepth 1 -type f \
      -name 'sa[0-9][0-9]' -size +0c -printf '%T@ %p\n' |
      sort -nr | head -n 1 | cut -d ' ' -f 2-
  ) || return 1
  [[ -n $latest ]] || return 1
  history_file_recent "$latest" 120 || return 1
  sudo -n timeout 30 /usr/bin/sar -A -f "$latest" >/dev/null &&
    sudo -n timeout 30 /usr/bin/sar -d -f "$latest" >/dev/null &&
    sudo -n timeout 30 /usr/bin/sar -m CPU,FREQ,TEMP -f "$latest" >/dev/null
}

vicinae_input_server_unprivileged() {
  local helper=/usr/libexec/vicinae/vicinae-input-server
  local capabilities mode

  [[ -x $helper ]] || return 1
  [[ $(stat -c '%U:%G' "$helper") == root:root ]] || return 1
  mode=$(stat -c '%a' "$helper") || return 1
  (((8#$mode & 06000) == 0)) || return 1
  capabilities=$(getcap -n "$helper" 2>/dev/null) || return 1
  [[ -z $capabilities ]]
}

vicinae_source_build_identity_valid() {
  local actual

  [[ $(pacman -Q vicinae-bin) == 'vicinae-bin 0.25.0-10' ]] || return 1
  actual=$(vicinae version) || return 1
  grep -Fxq 'Version v0.25.0 (commit 7e13b3f54)' <<<"$actual" || return 1
  grep -Eq '^Build: GCC [0-9]+(\.[0-9]+)+ - Release$' <<<"$actual" || return 1
  grep -Fxq 'Provenance: arch_source' <<<"$actual"
}

hyprshell_source_build_identity_valid() {
  local capabilities mode

  [[ $(pacman -Q hyprshell-bin) == 'hyprshell-bin 4.10.8-3' ]] || return 1
  [[ -f /usr/bin/hyprshell && ! -L /usr/bin/hyprshell && -x /usr/bin/hyprshell ]] ||
    return 1
  [[ $(stat -c '%U:%G' /usr/bin/hyprshell) == root:root ]] || return 1
  mode=$(stat -c '%a' /usr/bin/hyprshell) || return 1
  [[ $mode == 755 ]] || return 1
  capabilities=$(getcap -n /usr/bin/hyprshell 2>/dev/null) || return 1
  [[ -z $capabilities ]] || return 1
  ! readelf -d /usr/bin/hyprshell | grep -Eq '\((RPATH|RUNPATH)\)' || return 1
  hyprshell --version | grep -Fq '4.10.8'
}

vicinae_native_runtime_valid() {
  local elf mode
  local -a executables=(
    /usr/bin/vicinae
    /usr/libexec/vicinae/vicinae-browser-link
    /usr/libexec/vicinae/vicinae-data-control-server
    /usr/libexec/vicinae/vicinae-file-indexer
    /usr/libexec/vicinae/vicinae-input-server
    /usr/libexec/vicinae/vicinae-server
  )

  [[ ! -e /opt/vicinae && ! -e /usr/bin/qt.conf ]] || return 1
  for directory in /usr/libexec/vicinae /usr/share/vicinae; do
    [[ -d $directory && ! -L $directory ]] || return 1
    [[ $(stat -c '%U:%G' "$directory") == root:root ]] || return 1
    mode=$(stat -c '%a' "$directory") || return 1
    (((8#$mode & 00022) == 0)) || return 1
  done
  [[ -f /usr/share/vicinae/themes/tokyo-night.toml ]] || return 1
  [[ -f /usr/share/licenses/vicinae-bin/LICENSE ]] || return 1
  sha256_matches /usr/share/licenses/vicinae-bin/LICENSE \
    3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986 ||
    return 1
  if find /usr/libexec/vicinae /usr/share/vicinae -xdev -mindepth 1 \
    ! -type d ! -type f -print -quit | grep -q .; then
    return 1
  fi
  if find /usr/libexec/vicinae /usr/share/vicinae -xdev -mindepth 1 \
    \( ! -user root -o ! -group root -o -perm /0022 \) \
    -print -quit | grep -q .; then
    return 1
  fi

  for elf in "${executables[@]}"; do
    [[ -f $elf && ! -L $elf && -x $elf ]] || return 1
    [[ $(stat -c '%U:%G' "$elf") == root:root ]] || return 1
    mode=$(stat -c '%a' "$elf") || return 1
    [[ $mode == 755 ]] || return 1
    readelf -n "$elf" | grep -Fq 'Build ID:' || return 1
    ! readelf -d "$elf" | grep -Eq '\((RPATH|RUNPATH)\)' || return 1
    ! readelf --wide --dyn-syms "$elf" | grep -Fq '@Qt_6_PRIVATE_API' ||
      return 1
  done
  [[ -f /usr/share/vicinae/build-environment.json &&
    ! -L /usr/share/vicinae/build-environment.json ]] || return 1
  jq -e '
    .schemaVersion == 2 and
    .packageVersion == "0.25.0-10" and
    .source.commit == "7e13b3f5450e9d91b09be2fec2f05c021c8ebb95" and
    .qmlCachegen == false and
    .usesQtGuiPrivate == true and
    (.qtLibraries | length > 0) and
    (.executables | length == 6)
  ' /usr/share/vicinae/build-environment.json >/dev/null
}

vicinae_bundled_notices_valid() {
  local notice_root=/usr/share/licenses/vicinae-bin/bundled
  local notice expected
  local -A digests=(
    ["cmark-gfm-COPYING"]=c22e885f33b821bddb24cf007145e5540655b6c0f403e49e6c76a93c28e6d9a9
    ["kirigami-wheelhandler-COPYING"]=de588a8b1c41fe73ffe1201f9d12c718a988ed8e1302929625a6e7c2bced7461
    ["vicinae-server-LICENSE"]=34d47ed18ab118421ec7cde3f04673a266d4f5f30ba573ab5147dbff57c55ea5
    ["glaze-LICENSE"]=5d49e66411a0807a7c8d6b911b9a26b59e940c71aebe561a3ad8b0b80ac4b7b6
    ["react-LICENSE"]=da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93
    ["pugixml-LICENSE"]=0d0b3772af2fa45628a548a3b34583707ebcc68bb6f83ec48ca273aab4a510f1
    ["sqlcipher-LICENSE"]=2a2826f6acf46fa650730cf42cbb22a642be33a7ef119c9c4f4bf6daf3bef48e
    ["tomlplusplus-LICENSE"]=529bc3900a9571e49db285b0df432397e70b881cc3bf48de6667ae74ff4b06d8
    ["zip-LICENSE"]=6c1643ab0353b42030e903654fdb3845570b741da5ffafcaf9d305e8ec79a4a0
    ["miniz-LICENSE"]=0115478d567121238cf6cc1c0c361926cf07a49d9e4c9e66da97fac6a01646b3
    ["CLI11-LICENSE"]=88cffe4600851e8dad1b8eb1e304d54286a89d2373a1b98f59cb969b9e967b90
    ["rang-LICENSE"]=88d9b4eb60579c191ec391ca04c16130572d7eedc4a86daa58bf28c6e14c9bcd
    ["fzf-LICENSE"]=c308be1be029070dd6a9c1134e19c398169eb9cfbd5f078fb002659db1e1b7cc
    ["emoji-segmenter-LICENSE"]=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
    ["unicode-data-LICENSE"]=e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96
    ["geist-mono-OFL"]=1781d2806a07d91c4edf4740b88449fab7d0eadad53f7c351b94cd4d4eb8c00f
    ["outfit-OFL"]=c676351bf8576b9aba743cd5eaa8c0e7ee0d51f805d720447b4df4ddb6a2e416
    ["noto-sans-math-OFL"]=c9c63b8ed6cf76b2ce0c58b241acfc1195c2c928334c989c7047cbdac58773d9
    ["noto-sans-symbols-OFL"]=b118dd41337806a5d4797052c77caf3bd096aed783e5eb21b4d11154351e1ac0
    ["devicon-LICENSE"]=121194741d4a915b9f5890fdd6dd95121f9b1f816517c792358d72d7c838d664
    ["wayland-protocols-COPYING"]=f1a2b233e8a9a71c40f4aa885be08a0842ac85bb8588703c1dd7e6e6502e3124
  )
  local -a installed=()

  [[ -d $notice_root && ! -L $notice_root ]] || return 1
  [[ $(stat -c '%U:%G:%a' "$notice_root") == root:root:755 ]] || return 1
  if find "$notice_root" -mindepth 1 ! -type f -print -quit | grep -q .; then
    return 1
  fi
  mapfile -t installed < <(
    find "$notice_root" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' |
      LC_ALL=C sort
  )
  ((${#installed[@]} == ${#digests[@]})) || return 1
  for notice in "${installed[@]}"; do
    [[ -v digests[$notice] ]] || return 1
    [[ $(stat -c '%U:%G:%a' "$notice_root/$notice") == root:root:644 ]] ||
      return 1
    expected=${digests[$notice]}
    sha256_matches "$notice_root/$notice" "$expected" || return 1
  done
}

vicinae_native_linkage_valid() {
  local elf ldd_output resolved
  local -a executables=(
    /usr/bin/vicinae
    /usr/libexec/vicinae/vicinae-browser-link
    /usr/libexec/vicinae/vicinae-data-control-server
    /usr/libexec/vicinae/vicinae-file-indexer
    /usr/libexec/vicinae/vicinae-input-server
    /usr/libexec/vicinae/vicinae-server
  )

  for elf in "${executables[@]}"; do
    [[ -f $elf && ! -L $elf && -x $elf ]] || return 1
    ldd_output=$(
      LC_ALL=C timeout 20s env \
        -u LD_LIBRARY_PATH -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG \
        /usr/bin/ldd -r "$elf" 2>&1
    ) || return 1
    ! grep -Eq 'not found|undefined symbol:' <<<"$ldd_output" || return 1
    while read -r resolved; do
      resolved=$(readlink -e -- "$resolved") || return 1
      [[ $resolved == /usr/lib/* ]] || return 1
    done < <(sed -n 's/.*=> \(\/[^ ]*\) .*/\1/p' <<<"$ldd_output")
  done
}

vicinae_system_qt_glib_valid() {
  local ldd_output qt_core_dynamic qt_core_symbols resolved soname
  local server=/usr/libexec/vicinae/vicinae-server
  local -A expected_mappings=(
    [libQt6Core_so_6]=/usr/lib/libQt6Core.so.6
    [libQt6Qml_so_6]=/usr/lib/libQt6Qml.so.6
    [libqt6keychain_so_1]=/usr/lib/libqt6keychain.so.1
  )

  qt_core_dynamic=$(readelf -d /usr/lib/libQt6Core.so.6) || return 1
  grep -Fq 'Shared library: [libglib-2.0.so.0]' <<<"$qt_core_dynamic" ||
    return 1
  qt_core_symbols=$(readelf --wide --dyn-syms /usr/lib/libQt6Core.so.6) ||
    return 1
  grep -Fq 'QEventDispatcherGlib13processEvents' <<<"$qt_core_symbols" ||
    return 1
  [[ $(pacman -Qoq /usr/lib/libQt6Core.so.6) == qt6-base ]] || return 1
  [[ $(pacman -Qoq /usr/lib/libQt6Qml.so.6) == qt6-declarative ]] || return 1
  [[ $(pacman -Qoq /usr/lib/libqt6keychain.so.1) == qtkeychain-qt6 ]] || return 1
  [[ $(pacman -Qoq /usr/lib/libsecret-1.so.0) == libsecret ]] || return 1
  grep -aFq 'secret-1' /usr/lib/libqt6keychain.so.1 || return 1

  ldd_output=$(
    LC_ALL=C timeout 20s env \
      -u LD_LIBRARY_PATH -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG \
      /usr/bin/ldd -r "$server" 2>&1
  ) || return 1
  ! grep -Eq 'not found|undefined symbol:' <<<"$ldd_output" || return 1
  for soname in libQt6Core.so.6 libQt6Qml.so.6 libqt6keychain.so.1; do
    resolved=$(
      awk -v library="$soname" \
        '$1 == library && $2 == "=>" { print $3 }' <<<"$ldd_output"
    ) || return 1
    [[ $resolved == "${expected_mappings[${soname//./_}]}" ]] || return 1
  done

  ! readelf --wide --dyn-syms "$server" | grep -Fq '@Qt_6_PRIVATE_API' ||
    return 1
  [[ ! -e /run/systemd/user/vicinae.service &&
    ! -L /run/systemd/user/vicinae.service ]] ||
    return 1
  sudo -n /usr/libexec/vicinae/vicinae-build-compatible
}

vicinae_active_runtime_mapping_valid() {
  local main_pid maps library
  local -a required_libraries=(
    libQt6Core.so
    libQt6Qml.so
    libglib-2.0.so
    libsecret-1.so
  )

  main_pid=$(systemctl --user show vicinae.service -P MainPID) || return 1
  [[ $main_pid =~ ^[1-9][0-9]*$ && -r /proc/$main_pid/maps ]] || return 1
  maps=$(<"/proc/$main_pid/maps") || return 1
  ! grep -Fq ' /opt/' <<<"$maps" || return 1
  for library in "${required_libraries[@]}"; do
    grep -Eq " /usr/lib/${library//./\\.}([.][0-9]+)*([[:space:]]|$)" \
      <<<"$maps" || return 1
  done
}

vicinae_desktop_entries_valid() {
  local launcher=/usr/share/applications/vicinae.desktop
  local uri_handler=/usr/share/applications/vicinae-url-handler.desktop

  sha256_matches \
    "$launcher" \
    e67900456fd1c29defcf0f5ca1e78de9aab7241bebb5290c2725efa99dd61079 ||
    return 1
  sha256_matches \
    "$uri_handler" \
    e6be7ddb52ccdeb8872a512cbe7b193a1260d8376bd97785d865dc64af578133 ||
    return 1
  grep -Fxq 'Exec=vicinae-control toggle' "$launcher" || return 1
  grep -Fxq 'TryExec=vicinae-control' "$launcher" || return 1
  grep -Fxq 'Exec=vicinae-control uri %u' "$uri_handler" || return 1
  grep -Fxq 'TryExec=vicinae-control' "$uri_handler" || return 1
  ! grep -Fq 'server --replace' "$launcher" "$uri_handler" || return 1
  desktop-file-validate "$launcher" "$uri_handler"
}

vicinae_uri_associations_valid() {
  local scheme

  for scheme in vicinae raycast com.raycast; do
    [[ $(xdg-mime query default "x-scheme-handler/$scheme" 2>/dev/null) == vicinae-url-handler.desktop ]] || return 1
  done
}

vicinae_service_policy_valid() (
  local properties
  local keyring_helper=$HOME/.local/libexec/vicinae-keyring-ready
  local server_helper=$HOME/.local/libexec/vicinae-server-ready

  sha256_matches \
    /usr/lib/systemd/user/vicinae.service \
    6f2e12e55d1dd179d40557a8386fed5ad081b5897fe38508567c1eceaf3bc7d1 ||
    return 1
  # Keep LoadUnit and GetAll on one sd-bus connection. A headless, inactive
  # unit can otherwise be garbage-collected between short busctl processes.
  properties=$(
    systemctl --user show vicinae.service --no-pager \
      --property=Environment \
      --property=EnvironmentFiles \
      --property=UnsetEnvironment \
      --property=ExecCondition \
      --property=ExecStart \
      --property=ExecStartPre \
      --property=ExecStartPost \
      --property=ExecReload \
      --property=ExecStop \
      --property=ExecStopPost \
      --property=ExecSearchPath \
      --property=FragmentPath \
      --property=DropInPaths \
      --property=KillMode \
      --property=Restart \
      --property=RestartUSec \
      --property=TimeoutStartUSec \
      --property=TimeoutStopUSec \
      --property=StartLimitIntervalUSec \
      --property=StartLimitBurst
  ) || return 1
  vicinae_effective_service_policy_valid \
    "$properties" "$keyring_helper" "$server_helper"
)

vicinae_performance_scripts_valid() {
  local scripts_dir=$HOME/.local/share/vicinae/scripts
  local script
  local -a scripts=()

  [[ -d $scripts_dir ]] || return 1
  mapfile -d '' -t scripts < <(
    find "$scripts_dir" -maxdepth 1 -type f \
      -name 'performance-*.sh' -print0 |
      sort -z
  )
  ((${#scripts[@]} == 8)) || return 1
  for script in "${scripts[@]}"; do
    [[ -x $script ]] || return 1
    vicinae script check "$script" || return 1
  done
}

vicinae_accessibility_scripts_valid() {
  local scripts_dir=$HOME/.local/share/vicinae/scripts
  local script
  local -a scripts=()

  [[ -d $scripts_dir ]] || return 1
  mapfile -d '' -t scripts < <(
    find "$scripts_dir" -maxdepth 1 -type f \
      -name 'accessibility-*.sh' -print0 |
      sort -z
  )
  ((${#scripts[@]} == 2)) || return 1
  for script in "${scripts[@]}"; do
    [[ -x $script ]] || return 1
    vicinae script check "$script" || return 1
  done
}

echo "==> Packages"
while IFS= read -r package; do
  check "pacman package installed: $package" pacman -Q "$package"
done < <(
  for manifest in \
    "$repo_root/packages/native.txt" \
    "$repo_root/packages/management.txt" \
    "$repo_root/packages/optional-deps.txt" \
    "$repo_root/packages/aur.txt"; do
    manifest_entries "$manifest"
  done | sort -u
)

if jq -e '.desktop_accessibility_profile_enabled == true' \
  <<<"$inventory_host_json" >/dev/null 2>&1; then
  check "opt-in Orca screen reader package installed" pacman -Q orca
  check "opt-in Orca screen reader executable responds" orca --version
  orca_desktop_entry=$(
    pacman -Ql orca |
      awk '$2 ~ "^/usr/share/applications/.+\\.desktop$" { print $2; exit }'
  )
  check "opt-in Orca desktop entry is installed" test -n "$orca_desktop_entry"
  if [[ -n $orca_desktop_entry ]]; then
    check "opt-in Orca desktop entry validates" \
      desktop-file-validate "$orca_desktop_entry"
  fi
else
  skip "opt-in Orca screen reader package" \
    "desktop_accessibility_profile_enabled is false"
fi

while IFS= read -r package; do
  check "local package installed: $package" pacman -Q "$package"
done < <(find "$repo_root/packages/local" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

check "source-built Codex Desktop package installed" pacman -Q codex-desktop
check "source-built Codex Desktop launcher installed" test -x /usr/bin/codex-desktop
check "source-built Codex Desktop updater installed" test -x /usr/bin/codex-update-manager

while IFS= read -r package; do
  # pacman -Q <name> accepts providers, so it would report tlp-pd as an
  # installed power-profiles-daemon. Compare against actual database names.
  if pacman -Qq | grep -Fxq -- "$package"; then
    fail "package is intentionally absent: $package"
  else
    pass "package is intentionally absent: $package"
  fi
done < <(manifest_entries "$repo_root/packages/absent.txt")

check "multilib repository enabled" bash -c \
  "pacman-conf --repo-list | grep -Fxq multilib"

echo "==> Performance observability"
check "journald uses persistent storage" \
  effective_systemd_setting systemd/journald.conf Journal Storage persistent
check "journald compresses retained records" \
  effective_systemd_setting systemd/journald.conf Journal Compress yes
check "journald storage is capped at 1 GiB" \
  effective_systemd_setting systemd/journald.conf Journal SystemMaxUse 1G
check "journald preserves 2 GiB of filesystem space" \
  effective_systemd_setting systemd/journald.conf Journal SystemKeepFree 2G
check "journald retention is capped at 30 days" \
  effective_systemd_setting systemd/journald.conf Journal MaxRetentionSec 30day
# The child shell owns the command substitution in these mode checks.
# shellcheck disable=SC2016
check "persistent journal directory ownership and mode are managed" bash -c \
  '[[ $(stat -c "%U:%G:%a" /var/log/journal) == root:systemd-journal:2755 ]]'
check "systemd-journald is active" \
  systemctl is-active --quiet systemd-journald.service
# shellcheck disable=SC2016
check "systemd default IO accounting is live" bash -c \
  '[[ $(systemctl show -P DefaultIOAccounting) == yes ]]'

check "atop collection interval and retention are configured" \
  atop_history_policy_configured
# shellcheck disable=SC2016
check "atop history directory is private" bash -c \
  '[[ $(stat -c "%U:%G:%a" /var/log/atop) == root:root:700 ]]'
# shellcheck disable=SC2016
check "atop fallback accounting directory is private" bash -c \
  '[[ $(stat -c "%U:%G:%a" /var/cache/atop.d) == root:root:700 ]]'
check "atop crash-unsafe fallback accounting file is absent" sudo -n \
  test ! -e /var/cache/atop.d/atop.acct
# shellcheck disable=SC2016
check "atop writes files with a private umask" bash -c \
  '[[ $(systemctl show atop.service -P UMask) == 0077 ]]'
# shellcheck disable=SC2016
check "atop restarts after collector failures" bash -c \
  '[[ $(systemctl show atop.service -P Restart) == on-failure ]]'
# shellcheck disable=SC2016
check "atop uses bounded restart attempts" bash -c \
  '[[ $(systemctl show atop.service -P StartLimitIntervalUSec) == 1min ]] &&
   [[ $(systemctl show atop.service -P StartLimitBurst) == 5 ]]'
check "atop process accounting is disabled" \
  unit_disabled_and_inactive atopacct.service
check "running atop has process accounting explicitly disabled" \
  atop_process_accounting_disabled
check "optional atop GPU collector is disabled" \
  unit_disabled_and_inactive atopgpu.service
for unit in atop.service atop-rotate.timer; do
  check "$unit enabled" systemctl is-enabled --quiet "$unit"
  check "$unit active" systemctl is-active --quiet "$unit"
done
check "atop has written recent parseable local history" \
  atop_history_recent_and_readable

check "sysstat retains 28 days with private files" \
  sysstat_history_policy_configured
check "sysstat collection timer uses the 30-second schedule" \
  sysstat_timer_policy_configured
# shellcheck disable=SC2016
check "sysstat history directory is private" bash -c \
  '[[ $(stat -c "%U:%G:%a" /var/log/sa) == root:root:700 ]]'
for unit in \
  sysstat.service \
  sysstat-collect.timer \
  sysstat-rotate.timer \
  sysstat-summary.timer; do
  check "$unit enabled" systemctl is-enabled --quiet "$unit"
  check "$unit active" systemctl is-active --quiet "$unit"
done
# shellcheck disable=SC2016
check "latest sysstat collection completed successfully" bash -c \
  '[[ $(systemctl show sysstat-collect.service -P Result) == success ]]'
check "sysstat has written recent parseable local history" \
  sysstat_history_recent_and_readable
check "persistent journal contains a current-boot record" sudo -n bash -c \
  'journalctl --directory=/var/log/journal -b 0 --no-pager -n 1 --output=short-unix | grep -q .'

echo "==> Power and sleep"
if capability battery; then
  for unit in tlp.service tlp-pd.service rtkit-daemon.service; do
    check "$unit enabled" systemctl is-enabled --quiet "$unit"
  done
  check "tlp-pd active" systemctl is-active --quiet tlp-pd.service
  check "RealtimeKit active" systemctl is-active --quiet rtkit-daemon.service
  check "TLP reports an active profile" tlp-stat -s
  check "TLP profile compatibility API is available" tlpctl get
  check "s2idle is the selected suspend mode" bash -c \
    "grep -q '\[s2idle\]' /sys/power/mem_sleep"
  check "no TLP charge threshold is configured" bash -c \
    "! grep -RqsE '^[[:space:]]*(START|STOP)_CHARGE_THRESH_' /etc/tlp.conf /etc/tlp.d"
else
  skip "battery and TLP policy checks" \
    "capability battery=false" "battery-charge-threshold"
  check "RealtimeKit active" systemctl is-active --quiet rtkit-daemon.service
fi

echo "==> Authentication and login"
for pam_file in /etc/pam.d/greetd /etc/pam.d/sddm; do
  check "$pam_file captures the login password for GNOME Keyring" \
    grep -qE '^[[:space:]]*-?auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so' "$pam_file"
  check "$pam_file starts and unlocks GNOME Keyring for the session" \
    grep -qE '^[[:space:]]*-?session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so[[:space:]]+auto_start' "$pam_file"
done
if capability fingerprint; then
  check_or_warn "fingerprint enrolled for the current user (manual enrollment if absent)" \
    fprintd-list "${USER:-$(id -un)}"
  for pam_file in /etc/pam.d/greetd /etc/pam.d/sddm /etc/pam.d/sudo; do
    check "$pam_file has fingerprint authentication" grep -q pam_fprintd.so "$pam_file"
    check "$pam_file keeps password-first authentication" grep -q 'pam_unix.so.*try_first_pass.*likeauth' "$pam_file"
  done
else
  skip "fingerprint enrollment and PAM checks" \
    "capability fingerprint=false" "fingerprint-enrollment"
fi
check "greetd is the boot display manager" systemctl is-enabled --quiet greetd.service
check "fallback SDDM is disabled" bash -c \
  '! systemctl is-enabled --quiet sddm.service'
# The inner expression is intentionally evaluated by bash -c.
# shellcheck disable=SC2016
check "display-manager alias selects greetd" bash -c \
  '[[ $(readlink -f /etc/systemd/system/display-manager.service) == /usr/lib/systemd/system/greetd.service ]]'
check "greetd uses the isolated Enoshima Auth compositor" grep -Fq \
  'command = "dbus-run-session start-hyprland -- -c /etc/greetd/hyprland.lua"' \
  /etc/greetd/config.toml
# The inner expression is intentionally evaluated by bash -c.
# shellcheck disable=SC2016
check "greetd configuration is world-readable but root-owned" bash -c \
  '[[ $(stat -c "%U:%G:%a" /etc/greetd/config.toml) == root:root:644 &&
      $(stat -c "%U:%G:%a" /etc/greetd/hyprland.lua) == root:root:644 ]]'
check "Enoshima Auth mixed-DPI compositor configuration parses" \
  env \
  GREETD_HYPRCTL=/usr/bin/true \
  GREETD_ENOSHIMA_GREETER=/usr/bin/true \
  GREETD_LID_STATE_ROOT=/dev/null \
  Hyprland --verify-config -c /etc/greetd/hyprland.lua
check "deprecated Enoshima Auth Hyprland configuration is absent" \
  test ! -e /etc/greetd/hyprland.conf
check "Enoshima Auth greeter binary is installed" test -x /usr/bin/enoshima-greeter
check "Enoshima Auth greeter self-test passes" enoshima-greeter --self-test
check "Enoshima Auth semantic stylesheet is installed" test -f /etc/greetd/enoshima-greeter.css
check "superseded ReGreet configuration is absent" bash -c \
  '[[ ! -e /etc/greetd/regreet.toml && ! -e /etc/greetd/regreet.css ]]'
check "Enoshima Auth lid-aware session helper is executable" \
  test -x /usr/local/lib/enoshima/greetd-session
check "Enoshima Auth crop-safe wallpaper is installed intact" sha256_matches \
  /etc/greetd/background-16x10.jpg \
  784c66002966e57a2ab0e5ae2413c3faee7b93a8c656d203899d41b25faffafb
# The inner expression is intentionally evaluated by bash -c.
# shellcheck disable=SC2016
check "enoshima Desktop login session is the only visible Hyprland session" \
  bash -c '
    entry=/usr/local/share/wayland-sessions/enoshima-desktop.desktop
    legacy=/usr/local/share/wayland-sessions/enoshima-hyprland-uwsm.desktop
    [[ ! -e $legacy ]] &&
      grep -Fxq "Name=enoshima Desktop" "$entry" &&
      grep -Fxq "Exec=uwsm start -e -D Hyprland start-hyprland" "$entry" &&
      command -v start-hyprland >/dev/null &&
      for override in hyprland.desktop hyprland-uwsm.desktop; do
        path=/usr/local/share/wayland-sessions/$override
        grep -Fxq "Hidden=true" "$path" &&
          grep -Fxq "NoDisplay=true" "$path" || exit 1
      done
  '
check "vi resolves to Vim" bash -c \
  "[[ \$(readlink -f /usr/local/bin/vi) == /usr/bin/vim ]]"
# The inner expression is intentionally evaluated by bash -c.
# shellcheck disable=SC2016
check "login shell is Zsh" bash -c \
  '[[ $(getent passwd "${USER:-$(id -un)}" | cut -d: -f7) == /bin/zsh ]]'
check "Oh My Zsh is installed from the managed package" \
  test -r /usr/share/oh-my-zsh/oh-my-zsh.sh
check "fastfetch configuration deployed" \
  test -f "$HOME/.config/fastfetch/config.jsonc"
for shell_package in \
  bat \
  eza \
  fzf-tab \
  starship \
  zoxide \
  zsh-autosuggestions \
  zsh-completions \
  zsh-syntax-highlighting; do
  check "managed shell package installed: $shell_package" \
    pacman -Q -- "$shell_package"
done
check "Starship configuration deployed" \
  test -f "$HOME/.config/starship.toml"
check "developer Zsh plugins load in their managed order" \
  zsh_developer_plugins_loaded

echo "==> Git credentials"
mapfile -t global_git_credential_helpers < <(
  git config --global --get-all credential.helper 2>/dev/null || true
)
if ((${#global_git_credential_helpers[@]} == 1)) &&
  [[ ${global_git_credential_helpers[0]} == store ]]; then
  pass "global Git credential helper is exactly store"
else
  fail "global Git credential helper must be exactly store"
  git config \
    --global \
    --show-origin \
    --show-scope \
    --get-all credential.helper >&2 || true
fi

credential_files=(
  "$HOME/.git-credentials"
  "${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials"
)
for credential_file in "${credential_files[@]}"; do
  [[ -e $credential_file ]] || continue

  mode=$(stat -c '%a' "$credential_file" 2>/dev/null || true)
  if [[ $mode =~ ^[0-7]+$ ]] && (((8#$mode & 077) == 0)); then
    pass "Git credential file is private: $credential_file ($mode)"
  else
    fail "Git credential file is accessible by group/others: $credential_file (${mode:-unknown})"
  fi
done

echo "==> Development runtimes"
mise_config=$HOME/.config/mise/config.toml
check "mise global runtime configuration deployed" test -f "$mise_config"
runtime_names=(Node.js Python Go Rust uv)
runtime_bins=(node python go rustc uv)
for index in "${!runtime_names[@]}"; do
  check "mise runtime active: ${runtime_names[$index]}" env \
    MISE_CONFIG_FILE="$mise_config" mise which "${runtime_bins[$index]}"
done

echo "==> Hardware integration"
if capability hibernation; then
  # The command substitution must inspect the live mount in the child shell.
  # shellcheck disable=SC2016
  check "dedicated hibernation swap subvolume is mounted" bash -c \
    '[[ $(findmnt -n -o FSTYPE /swap) == btrfs ]] && findmnt -n -o OPTIONS /swap | grep -Fq subvol=/@swap'
  # The pipeline must inspect the live swap table in the child shell.
  # shellcheck disable=SC2016
  check "disk-backed hibernation swap is active" bash -c \
    'swapon --show=NAME --noheadings --raw | grep -Fxq /swap/swapfile'
  check "kernel command line declares the Btrfs resume mapping" bash -c \
    'grep -Eq "(^| )resume=UUID=[0-9a-f-]+ resume_offset=[1-9][0-9]*($| )" /etc/kernel/cmdline'
  check "systemd sleep policy enables suspend-then-hibernate" bash -c \
    'systemd-analyze cat-config systemd/sleep.conf | grep -Fxq "AllowSuspendThenHibernate=yes"'
  check "systemd-logind owns the lid policy" bash -c \
    'systemd-analyze cat-config systemd/logind.conf | grep -Fxq "HandleLidSwitch=suspend-then-hibernate"'
  check_or_warn "systemd-logind reports hibernation available after rebooting the rebuilt UKI" bash -c \
    'busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate | grep -Eq "\\\"(yes|challenge)\\\""'
else
  skip "Btrfs hibernation and resume checks" \
    "capability hibernation=false" "hibernation"
fi

check "NetworkManager active" systemctl is-active --quiet NetworkManager.service
if capability wwan; then
  check "ModemManager active" systemctl is-active --quiet ModemManager.service
  check "Lenovo WWAN configuration service enabled" systemctl is-enabled --quiet lenovo-cfgservice.service
  check "Lenovo WWAN SAR configuration completed successfully" lenovo_sar_run_succeeded
  for regulatory_profile in 29619 30007; do
    check "Gen 13 RM520N-GL SAR profile installed: $regulatory_profile" bash -c \
      "compgen -G '/opt/fcc_lenovo/sar_config_files/cs25/*RM520NGL*ThinkPad-X1-Carbon-Gen-13*21NX*$regulatory_profile.bin' >/dev/null"
  done
  check_or_warn "at least one GSM connection profile exists (manual APN credentials if absent)" bash -c \
    "nmcli -g TYPE connection show | grep -Fxq gsm"
  check "WWAN fallback dispatcher installed" test -x /etc/NetworkManager/dispatcher.d/90-wwan-fallback
  check "WWAN shutdown quiesce service enabled" \
    systemctl is-enabled --quiet enoshima-wwan-quiesce.service
  check "WWAN shutdown helper installed" test -x /usr/local/libexec/enoshima-wwan-quiesce
  # The command substitution must run in the child shell used by the check.
  # shellcheck disable=SC2016
  check "ModemManager stop timeout is bounded" bash -c \
    '[[ $(systemctl show ModemManager.service -P TimeoutStopUSec) == 15s ]]'

  if journalctl -b -u lenovo-cfgservice.service --no-pager 2>/dev/null |
    grep -Eqi '(No such file|SAR.*(fail|error)|failed to open.*\.bin)'; then
    warn "Lenovo WWAN service journal still contains a SAR-file error"
  else
    pass "Lenovo WWAN service journal has no known SAR-file error"
  fi

  if mmcli -L -J 2>/dev/null |
    jq -e '."modem-list" | length > 0' >/dev/null 2>&1; then
    pass "ModemManager detects a modem"
  else
    warn "no modem is currently visible (check BIOS, SIM, RF kill, and Lenovo service)"
  fi
else
  skip "WWAN modem, SAR, dispatcher, and shutdown checks" \
    "capability wwan=false" "wwan-modem"
fi

if capability camera; then
  check "RGB UVC camera present" grep -qs '^Integrated Camera: Integrated C' /sys/class/video4linux/*/name
  check "IR UVC camera present" grep -qs '^Integrated Camera: Integrated I' /sys/class/video4linux/*/name
else
  skip "integrated camera device checks" \
    "capability camera=false" "camera-device"
fi

if capability fingerprint; then
  check "fingerprint reader present" bash -c \
    "lsusb | grep -Fq '06cb:0123'"
else
  skip "fingerprint reader device check" \
    "capability fingerprint=false" "fingerprint-device"
fi

if ! capability thunderbolt; then
  skip "Thunderbolt controller checks" \
    "capability thunderbolt=false" "thunderbolt-controller"
fi
if ! capability external_display; then
  skip "physical external-display checks" \
    "capability external_display=false" "external-display"
fi
if capability btrfs_layout; then
  # The command substitution must inspect the live mount in the child shell.
  # shellcheck disable=SC2016
  check "root filesystem uses the managed Btrfs layout" bash -c \
    '[[ $(findmnt -n -o FSTYPE /) == btrfs ]] && findmnt -n -o OPTIONS / | grep -Fq subvol=/@'
else
  skip "managed Btrfs root-layout checks" \
    "capability btrfs_layout=false" "btrfs-layout"
fi
if capability root_luks; then
  # The wildcard applies to findmnt output inside the child shell.
  # shellcheck disable=SC2016
  check "root filesystem is backed by the managed LUKS mapping" bash -c \
    '[[ $(findmnt -n -o SOURCE /) == /dev/mapper/cryptroot* ]]'
else
  skip "root LUKS mapping checks" \
    "capability root_luks=false" "root-luks"
fi
if capability boot_artifacts; then
  check "transactional UKI rebuild helper is installed" \
    test -x /usr/local/libexec/enoshima-rebuild-uki
  check "managed boot artifacts were explicitly applied" \
    test -f /var/lib/enoshima/boot-artifacts-applied
  check "managed kernel command line is present" test -s /etc/kernel/cmdline
  check "managed initramfs crypttab is present" test -s /etc/crypttab.initramfs
  check "managed UKIs are present" sudo -n bash -c \
    'compgen -G "/efi/EFI/Linux/arch-*.efi" >/dev/null'
else
  skip "managed boot artifact checks" \
    "capability boot_artifacts=false" "boot-artifacts"
fi
if capability secure_boot; then
  # The EFI variable glob and command substitution belong to the child shell.
  # shellcheck disable=SC2016
  check_or_warn "firmware reports Secure Boot enabled" bash -c \
    '[[ $(od -An -j4 -N1 -tu1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | tr -d " ") == 1 ]]'
  # The image loop belongs to the child shell.
  # shellcheck disable=SC2016
  check_or_warn "managed UKIs carry a Secure Boot signature" sudo -n bash -c \
    'certificate=/var/lib/sbctl/keys/db/db.pem; [[ -r $certificate ]] || exit 1; for image in /efi/EFI/Linux/arch-*.efi; do [[ $image == *-unsigned.efi ]] && continue; sbverify --cert "$certificate" "$image" >/dev/null || exit 1; done'
else
  skip "Secure Boot enforcement checks" \
    "capability secure_boot=false" "secure-boot"
fi
if capability tpm; then
  check "TPM 2.0 resource manager is present" test -c /dev/tpmrm0
  # Device discovery and expansion belong to the child shell.
  # shellcheck disable=SC2016
  check_or_warn "root LUKS volume has a TPM2 enrollment" bash -c \
    'device=$(cryptsetup status cryptroot 2>/dev/null | sed -n "s/^[[:space:]]*device:[[:space:]]*//p"); [[ -n $device ]] && sudo -n systemd-cryptenroll "$device" | grep -Fq tpm2'
else
  skip "TPM enrollment and unlock checks" \
    "capability tpm=false" "tpm-unlock"
fi

echo "==> Desktop session"
for unit in \
  cyberdock.service \
  cyberdock-event-bridge.service \
  desktop-display-events.service \
  desktop-power-verify.service \
  kakaotalk-focus-guard.service \
  xembed-sni-proxy.service; do
  check "custom user unit enabled: $unit" systemctl --user is-enabled --quiet "$unit"
done
for unit in hyprshell.service vicinae.service; do
  check "packaged desktop user unit enabled: $unit" \
    systemctl --user is-enabled --quiet "$unit"
done

check "official hyprfocus plugin is enabled" hyprpm_plugin_enabled hyprfocus
if hyprpm_plugin_enabled hyprbars; then
  fail "retired hyprbars plugin is disabled"
else
  pass "retired hyprbars plugin is disabled"
fi
check "Enoshima titlebar plugin matches the installed Hyprland ABI" \
  enoshima_decoration_installed
check "desktop appearance accessibility helper is deployed" \
  test -x "$HOME/.local/bin/desktop-appearance"

check "Bottles Flatpak installed for the user" flatpak info --user com.usebottles.bottles

if systemctl --user is-active --quiet graphical-session.target; then
  hyprland_config_errors=$(hyprctl configerrors 2>/dev/null || true)
  if [[ -z $hyprland_config_errors ]]; then
    pass "Hyprland reports no live configuration errors"
  else
    fail "Hyprland reports one or more live configuration errors"
    printf '%s\n' "$hyprland_config_errors" >&2
  fi

  for unit in \
    pipewire.service \
    pipewire-pulse.service \
    wireplumber.service \
    xdg-desktop-portal-hyprland.service \
    cyberdock.service \
    cyberdock-event-bridge.service \
    desktop-display-events.service \
    kakaotalk-focus-guard.service \
    hyprshell.service \
    vicinae.service \
    xembed-sni-proxy.service; do
    check_or_warn "user unit active after login: $unit" systemctl --user is-active --quiet "$unit"
  done

  check_or_warn "Hyprland session is managed by UWSM (select it at the next login if absent)" \
    systemctl --user is-active --quiet wayland-wm@hyprland.desktop.service
  check_or_warn "Fcitx daemon is reachable after login" fcitx5-remote
  check_or_warn "Fcitx XIM environment imported into user manager (new login if absent)" bash -c \
    "systemctl --user show-environment | grep -Fxq 'XMODIFIERS=@im=fcitx'"
  check_or_warn "Secret Service is available for application credentials after login" \
    timeout --signal=TERM --kill-after=1s 5s \
    busctl --user --quiet status org.freedesktop.secrets
  check_or_warn "Vicinae server responds after login" \
    timeout --signal=TERM --kill-after=1s 5s /usr/bin/vicinae ping
  check_or_warn "Vicinae active server maps only the reviewed system runtime" \
    vicinae_active_runtime_mapping_valid
  check_or_warn "graphical session imports mise shims (log out once if absent)" bash -c \
    "systemctl --user show-environment | grep -Eq '^PATH=.*/\.local/share/mise/shims'"
  check_or_warn "hyprfocus plugin is loaded in the active compositor" hyprfocus_loaded
  check_or_warn "Enoshima titlebar plugin is loaded in the active compositor" \
    enoshima_decoration_loaded
  check_or_warn "hyprfocus uses the managed schema and accessibility mode" \
    hyprfocus_configured
else
  warn "no graphical session is active; live user-service, UWSM, Fcitx, and Secret Service checks are deferred until login"
fi

if command -v hyprctl >/dev/null 2>&1 && hyprctl monitors -j >/dev/null 2>&1; then
  monitor_json=$(hyprctl monitors -j)
  display_mode=unknown
  if command -v desktop-display-mode >/dev/null 2>&1; then
    display_status=$(desktop-display-mode status --json 2>/dev/null || true)
    display_mode=$(jq -r '.mode // "unknown"' <<<"$display_status" 2>/dev/null || printf unknown)
  fi
  if [[ $profile == enoshima-vm ]] &&
    jq -e 'length >= 1 and all(.[]; .name | test("^(HEADLESS-|Virtual-)"))' \
      <<<"$monitor_json" >/dev/null; then
    workspace_json=$(hyprctl workspaces -j)
    if jq -e --argjson monitors "$monitor_json" \
      'all(.[]; .monitor as $current | any($monitors[]; .name == $current))' \
      <<<"$workspace_json" >/dev/null; then
      pass "VM workspaces are confined to the reviewed virtual outputs"
    else
      fail "a VM workspace references an unavailable virtual output"
    fi
  else
    case $display_mode in
      internal)
        if jq -e 'length == 1 and .[0].name == "eDP-1"' <<<"$monitor_json" >/dev/null; then
          pass "saved internal-only display mode is active"
        else
          fail "internal-only display mode does not have exactly one internal output"
        fi
        ;;
      external)
        if jq -e 'length == 1 and .[0].name != "eDP-1"' <<<"$monitor_json" >/dev/null; then
          pass "saved external-only display mode is active"
        else
          fail "external-only display mode does not have exactly one external output"
        fi
        ;;
      mirror)
        if jq -e 'length >= 2 and any(.[]; (.mirrorOf // "none") != "none")' <<<"$monitor_json" >/dev/null; then
          pass "saved duplicate display mode is active"
        else
          fail "duplicate display mode has no mirrored output"
        fi
        ;;
      extend)
        if jq -e '.[] | select(.name == "eDP-1") | select(.width == 2880 and .height == 1800 and .refreshRate >= 119 and .scale == 1.5 and .x == 0 and .y == 240)' \
          <<<"$monitor_json" >/dev/null; then
          pass "extended internal display uses the managed 2880x1800 seed"
        else
          warn "extended internal layout differs from the seed because a confirmed topology preference may be active"
        fi
        workspace_json=$(hyprctl workspaces -j)
        mapfile -t external_outputs < <(
          jq -r '
          map(select(.name != "eDP-1" and (.mirrorOf // "none") == "none"))
          | sort_by(.x // 0, .y // 0, .name)
          | .[].name
        ' <<<"$monitor_json"
        )
        if ((${#external_outputs[@]} > 0)); then
          pass "${#external_outputs[@]} external display(s) are active in extended mode"
        else
          fail "extended mode has no external output"
        fi
        workspace_layout_ok=true
        external_workspace_ids=(1 2 4)
        if ((${#external_outputs[@]} > 0)); then
          for index in "${!external_workspace_ids[@]}"; do
            workspace_id=${external_workspace_ids[$index]}
            expected_output=${external_outputs[$((index % ${#external_outputs[@]}))]}
            actual_output=$(jq -r --argjson id "$workspace_id" \
              'map(select(.id == $id))[0].monitor // empty' <<<"$workspace_json")
            [[ $actual_output == "$expected_output" ]] || workspace_layout_ok=false
          done
        else
          workspace_layout_ok=false
        fi
        for workspace_id in 3 5; do
          actual_output=$(jq -r --argjson id "$workspace_id" \
            'map(select(.id == $id))[0].monitor // empty' <<<"$workspace_json")
          [[ $actual_output == eDP-1 ]] || workspace_layout_ok=false
        done
        if [[ $workspace_layout_ok == true ]]; then
          pass "five workspaces match the extended output map"
        else
          fail "workspaces do not match the extended output map"
        fi
        ;;
      *) warn "desktop-display-mode status is unavailable; live projection validation was deferred" ;;
    esac
  fi

  if [[ -z $(hyprctl configerrors) ]]; then
    pass "Hyprland reports no configuration errors"
  else
    fail "Hyprland reports configuration errors"
  fi

  if hyprctl getoption input:kb_options -j 2>/dev/null |
    jq -e '.str == "korean:ralt_hangul"' >/dev/null; then
    pass "Right Alt is mapped to the Hangul keysym"
  else
    fail "Right Alt is not mapped to the Hangul keysym"
  fi

  if hyprctl getoption xwayland:force_zero_scaling -j 2>/dev/null |
    jq -e '.bool == true' >/dev/null; then
    pass "XWayland zero scaling is active"
  else
    fail "XWayland zero scaling is not active"
  fi

  if hyprctl getoption general:resize_on_border -j 2>/dev/null |
    jq -e '.bool == true' >/dev/null; then
    pass "direct pointer resizing on tiled borders is active"
  else
    fail "direct pointer resizing on tiled borders is not active"
  fi
  if hypr-window-control-doctor --json 2>/dev/null | jq -e '.healthy' >/dev/null; then
    pass "effective pointer move/resize binds and border grab area are active"
  else
    fail "effective pointer window controls are incomplete"
  fi
else
  warn "Hyprland IPC is unavailable; display and live configuration checks were skipped"
fi

if [[ -d $HOME/.var/app/com.usebottles.bottles/data/bottles/bottles/KakaoTalk ]]; then
  pass "KakaoTalk Bottles prefix exists"
  check_or_warn "KakaoTalk profile, IME, tray and focus integration is healthy" bash -c \
    'kakaotalk-doctor --json | jq -e .healthy'
else
  warn "KakaoTalk bottle is not provisioned; run kakaotalk-setup interactively"
fi

echo "==> Desktop expansion"
check "Hyprshot CLI is callable" hyprshot --help
check "Kooha executable is installed" test -x /usr/bin/kooha
check "Kooha desktop entry is installed" \
  test -f /usr/share/applications/io.github.seadve.Kooha.desktop
check "Hyprshell overview configuration parses" \
  hyprshell -c "$HOME/.config/hyprshell/config.ron" config check
check "Hyprshell stylesheet is deployed" \
  test -s "$HOME/.config/hyprshell/styles.css"
check "Hyprshell is the pinned direct-input source build" \
  hyprshell_source_build_identity_valid
check "Hyprshell package source and patch provenance are pinned" \
  "$repo_root/scripts/check-hyprshell-provenance" --root "$repo_root"
check "Vicinae staged privacy policy is deployed" jq -e '
  .telemetry.system_info == false and
  .input_server.enabled == false and
  .global_shortcuts.toggle == "" and
  all(.providers[]?.entrypoints[]?; (.shortcut // "") == "") and
  .encrypt_sensitive_data == true and
  .providers.clipboard.preferences.ignorePasswords == true and
  .providers.clipboard.preferences.eraseOnStartup == true and
  .providers.files.enabled == false and
  .providers.files.preferences.autoIndexing == false
' "$HOME/.config/vicinae/settings.json"
check "Vicinae shortcut IPC is bounded" \
  test -x "$HOME/.local/bin/vicinae-control"
check "Vicinae waits for an unlocked login keyring" \
  test -x "$HOME/.local/libexec/vicinae-keyring-ready"
check "Vicinae server startup is bounded" \
  test -x "$HOME/.local/libexec/vicinae-server-ready"
check "Vicinae packaged service has the effective bounded keyring guard" \
  vicinae_service_policy_valid
check "Vicinae performance Script Commands validate" \
  vicinae_performance_scripts_valid
check "Vicinae accessibility Script Commands validate" \
  vicinae_accessibility_scripts_valid
check "Vicinae is the pinned stable upstream source build" \
  vicinae_source_build_identity_valid
check "Vicinae native runtime is safely source-built" \
  vicinae_native_runtime_valid
check "Vicinae reviewed bundled third-party notices are pinned" \
  vicinae_bundled_notices_valid
check "Vicinae system Qt keeps the GLib dispatcher and matches the build manifest" \
  vicinae_system_qt_glib_valid
check "Vicinae managed desktop entries cannot bypass the user service" \
  vicinae_desktop_entries_valid
check "Vicinae URI schemes select the managed service adapter" \
  vicinae_uri_associations_valid
check "Vicinae native linkage is complete after the full system upgrade" \
  vicinae_native_linkage_valid
check "Vicinae input helper has no elevated capability or set-ID bit" \
  vicinae_input_server_unprivileged
check "Vicinae package and ephemeral Qt guard hooks are pinned" \
  "$repo_root/scripts/check-vicinae-provenance" --root "$repo_root"
check "Vicinae global-input migration surfaces are absent" bash -c \
  '[[ ! -e /usr/lib/modules-load.d/vicinae.conf && ! -e /opt/vicinae && ! -e /etc/pacman.d/hooks/95-enoshima-vicinae-capability.hook && ! -e /usr/local/libexec/enoshima-vicinae-unprivileged ]]'
check "FileZilla executable is installed" \
  test -x /usr/bin/filezilla
check "FileZilla desktop entry is installed" \
  test -f /usr/share/applications/filezilla.desktop
if [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]; then
  check "FileZilla starts and reports its version" \
    filezilla_version_reports
else
  warn "FileZilla runtime smoke test skipped: no graphical display"
fi
check "Pear Desktop entry is installed" \
  test -f /usr/share/applications/com.github.th-ch.youtube-music.desktop
check "managed 16:9 cyberpunk wallpaper is deployed intact" \
  sha256_matches \
  "$HOME/.local/share/backgrounds/cyberpunk-library-16x9.jpg" \
  5b96bdca2bfc912164e2dec3ec5aec6f360e3c7ba6dabc7136afe39b618ce1cc
check "managed 16:10 cyberpunk wallpaper is deployed intact" \
  sha256_matches \
  "$HOME/.local/share/backgrounds/cyberpunk-library-16x10.jpg" \
  784c66002966e57a2ab0e5ae2413c3faee7b93a8c656d203899d41b25faffafb
check "Hyprpaper routes the 16:10 composition to eDP-1" \
  grep -Fq 'cyberpunk-library-16x10.jpg' "$HOME/.config/hypr/hyprpaper.conf"
check "Hyprlock keeps password and fingerprint authentication" \
  grep -Fq 'fingerprint {' "$HOME/.config/hypr/hyprlock.conf"
# HOME is intentionally expanded by the child Bash used for this compound check.
# shellcheck disable=SC2016
check "Hyprlock uses mixed-DPI responsive geometry" bash -c \
  'grep -Fq "fractional_scaling = 2" "$HOME/.config/hypr/hyprlock.conf" && grep -Fq "size = 468, 560" "$HOME/.config/hypr/hyprlock.conf"'
check "Waybar uses quiet persistent status and a secondary system drawer" \
  jq -e '
    .height == 48 and
    ."margin-top" == 14 and
    ."modules-left" == ["ext/workspaces"] and
    (has("hyprland/window") | not) and
    (has("custom/window-minimize") | not) and
    (has("custom/window-maximize") | not) and
    (has("custom/window-close") | not) and
    (."modules-right" | index("group/system") != null)
  ' \
  "$HOME/.config/waybar/config.jsonc"
check "Cyberdock stays discoverable outside true fullscreen" \
  grep -Fq 'exclusiveZone: fullscreenActive ? 0 : 74' \
  "$HOME/.config/quickshell/cyberdock/shell.qml"
check "Cyberlauncher provides searchable app details and keyboard focus" \
  grep -Fq 'WlrKeyboardFocus.Exclusive' \
  "$HOME/.config/quickshell/cyberdock/CyberLauncher.qml"
check "desktop OSD shares the Quickshell surface" \
  test -x "$HOME/.local/bin/cyberosd-show"
check "display projection controller is deployed" \
  test -x "$HOME/.local/bin/desktop-display-mode"
check "display projection overlay is deployed" \
  test -f "$HOME/.config/quickshell/cyberdock/DisplayModeOverlay.qml"
check "desktop power controller is deployed" \
  test -x "$HOME/.local/bin/desktop-power"
# HOME is intentionally expanded by the child Bash used for this compound check.
# shellcheck disable=SC2016
check "desktop power uses login1 without a user-scoped post command" bash -c \
  'grep -Fq "org.freedesktop.login1.Manager" "$HOME/.local/bin/desktop-power" && ! grep -Eq "systemd-run|--post-cmd|finalize-transition" "$HOME/.local/bin/desktop-power"'
check "desktop power menu is deployed" \
  test -f "$HOME/.config/quickshell/cyberdock/PowerMenu.qml"
# HOME is intentionally expanded by the child Bash used for these compound checks.
# shellcheck disable=SC2016
check "desktop window actions have no tracked Waybar target" bash -c \
  'test -x "$HOME/.local/bin/desktop-window-action" && ! grep -Fq -- "--tracked" "$HOME/.local/bin/desktop-window-action"'
# shellcheck disable=SC2016
check "client minimize bridge has no active-window side channel" bash -c \
  'test -x "$HOME/.local/bin/cyberdock-event-bridge" && ! grep -Eq "active-window-address|activewindowv2" "$HOME/.local/bin/cyberdock-event-bridge"'
# HOME is intentionally expanded by the child Bash used for the compound check.
# shellcheck disable=SC2016
check "KakaoTalk focus repair and surface guard are deployed" bash -c \
  'test -x "$HOME/.local/bin/kakaotalk-focus-repair" && test -x "$HOME/.local/bin/kakaotalk-focus-guard"'
check "SwayNC exposes notifications and the managed quick settings" \
  jq -e '
    ."widget-config".title.text == "Notifications" and
    (.widgets | index("buttons-grid#quick-settings") != null)
  ' \
  "$HOME/.config/swaync/config.json"
check "SwayNC quick-setting helper is executable and reports valid state" \
  swaync_quick_settings_callable
check "desktop GTK surfaces share the semantic palette" \
  test -f "$HOME/.config/cyberpunk-library/palette.css"
check "Ghostty enforces WCAG contrast" \
  grep -Fq 'minimum-contrast = 4.5' "$HOME/.config/ghostty/config.ghostty"
check "Zed applies the One Dark wallpaper-derived override" \
  jq -e '.theme_overrides["One Dark"]["editor.background"] == "#050623"' \
  "$HOME/.config/zed/settings.json"
check "GTK 3 uses the managed dark theme" \
  grep -Fq 'gtk-theme-name=adw-gtk3-dark' "$HOME/.config/gtk-3.0/settings.ini"
check "GTK 4 uses the managed dark theme" \
  grep -Fq 'gtk-theme-name=adw-gtk3-dark' "$HOME/.config/gtk-4.0/settings.ini"
check "desktop cursor uses the managed macOS-inspired theme" \
  grep -Fq 'gtk-cursor-theme-name=capitaine-cursors' \
  "$HOME/.config/gtk-3.0/settings.ini"
check "Fcitx candidate UI uses the managed deep-purple theme" \
  grep -Fq 'Theme=Material-Color-DeepPurple' \
  "$HOME/.config/fcitx5/conf/classicui.conf"
check "fallback cyberpunk SDDM theme payload is installed" \
  test -f /usr/share/sddm/themes/cyberpunk/Main.qml
check "cyberpunk SDDM 16:9 wallpaper is installed intact" \
  sha256_matches \
  /usr/share/sddm/themes/cyberpunk/background-16x9.jpg \
  5b96bdca2bfc912164e2dec3ec5aec6f360e3c7ba6dabc7136afe39b618ce1cc
check "cyberpunk SDDM 16:10 wallpaper is installed intact" \
  sha256_matches \
  /usr/share/sddm/themes/cyberpunk/background-16x10.jpg \
  784c66002966e57a2ab0e5ae2413c3faee7b93a8c656d203899d41b25faffafb
check "superseded SDDM wallpaper assets were removed" \
  bash -c \
  '[[ ! -e /usr/share/sddm/themes/cyberpunk/background.jpg && ! -e /usr/share/sddm/themes/cyberpunk/background.png ]]'

if [[ -f /etc/sddm.conf.d/20-cyberpunk-theme.conf ]]; then
  check "fallback cyberpunk SDDM theme is selected" \
    grep -Eq '^[[:space:]]*Current=cyberpunk[[:space:]]*$' \
    /etc/sddm.conf.d/20-cyberpunk-theme.conf
else
  warn "cyberpunk SDDM selection remains gated pending manual acceptance"
fi

if [[ $(fc-match -f '%{family}\n' sans-serif 2>/dev/null) == Pretendard* ]]; then
  pass "Pretendard is the first sans-serif match"
else
  fail "Pretendard is not the first sans-serif match"
fi
if [[ $(fc-match -f '%{family}\n' monospace 2>/dev/null) == Jetendard* ]]; then
  pass "Jetendard is the first monospace match"
else
  fail "Jetendard is not the first monospace match"
fi

scaling_helper=$HOME/.local/bin/desktop-scaling-status
if systemctl --user is-active --quiet graphical-session.target &&
  hyprctl clients -j >/dev/null 2>&1; then
  if [[ -x $scaling_helper ]]; then
    "$scaling_helper"
    scaling_status=$?
    case $scaling_status in
      0) pass "all scaling acceptance clients have the intended backend" ;;
      2) warn "some scaling acceptance clients are not running" ;;
      *) fail "one or more live clients use the wrong display backend" ;;
    esac
  else
    fail "desktop scaling status helper is not deployed"
  fi
else
  warn "graphical IPC is unavailable; live application scaling checks are deferred"
fi

rclone_config=${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf
if [[ -f $rclone_config ]]; then
  if grep -q '^RCLONE_ENCRYPT_V[0-9]\+:' "$rclone_config"; then
    pass "rclone configuration is encrypted"
  else
    fail "rclone configuration exists but is not encrypted"
  fi
  if [[ $(stat -c '%a' "$rclone_config" 2>/dev/null) == 600 ]]; then
    pass "rclone configuration mode is 0600"
  else
    fail "rclone configuration mode is not 0600"
  fi
  for remote in google-drive proton-drive; do
    unit=rclone-$remote.service
    check "cloud mount unit enabled: $unit" \
      systemctl --user is-enabled --quiet "$unit"
    check "cloud mount unit active: $unit" \
      systemctl --user is-active --quiet "$unit"
  done
  check "Google Drive mount is present" mountpoint -q "$HOME/Cloud/GoogleDrive"
  check "Proton Drive mount is present" mountpoint -q "$HOME/Cloud/ProtonDrive"
else
  warn "cloud accounts are not onboarded; run rclone-cloud-setup all"
fi

bridge_marker=${XDG_STATE_HOME:-$HOME/.local/state}/protonmail-bridge/managed-service-enabled
bridge_status=$HOME/.local/bin/protonmail-bridge-status
if [[ -f $bridge_marker ]]; then
  if [[ -x $bridge_status ]] && "$bridge_status"; then
    pass "Proton Mail Bridge managed state is ready"
  else
    fail "Proton Mail Bridge onboarding exists but managed state is unhealthy"
  fi
else
  warn "Proton Mail Bridge is not onboarded; run protonmail-bridge-setup"
fi

if systemctl is-enabled --quiet warp-svc.service &&
  systemctl is-active --quiet warp-svc.service; then
  pass "Cloudflare One system daemon is enabled and active"
else
  fail "Cloudflare One daemon did not converge after the AUR phase"
fi
if systemctl --user is-enabled --quiet warp-taskbar.service; then
  pass "Cloudflare One taskbar unit is enabled"
else
  warn "Cloudflare One GUI enrollment is pending; run cloudflare-one-setup"
fi
cloudflare_status=$HOME/.local/bin/cloudflare-one-status
if [[ -x $cloudflare_status ]]; then
  "$cloudflare_status"
fi

for mime_type in \
  application/vnd.openxmlformats-officedocument.wordprocessingml.document \
  application/vnd.openxmlformats-officedocument.spreadsheetml.sheet \
  application/vnd.openxmlformats-officedocument.presentationml.presentation; do
  if [[ $(xdg-mime query default "$mime_type" 2>/dev/null) == onlyoffice-desktopeditors.desktop ]]; then
    pass "ONLYOFFICE default: $mime_type"
  else
    fail "ONLYOFFICE is not the default for $mime_type"
  fi
done
if [[ $(xdg-mime query default application/pdf 2>/dev/null) == google-chrome.desktop ]]; then
  pass "PDF default remains Google Chrome"
else
  fail "PDF default changed from the approved existing policy"
fi

rhwp_private_dir=$(
  find /opt/rhwp-desktop -type d ! -perm -0005 -print -quit 2>/dev/null || true
)
if [[ $(stat -c '%U:%G:%a' /opt/rhwp-desktop 2>/dev/null) == root:root:755 ]] &&
  [[ -z $rhwp_private_dir ]]; then
  pass "RHWP application directories are readable and traversable"
else
  fail "RHWP application directory ownership or modes are incorrect"
fi
if [[ $(stat -c '%U:%G:%a' /opt/rhwp-desktop/chrome-sandbox 2>/dev/null) == root:root:4755 ]]; then
  pass "RHWP Chromium sandbox has the reviewed root-owned 4755 mode"
else
  fail "RHWP Chromium sandbox owner or mode is incorrect"
fi

if xdg-mime query default application/vnd.hancom.hwpx 2>/dev/null |
  grep -Fxq rhwp-desktop.desktop; then
  pass "RHWP defaults were enabled after local acceptance"
else
  warn "RHWP HWP/HWPX defaults remain gated pending sample acceptance"
fi

graphics_status=$HOME/.local/bin/graphics-workflow-check
if [[ -x $graphics_status ]]; then
  if "$graphics_status" --status; then
    pass "GIMP and PhotoGIMP profiles remain isolated"
  else
    fail "graphics workflow status reported a managed-state failure"
  fi
else
  fail "graphics workflow status helper is not deployed"
fi

if [[ -z $(systemctl --failed --no-legend --plain 2>/dev/null) ]]; then
  pass "no failed system units"
else
  fail "one or more system units are failed"
fi

if [[ -z $(systemctl --user --failed --no-legend --plain 2>/dev/null) ]]; then
  pass "no failed user units"
else
  warn "one or more session/application user units are failed; inspect after the next graphical login"
fi

printf '\nPostflight result: %d failure(s), %d warning(s), %d skip(s).\n' \
  "$failures" "$warnings" "$skips"
printf 'Manual checks still required: fingerprint/auth and fallback SDDM; suspend, boot security, WWAN, and displays; Hyprshot/Kooha capture; Vicinae IME/privacy/idle; Hyprshell mixed-DPI keyboard focus; performance-history retention/overhead; Kakao and Parsec workflows.\n'

if [[ $report_format == json ]]; then
  report_destination=${report_output:-$results_file.json}
  if [[ -n $report_output ]]; then
    install -d -m 0700 "${report_destination%/*}"
  fi
  /usr/bin/python - \
    "$results_file" "$profile" "$failures" "$warnings" "$skips" \
    "$report_destination" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys

results_path = Path(sys.argv[1])
checks = [
    json.loads(line)
    for line in results_path.read_text(encoding="utf-8").splitlines()
    if line
]
payload = {
    "schema": 1,
    "profile": sys.argv[2],
    "result": "failed" if int(sys.argv[3]) else "passed",
    "summary": {
        "pass": sum(check["status"] == "pass" for check in checks),
        "fail": int(sys.argv[3]),
        "warn": int(sys.argv[4]),
        "skip": int(sys.argv[5]),
    },
    "checks": checks,
}
Path(sys.argv[6]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
  if [[ -n $report_stdout_fd ]]; then
    cat -- "$report_destination" >&3
  fi
elif [[ -n $report_output ]]; then
  install -d -m 0700 "${report_output%/*}"
  {
    printf 'Postflight result: %d failure(s), %d warning(s), %d skip(s).\n' \
      "$failures" "$warnings" "$skips"
  } >"$report_output"
fi

((failures == 0))
