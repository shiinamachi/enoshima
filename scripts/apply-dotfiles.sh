#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_dir=${DOTFILES_SOURCE:-$repo_root}
destination=${CHEZMOI_DESTINATION:-$HOME}
control_home=${ENOSHIMA_STATE_HOME:-$destination/.enoshima}
legacy_control_home=$destination/.my-arch-configurations
persistent_state=${CHEZMOI_PERSISTENT_STATE:-$control_home/chezmoi-state.boltdb}
backup_base=${DOTFILES_BACKUP_ROOT:-$control_home/backups}
legacy_state=${CHEZMOI_LEGACY_STATE:-$destination/.config/chezmoi/chezmoistate.boltdb}
mode=
policy=

usage() {
  cat <<'EOF'
Usage: scripts/apply-dotfiles.sh (--check|--apply) POLICY

POLICY is one of:
  backup     Back up conflicts and apply the repository versions.
  overwrite  Apply the repository versions without conflict backups.
  keep       Keep conflicts and apply all independent targets.
  abort      Exit without applying if any conflict exists.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

while (($# > 0)); do
  case $1 in
    --check | --apply)
      [[ -z $mode ]] || die "select exactly one of --check or --apply"
      mode=$1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z $policy ]] || die "only one conflict policy may be selected"
      policy=$1
      shift
      ;;
  esac
done

[[ -n $mode ]] || die "--check or --apply is required"
case $policy in
  backup | overwrite | keep | abort) ;;
  *) die "policy must be backup, overwrite, keep, or abort" ;;
esac

