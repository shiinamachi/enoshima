#!/usr/bin/env bash

# Read a boolean host capability from an ansible-inventory JSON object.
# Missing capabilities preserve the postflight compatibility default of true,
# while an explicitly configured false must remain false.
inventory_capability() {
  local inventory_json=$1 name=$2 value

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  value=$(jq -r --arg name "$name" '
    .enoshima_capabilities
    | if type == "object" and has($name) then .[$name] else true end
  ' <<<"$inventory_json") || return 1
  [[ $value == true ]]
}
