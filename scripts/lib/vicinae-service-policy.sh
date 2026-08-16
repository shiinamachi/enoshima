#!/usr/bin/env bash

# Validate the effective systemd service properties emitted by one
# `systemctl show` invocation. Empty array-valued properties may be omitted
# entirely by systemctl, so absence is equivalent to an empty value only for
# EnvironmentFiles. Loader, plugin, and QML path overrides are always removed
# alongside QT_NO_GLIB so the reviewed system Qt/QtKeychain runtime cannot be
# replaced through the inherited user-manager environment.
vicinae_effective_service_policy_valid() (
  local properties=${1-}
  local keyring_helper=${2-}
  local server_helper=${3-}
  local compatibility_helper=/usr/libexec/vicinae/vicinae-build-compatible
  local exec_condition exec_start exec_start_post home key value
  local -A effective=()

  [[ -n $keyring_helper && -n $server_helper ]] || return 1
  while IFS='=' read -r key value; do
    case $key in
      Environment | EnvironmentFiles | UnsetEnvironment | ExecCondition | \
        ExecStart | ExecStartPre | ExecStartPost | ExecReload | ExecStop | \
        ExecStopPost | ExecSearchPath | FragmentPath | DropInPaths | KillMode | Restart | RestartUSec | \
        TimeoutStartUSec | TimeoutStopUSec | \
        StartLimitIntervalUSec | StartLimitBurst) ;;
      *) return 1 ;;
    esac
    if [[ $key == ExecCondition && -v effective["$key"] ]]; then
      effective["$key"]+=" $value"
    else
      [[ ! -v effective["$key"] ]] || return 1
      effective["$key"]=$value
    fi
  done <<<"$properties"

  for key in \
    Environment \
    UnsetEnvironment \
    ExecCondition \
    ExecStart \
    ExecStartPost \
    FragmentPath \
    DropInPaths \
    KillMode \
    Restart \
    RestartUSec \
    TimeoutStartUSec \
    TimeoutStopUSec \
    StartLimitIntervalUSec \
    StartLimitBurst; do
    [[ -v effective["$key"] ]] || return 1
  done
  home=${keyring_helper%/.local/libexec/vicinae-keyring-ready}
  [[ ${effective[Environment]} == "VICINAE_NODE_BIN=/usr/bin/node HOME=$home XDG_CONFIG_HOME=$home/.config XDG_DATA_HOME=$home/.local/share XDG_STATE_HOME=$home/.local/state XDG_CACHE_HOME=$home/.cache \"EMOJI_FONT=Noto Color Emoji\"" ]] ||
    return 1
  [[ -z ${effective[EnvironmentFiles]-} ]] || return 1
  [[ -z ${effective[ExecSearchPath]-} ]] || return 1
  [[ ${effective[FragmentPath]} == /usr/lib/systemd/user/vicinae.service ]] ||
    return 1
  [[ ${effective[DropInPaths]} == '/usr/lib/systemd/user/vicinae.service.d/20-enoshima-qt-compatibility.conf '"${keyring_helper%/.local/libexec/vicinae-keyring-ready}"'/.config/systemd/user/vicinae.service.d/60-enoshima-keyring.conf' ]] ||
    return 1
  [[ -z ${effective[ExecStartPre]-} && -z ${effective[ExecReload]-} &&
    -z ${effective[ExecStop]-} && -z ${effective[ExecStopPost]-} ]] || return 1
  [[ ${effective[UnsetEnvironment]} == 'QT_NO_GLIB LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT QT_PLUGIN_PATH QML_IMPORT_PATH QML2_IMPORT_PATH QT_QPA_PLATFORM_PLUGIN_PATH VICINAE_OVERRIDES' ]] ||
    return 1

  exec_condition=${effective[ExecCondition]}
  [[ $exec_condition == "{ path=$compatibility_helper ; argv[]=$compatibility_helper ; ignore_errors=no ; "* ]] ||
    return 1
  [[ $exec_condition == *" } { path=$keyring_helper ; argv[]=$keyring_helper ; ignore_errors=no ; "* ]] ||
    return 1
  [[ $exec_condition == *' }' ]] || return 1
  [[ $(grep -Fo '} {' <<<"$exec_condition" | wc -l) == 1 ]] || return 1

  exec_start=${effective[ExecStart]}
  [[ $exec_start == '{ path=/usr/bin/vicinae ; argv[]=/usr/bin/vicinae server --replace ; ignore_errors=no ; '* ]] ||
    return 1
  [[ $exec_start == *' }' && $exec_start != *'} {'* ]] || return 1

  exec_start_post=${effective[ExecStartPost]}
  [[ $exec_start_post == "{ path=$server_helper ; argv[]=$server_helper ; ignore_errors=no ; "* ]] ||
    return 1
  [[ $exec_start_post == *' }' && $exec_start_post != *'} {'* ]] || return 1
  [[ ${effective[KillMode]} == control-group ]] || return 1
  [[ ${effective[Restart]} == on-failure ]] || return 1
  [[ ${effective[RestartUSec]} == 1min ]] || return 1
  [[ ${effective[TimeoutStartUSec]} == 40s ]] || return 1
  [[ ${effective[TimeoutStopUSec]} == 10s ]] || return 1
  [[ ${effective[StartLimitIntervalUSec]} == 5min ]] || return 1
  [[ ${effective[StartLimitBurst]} == 2 ]]
)