command -v chezmoi >/dev/null 2>&1 || die "chezmoi is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v findmnt >/dev/null 2>&1 || die "findmnt is required"
[[ -d $source_dir ]] || die "dotfile source does not exist: $source_dir"
[[ $destination == /* ]] || die "CHEZMOI_DESTINATION must be an absolute path"
[[ -d $destination ]] || die "CHEZMOI_DESTINATION must already be a directory: $destination"
canonical_destination=$(realpath -e -- "$destination")
[[ $canonical_destination == "$destination" ]] ||
  die "CHEZMOI_DESTINATION must be a canonical, non-symlink path: $destination"
[[ $control_home == "$destination/"* ]] || die "ENOSHIMA_STATE_HOME must be inside $destination"
[[ ! -L $control_home && (! -e $control_home || -d $control_home) ]] ||
  die "reserved state path is not a real directory: $control_home"

if [[ -z ${ENOSHIMA_STATE_HOME+x} && ! -e $control_home &&
  (-e $legacy_control_home || -L $legacy_control_home) ]]; then
  [[ -d $legacy_control_home && ! -L $legacy_control_home ]] ||
    die "legacy state path is not a real directory: $legacy_control_home"
  if findmnt --kernel --mountpoint "$legacy_control_home" >/dev/null 2>&1; then
    die "refusing to migrate a mounted legacy state path: $legacy_control_home"
  fi
  mv -- "$legacy_control_home" "$control_home"
  echo "Migrated the previous project state into $control_home."
fi

mkdir -p -- "$control_home" "$(dirname -- "$persistent_state")"
chmod 0700 -- "$control_home"

declare -a home_mount_paths=()
load_home_mount_paths() {
  mapfile -d '' -t home_mount_paths < <(
    findmnt --kernel=mountinfo --json --output TARGET |
      jq --raw-output0 --arg destination "$canonical_destination" '
        .. | objects | .target? // empty
        | select(. != $destination and startswith($destination + "/"))
      '
  )
}
load_home_mount_paths

assert_confined_target() {
  local target=$1
  local operation=$2
  local canonical_parent mounted_path

  [[ $target == "$destination/"* ]] ||
    die "refusing to $operation a target outside $destination: $target"
  canonical_parent=$(realpath -m -- "$(dirname -- "$target")")
  [[ $canonical_parent == "$canonical_destination" ||
    $canonical_parent == "$canonical_destination/"* ]] ||
    die "refusing to $operation through an ancestor outside $destination: $target"

  load_home_mount_paths
  for mounted_path in "${home_mount_paths[@]}"; do
    if [[ $target == "$mounted_path" ||
      $target == "$mounted_path/"* ||
      $mounted_path == "$target/"* ]]; then
      die "refusing to $operation across mounted path: $mounted_path"
    fi
  done
}

chezmoi_args=(
  --config /dev/null
  --config-format toml
  --source "$source_dir"
  --destination "$destination"
  --persistent-state "$persistent_state"
  --no-pager
  --no-tty
)

status_file=$(mktemp)
state_file=$(mktemp)
managed_file=$(mktemp)
cleanup() {
  rm -f -- "$status_file" "$state_file" "$managed_file"
}
trap cleanup EXIT

chezmoi "${chezmoi_args[@]}" managed --path-style absolute >"$managed_file"
mapfile -t managed_targets <"$managed_file"

declare -A managed=()
for managed_target in "${managed_targets[@]}"; do
  managed["$managed_target"]=1
  if [[ $managed_target == "$control_home" || $control_home == "$managed_target/"* ]]; then
    die "chezmoi source must not manage the reserved state path: $control_home"
  fi
done

# The old bootstrap used chezmoi's default database. Seed the isolated database
# once with entries for targets still owned by this repository, so an ordinary
# repository update is not mistaken for a local edit during migration.
migrated_state=false
if [[ ! -e $persistent_state && -f $legacy_state && $legacy_state != "$persistent_state" ]]; then
  cp --reflink=auto -- "$legacy_state" "$persistent_state"
  chmod 0600 -- "$persistent_state"
  migrated_state=true
fi

chezmoi "${chezmoi_args[@]}" state dump >"$state_file"
if [[ $migrated_state == true ]]; then
  while IFS= read -r old_target; do
    if [[ ! -v managed["$old_target"] ]]; then
      chezmoi "${chezmoi_args[@]}" state delete \
        --bucket entryState --key "$old_target"
    fi
  done < <(jq -r '(.entryState // {}) | keys[]' "$state_file")
  chezmoi "${chezmoi_args[@]}" state dump >"$state_file"
  echo "Migrated the previous chezmoi baseline into the repository-specific state."
fi

declare -A previously_managed=()
declare -A previous_type=()
while IFS=$'\t' read -r target target_type; do
  if [[ $target == "$control_home" || $target == "$control_home/"* ]]; then
    die "chezmoi state must not own the reserved state path: $control_home"
  fi
  previously_managed["$target"]=1
  previous_type["$target"]=$target_type
done < <(
  jq -r '(.entryState // {}) | to_entries[] | [.key, .value.type] | @tsv' "$state_file"
)

declare -A blocking_paths_seen=()
declare -a blocking_paths=()
declare -A mounted_blocking_path=()
for managed_target in "${managed_targets[@]}"; do
  for mounted_path in "${home_mount_paths[@]}"; do
    if [[ $managed_target == "$mounted_path" ||
      $managed_target == "$mounted_path/"* ]]; then
      mounted_blocking_path["$mounted_path"]=1
      if [[ ! -v blocking_paths_seen["$mounted_path"] ]]; then
        blocking_paths_seen["$mounted_path"]=1
        blocking_paths+=("$mounted_path")
      fi
    fi
  done

  parent=$(dirname -- "$managed_target")
  while [[ $parent == "$destination/"* ]]; do
    if [[ -L $parent || (-e $parent && ! -d $parent) ]]; then
      if [[ ! -v blocking_paths_seen["$parent"] ]]; then
        blocking_paths_seen["$parent"]=1
        blocking_paths+=("$parent")
      fi
      break
    fi
    parent=$(dirname -- "$parent")
  done
done

# Ask chezmoi for each entry non-recursively. Descendants of a file/symlink
# blocker cannot be inspected until their managed ancestor has been resolved,
# but the blocker itself can still be compared with its previous baseline.
declare -a status_targets=()
for managed_target in "${managed_targets[@]}"; do
  blocked_descendant=false
  for blocking_path in "${blocking_paths[@]}"; do
    if [[ $managed_target == "$blocking_path/"* ]]; then
      blocked_descendant=true
      break
    fi
  done
  if [[ $blocked_descendant == false ]]; then
    status_targets+=("$managed_target")
  fi
done
if ((${#status_targets[@]} > 0)); then
  chezmoi "${chezmoi_args[@]}" status --recursive=false --path-style absolute -- \
    "${status_targets[@]}" >"$status_file"
fi

declare -A conflict_seen=()
declare -a conflicts=()
add_conflict() {
  local target=$1
  if [[ ! -v conflict_seen["$target"] ]]; then
    conflict_seen["$target"]=1
    conflicts+=("$target")
  fi
}

for blocking_path in "${blocking_paths[@]}"; do
  if [[ -v mounted_blocking_path["$blocking_path"] ]]; then
    add_conflict "$blocking_path"
  fi
done

while IFS= read -r status_line; do
  ((${#status_line} >= 4)) || continue
  local_state=${status_line:0:1}
  desired_state=${status_line:1:1}
  target=${status_line:3}
  [[ $desired_state != " " ]] || continue

  if [[ $local_state != " " ]]; then
    add_conflict "$target"
  elif [[ -e $target || -L $target ]] && [[ ! -v previously_managed["$target"] ]]; then
    # On the first run, a different pre-existing target has no safe baseline.
    add_conflict "$target"
  fi
done <"$status_file"

mode_matches_baseline() {
  local target=$1
  local stored_mode current_mode_octal current_mode
  stored_mode=$(jq -r --arg target "$target" \
    '.entryState[$target].mode // empty' "$state_file")
  [[ -n $stored_mode ]] || return 0
  current_mode_octal=$(stat -c '%a' -- "$target")
  current_mode=$((8#$current_mode_octal))
  ((current_mode == (stored_mode & 511)))
}

matches_baseline() {
  local target=$1
  local target_type stored_checksum current_checksum
  target_type=${previous_type[$target]}

  if [[ ! -e $target && ! -L $target ]]; then
    return 0
  fi

  case $target_type in
    file)
      [[ -f $target && ! -L $target ]] || return 1
      stored_checksum=$(jq -r --arg target "$target" \
        '.entryState[$target].contentsSHA256 // empty' "$state_file")
      current_checksum=$(sha256sum -- "$target")
      current_checksum=${current_checksum%% *}
      [[ -n $stored_checksum && $current_checksum == "$stored_checksum" ]] &&
        mode_matches_baseline "$target"
      ;;
    symlink)
      [[ -L $target ]] || return 1
      stored_checksum=$(jq -r --arg target "$target" \
        '.entryState[$target].contentsSHA256 // empty' "$state_file")
      current_checksum=$(printf '%s' "$(readlink -- "$target")" | sha256sum)
      current_checksum=${current_checksum%% *}
      [[ -n $stored_checksum && $current_checksum == "$stored_checksum" ]]
      ;;
    dir)
      [[ -d $target && ! -L $target ]] && mode_matches_baseline "$target"
      ;;
    script)
      [[ ! -e $target && ! -L $target ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# A source removal/rename is desired deletion. Compare stale entryState records
# with the actual filesystem so unchanged old targets can be removed while
# locally edited ones use the same selected conflict policy.
declare -a stale_targets=()
declare -a stale_directories=()
declare -A safe_deletion=()
declare -A protected_stale_target=()
declare -A state_only_deletion=()
while IFS= read -r old_target; do
  if [[ ! -v managed["$old_target"] ]]; then
    stale_targets+=("$old_target")

    # Script keys are synthetic hook identifiers, not filesystem ownership.
    # Removing a hook must never delete an unrelated real file with that name.
    if [[ ${previous_type[$old_target]} == script ]]; then
      state_only_deletion["$old_target"]=1
      safe_deletion["$old_target"]=1
      continue
    fi

    # Never inspect a stale descendant through a symlink or non-directory
    # ancestor. A user may have replaced an old managed directory with a link
    # outside HOME; classifying, backing up, or removing the descendant would
    # otherwise follow that link. Treat the ancestor itself as the conflict.
    stale_blocker=
    for mounted_path in "${home_mount_paths[@]}"; do
      if [[ $old_target == "$mounted_path" ||
        $old_target == "$mounted_path/"* ]]; then
        mounted_blocking_path["$mounted_path"]=1
        stale_blocker=$mounted_path
        break
      fi
    done

    parent=$(dirname -- "$old_target")
    while [[ $parent == "$destination/"* ]]; do
      if [[ -L $parent || (-e $parent && ! -d $parent) ]]; then
        stale_blocker=$parent
        break
      fi
      parent=$(dirname -- "$parent")
    done
    if [[ -n $stale_blocker ]]; then
      protected_stale_target["$old_target"]=1
      if [[ ! -v blocking_paths_seen["$stale_blocker"] ]]; then
        blocking_paths_seen["$stale_blocker"]=1
        blocking_paths+=("$stale_blocker")
      fi
      add_conflict "$stale_blocker"
      continue
    fi

    stale_contains_mount=false
    for mounted_path in "${home_mount_paths[@]}"; do
      if [[ $mounted_path == "$old_target/"* ]]; then
        mounted_blocking_path["$mounted_path"]=1
        protected_stale_target["$old_target"]=1
        add_conflict "$old_target"
        stale_contains_mount=true
      fi
    done
    [[ $stale_contains_mount == false ]] || continue

    if [[ ${previous_type[$old_target]} == dir ]]; then
      stale_directories+=("$old_target")
    elif matches_baseline "$old_target"; then
      safe_deletion["$old_target"]=1
    else
      add_conflict "$old_target"
    fi
  fi
done < <(jq -r '(.entryState // {}) | keys[]' "$state_file")

for ((index = ${#stale_directories[@]} - 1; index >= 0; index--)); do
  target=${stale_directories[index]}
  directory_is_safe=true

  if ! matches_baseline "$target"; then
    directory_is_safe=false
  elif [[ -d $target && ! -L $target ]]; then
    while IFS= read -r -d '' child; do
      if [[ ! -v safe_deletion["$child"] ]]; then
        directory_is_safe=false
        break
      fi
    done < <(find "$target" -mindepth 1 -print0)
  fi

  if [[ $directory_is_safe == true ]]; then
    safe_deletion["$target"]=1
  else
    add_conflict "$target"
  fi
done

# A type or directory conflict may contain a local-only submount even when no
# managed/stale key exists below it. Recursive backup or replacement must stop
# before crossing that filesystem boundary.
for target in "${conflicts[@]}"; do
  if [[ -d $target && ! -L $target ]]; then
    for mounted_path in "${home_mount_paths[@]}"; do
      if [[ $mounted_path == "$target" || $mounted_path == "$target/"* ]]; then
        mounted_blocking_path["$mounted_path"]=1
      fi
    done
  fi
done

declare -a safe_targets=()
if ((${#conflicts[@]} > 0)); then
  echo "Conflicts are being kept separate from non-recursive target updates."
fi
for managed_target in "${managed_targets[@]}"; do
  [[ ! -v conflict_seen["$managed_target"] ]] || continue

  blocked_by_kept_type_conflict=false
  for blocking_path in "${blocking_paths[@]}"; do
    if [[ -v conflict_seen["$blocking_path"] && $managed_target == "$blocking_path/"* ]]; then
      blocked_by_kept_type_conflict=true
      break
    fi
  done
  [[ $blocked_by_kept_type_conflict == false ]] || continue

  # After hooks run after the selected safe files. Repository hooks are written
  # to converge independent user state, so an unrelated kept conflict must not
  # prevent them from completing the rest of the profile.
  safe_targets+=("$managed_target")
done

if ((${#conflicts[@]} > 0)); then
  printf 'Found %d conflicting user-file target(s):\n' "${#conflicts[@]}"
  printf '  %s\n' "${conflicts[@]}"
else
  echo "No conflicting user files found."
fi

if [[ $policy == abort && ${#conflicts[@]} -gt 0 ]]; then
  echo "Conflict policy is abort; no user files were applied." >&2
  exit 3
fi
if ((${#mounted_blocking_path[@]} > 0)) && [[ $policy != keep ]]; then
  printf 'Mounted paths cannot be safely replaced by the %s policy:\n' "$policy" >&2
  printf '  %s\n' "${!mounted_blocking_path[@]}" >&2
  echo "Unmount them first, or select keep to preserve the mounted trees." >&2
  exit 4
fi
if [[ $mode == --check ]]; then
  exit 0
fi

remove_stale_targets() {
  local selection=$1
  local index target
  for ((index = ${#stale_targets[@]} - 1; index >= 0; index--)); do
    target=${stale_targets[index]}
    if [[ $selection == safe && ! -v safe_deletion["$target"] ]]; then
      continue
    fi
    if [[ $selection == safe && -v protected_stale_target["$target"] ]]; then
      continue
    fi
    if [[ -v state_only_deletion["$target"] ]]; then
      chezmoi "${chezmoi_args[@]}" state delete \
        --bucket entryState --key "$target"
      continue
    fi
    assert_confined_target "$target" "remove"
    rm -rf -- "$target"
    chezmoi "${chezmoi_args[@]}" state delete \
      --bucket entryState --key "$target"
  done
}

remove_blocking_paths() {
  local blocking_path
  for blocking_path in "${blocking_paths[@]}"; do
    assert_confined_target "$blocking_path" "remove"
    rm -rf -- "$blocking_path"
  done
}

case $policy in
  backup)
    if ((${#conflicts[@]} > 0)); then
      previous_umask=$(umask)
      umask 077
      mkdir -p -- "$backup_base"
      backup_dir=$(mktemp -d "$backup_base/$(date +%Y%m%d-%H%M%S).XXXXXX")
      mkdir -- "$backup_dir/home"
      for target in "${conflicts[@]}"; do
        assert_confined_target "$target" "back up"
        [[ -e $target || -L $target ]] || continue
        relative_target=${target#"$destination/"}
        (
          cd "$destination"
          cp -a --parents -- "$relative_target" "$backup_dir/home"
        )
      done
      printf '%s\n' "${conflicts[@]}" >"$backup_dir/conflicts.txt"
      umask "$previous_umask"
      echo "Backed up conflicting user files to: $backup_dir"
    fi
    remove_blocking_paths
    remove_stale_targets all
    chezmoi "${chezmoi_args[@]}" --force apply
    ;;
  overwrite)
    for target in "${conflicts[@]}"; do
      assert_confined_target "$target" "replace"
    done
    remove_blocking_paths
    remove_stale_targets all
    chezmoi "${chezmoi_args[@]}" --force apply
    ;;
  keep)
    remove_stale_targets safe
    if ((${#safe_targets[@]} > 0)); then
      chezmoi "${chezmoi_args[@]}" --force apply --recursive=false -- \
        "${safe_targets[@]}"
    else
      echo "No independent user-file changes to apply."
    fi
    if ((${#conflicts[@]} > 0)); then
      echo "Kept ${#conflicts[@]} conflicting local target(s); independent targets and hooks were applied."
    fi
    ;;
  abort)
    remove_stale_targets safe
    remove_blocking_paths
    chezmoi "${chezmoi_args[@]}" --force apply
    ;;
esac
