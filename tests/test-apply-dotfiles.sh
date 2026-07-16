#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
subject="$repo_root/scripts/apply-dotfiles.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

assert_contents() {
  local path=$1
  local expected=$2
  local actual
  actual=$(<"$path")
  [[ $actual == "$expected" ]] || fail "$path: expected '$expected', got '$actual'"
}

new_fixture() {
  local name=$1
  fixture="$test_root/$name"
  source_dir="$fixture/source"
  destination="$fixture/home"
  state_file="$fixture/state/chezmoi.boltdb"
  backup_root="$fixture/backups"
  mkdir -p -- "$source_dir" "$destination" "$(dirname -- "$state_file")"

  printf 'repository conflict one\n' >"$source_dir/dot_conflict_one"
  printf 'repository conflict two\n' >"$source_dir/dot_conflict_two"
  printf 'repository safe\n' >"$source_dir/dot_safe"
  printf 'local conflict one\n' >"$destination/.conflict_one"
  printf 'local conflict two\n' >"$destination/.conflict_two"
}

run_subject() {
  DOTFILES_SOURCE="$source_dir" \
    CHEZMOI_DESTINATION="$destination" \
    CHEZMOI_PERSISTENT_STATE="$state_file" \
    DOTFILES_BACKUP_ROOT="$backup_root" \
    "$subject" "$@"
}

run_subject_with_defaults() {
  DOTFILES_SOURCE="$source_dir" \
    CHEZMOI_DESTINATION="$destination" \
    "$subject" "$@"
}

echo "==> keep preserves every conflict and applies safe targets"
new_fixture keep
run_subject --check keep >/dev/null
run_subject --apply keep >/dev/null
assert_contents "$destination/.conflict_one" "local conflict one"
assert_contents "$destination/.conflict_two" "local conflict two"
assert_contents "$destination/.safe" "repository safe"

echo "==> backup preserves originals and applies repository targets"
new_fixture backup
run_subject --apply backup >/dev/null
assert_contents "$destination/.conflict_one" "repository conflict one"
assert_contents "$destination/.conflict_two" "repository conflict two"
backup_dir=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n $backup_dir ]] || fail "backup policy did not create a backup directory"
assert_contents "$backup_dir/home/.conflict_one" "local conflict one"
assert_contents "$backup_dir/home/.conflict_two" "local conflict two"
[[ -s $backup_dir/conflicts.txt ]] || fail "backup policy did not write a conflict manifest"

echo "==> overwrite applies repository targets without a backup"
new_fixture overwrite
run_subject --apply overwrite >/dev/null
assert_contents "$destination/.conflict_one" "repository conflict one"
assert_contents "$destination/.conflict_two" "repository conflict two"
[[ ! -e $backup_root ]] || fail "overwrite policy unexpectedly created a backup"

echo "==> abort detects all conflicts before applying user files"
new_fixture abort
set +e
run_subject --check abort >/dev/null 2>&1
abort_status=$?
set -e
[[ $abort_status -eq 3 ]] || fail "abort policy returned $abort_status instead of 3"
assert_contents "$destination/.conflict_one" "local conflict one"
[[ ! -e $destination/.safe ]] || fail "abort preflight applied a safe target"

echo "==> keep distinguishes a later repository update from a local edit"
new_fixture existing
chezmoi \
  --config /dev/null \
  --config-format toml \
  --source "$source_dir" \
  --destination "$destination" \
  --persistent-state "$state_file" \
  --no-tty \
  --force apply
printf 'edited locally\n' >"$destination/.conflict_one"
printf 'repository update\n' >"$source_dir/dot_safe"
run_subject --apply keep >/dev/null
assert_contents "$destination/.conflict_one" "edited locally"
assert_contents "$destination/.safe" "repository update"

echo "==> keep protects descendants of a file/directory type conflict"
new_fixture type-conflict
mkdir -- "$source_dir/dot_tree"
printf 'repository child\n' >"$source_dir/dot_tree/dot_child"
printf 'local file blocks desired directory\n' >"$destination/.tree"
run_subject --apply keep >/dev/null
assert_contents "$destination/.tree" "local file blocks desired directory"

echo "==> backup resolves a file/directory type conflict after preserving it"
new_fixture type-backup
mkdir -- "$source_dir/dot_tree"
printf 'repository child\n' >"$source_dir/dot_tree/dot_child"
printf 'local file blocks desired directory\n' >"$destination/.tree"
run_subject --apply backup >/dev/null
assert_contents "$destination/.tree/.child" "repository child"
backup_dir=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
assert_contents "$backup_dir/home/.tree" "local file blocks desired directory"

echo "==> default backup storage remains outside a conflicting .local directory"
new_fixture local-state-parent
mkdir -- "$source_dir/dot_local" "$destination/.local"
printf 'repository local child\n' >"$source_dir/dot_local/dot_child"
printf 'local-only data\n' >"$destination/.local/local-only"
chmod 0700 "$destination/.local"
run_subject_with_defaults --apply backup >/dev/null
default_backup_dir=$(find "$destination/.enoshima/backups" \
  -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n $default_backup_dir ]] || fail "default backup policy did not preserve the .local conflict"
assert_contents "$default_backup_dir/home/.local/local-only" "local-only data"
assert_contents "$destination/.local/.child" "repository local child"

echo "==> the previous project state directory migrates to the enoshima namespace"
new_fixture project-state-rename
legacy_control_home=$destination/.my-arch-configurations
mkdir -p -- "$legacy_control_home/backups"
printf 'preserved backup marker\n' >"$legacy_control_home/backups/marker"
run_subject_with_defaults --apply keep >/dev/null
[[ ! -e $legacy_control_home ]] || fail "legacy project state directory was not removed"
assert_contents "$destination/.enoshima/backups/marker" "preserved backup marker"
[[ -f $destination/.enoshima/chezmoi-state.boltdb ]] ||
  fail "migrated project state does not contain the chezmoi database"

echo "==> keep records an identical pre-existing target as its baseline"
new_fixture identical
printf 'same content\n' >"$source_dir/dot_identical"
printf 'same content\n' >"$destination/.identical"
run_subject --apply keep >/dev/null
jq -e --arg target "$destination/.identical" \
  '.entryState | has($target)' < <(
    chezmoi --config /dev/null --config-format toml \
      --source "$source_dir" --destination "$destination" \
      --persistent-state "$state_file" state dump
  ) >/dev/null || fail "keep did not record the identical target baseline"
printf 'repository changed later\n' >"$source_dir/dot_identical"
run_subject --apply keep >/dev/null
assert_contents "$destination/.identical" "repository changed later"

echo "==> keep applies a baseline file-to-directory repository transition"
new_fixture file-to-directory
printf 'old managed file\n' >"$source_dir/dot_transition"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
rm -- "$source_dir/dot_transition"
mkdir -- "$source_dir/dot_transition"
printf 'new managed child\n' >"$source_dir/dot_transition/dot_child"
run_subject --apply keep >/dev/null
assert_contents "$destination/.transition/.child" "new managed child"

echo "==> keep applies a safe child beneath a directory mode conflict"
new_fixture directory-mode
mkdir -- "$source_dir/dot_mode_parent"
printf 'first child\n' >"$source_dir/dot_mode_parent/dot_first"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
chmod 0700 "$destination/.mode_parent"
printf 'second child\n' >"$source_dir/dot_mode_parent/dot_second"
run_subject --apply keep >/dev/null
[[ $(stat -c '%a' "$destination/.mode_parent") == 700 ]] ||
  fail "keep changed the conflicting directory mode"
assert_contents "$destination/.mode_parent/.second" "second child"

echo "==> source removal deletes an unchanged old target"
new_fixture removal
printf 'remove me\n' >"$source_dir/dot_old"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
rm -- "$source_dir/dot_old"
run_subject --apply keep >/dev/null
[[ ! -e $destination/.old ]] || fail "unchanged stale target was not deleted"

echo "==> source removal applies the selected policy to a local edit"
new_fixture removal-conflict
printf 'old baseline\n' >"$source_dir/dot_old"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
printf 'edited old target\n' >"$destination/.old"
rm -- "$source_dir/dot_old"
run_subject --apply keep >/dev/null
assert_contents "$destination/.old" "edited old target"
run_subject --apply backup >/dev/null
[[ ! -e $destination/.old ]] || fail "backup policy did not delete the stale conflict"
backup_dir=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
assert_contents "$backup_dir/home/.old" "edited old target"

echo "==> stale cleanup never follows a replacement symlink outside HOME"
new_fixture stale-symlink
mkdir -- "$source_dir/dot_tree" "$fixture/outside"
printf 'managed baseline\n' >"$source_dir/dot_tree/dot_old"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
rm -rf -- "$destination/.tree" "$source_dir/dot_tree"
printf 'managed baseline\n' >"$fixture/outside/.old"
ln -s -- "$fixture/outside" "$destination/.tree"
run_subject --apply keep >/dev/null
assert_contents "$fixture/outside/.old" "managed baseline"
[[ -L $destination/.tree ]] || fail "keep removed the conflicting symlink"
run_subject --apply backup >/dev/null
assert_contents "$fixture/outside/.old" "managed baseline"
[[ ! -e $destination/.tree && ! -L $destination/.tree ]] ||
  fail "backup policy did not remove the stale symlink itself"
backup_dir=$(find "$backup_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -L $backup_dir/home/.tree ]] || fail "backup did not preserve the stale symlink"

echo "==> stale cleanup never crosses a bind mount"
new_fixture stale-bind-mount
mkdir -- "$source_dir/dot_tree" "$fixture/outside"
printf 'managed baseline\n' >"$source_dir/dot_tree/dot_old"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
rm -rf -- "$destination/.tree" "$source_dir/dot_tree"
mkdir -- "$destination/.tree"
printf 'managed baseline\n' >"$fixture/outside/.old"
printf 'outside sentinel\n' >"$fixture/outside/sentinel"
if unshare -Ur -m true 2>/dev/null; then
  unshare -Ur -m bash -s -- \
    "$subject" "$source_dir" "$destination" "$state_file" \
    "$backup_root" "$fixture/outside" <<'BIND_MOUNT_TEST'
set -euo pipefail
subject=$1
source_dir=$2
destination=$3
state_file=$4
backup_root=$5
outside=$6
mount --bind "$outside" "$destination/.tree"
trap 'umount -- "$destination/.tree"' EXIT
DOTFILES_SOURCE="$source_dir" \
  CHEZMOI_DESTINATION="$destination" \
  CHEZMOI_PERSISTENT_STATE="$state_file" \
  DOTFILES_BACKUP_ROOT="$backup_root" \
  "$subject" --apply keep >/dev/null
[[ $(<"$outside/.old") == "managed baseline" ]]
[[ $(<"$outside/sentinel") == "outside sentinel" ]]
set +e
DOTFILES_SOURCE="$source_dir" \
  CHEZMOI_DESTINATION="$destination" \
  CHEZMOI_PERSISTENT_STATE="$state_file" \
  DOTFILES_BACKUP_ROOT="$backup_root" \
  "$subject" --check backup >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 4 ]]
BIND_MOUNT_TEST
else
  echo "==> Skipping bind-mount regression: unprivileged mount namespaces unavailable"
fi

echo "==> a stale mountpoint target is rejected before recursive replacement"
new_fixture stale-direct-mount
mkdir -- "$source_dir/dot_tree" "$fixture/outside"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
rm -rf -- "$destination/.tree" "$source_dir/dot_tree"
mkdir -- "$destination/.tree"
printf 'outside sentinel\n' >"$fixture/outside/sentinel"
if unshare -Ur -m true 2>/dev/null; then
  unshare -Ur -m bash -s -- \
    "$subject" "$source_dir" "$destination" "$state_file" \
    "$backup_root" "$fixture/outside" <<'DIRECT_MOUNT_TEST'
set -euo pipefail
subject=$1
source_dir=$2
destination=$3
state_file=$4
backup_root=$5
outside=$6
mount --bind "$outside" "$destination/.tree"
trap 'umount -- "$destination/.tree"' EXIT
set +e
DOTFILES_SOURCE="$source_dir" \
  CHEZMOI_DESTINATION="$destination" \
  CHEZMOI_PERSISTENT_STATE="$state_file" \
  DOTFILES_BACKUP_ROOT="$backup_root" \
  "$subject" --apply overwrite >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 4 ]]
[[ $(<"$outside/sentinel") == "outside sentinel" ]]
DIRECT_MOUNT_TEST
else
  echo "==> Skipping direct-mount regression: unprivileged mount namespaces unavailable"
fi

echo "==> stale directory cleanup rejects unmanaged descendant mounts"
new_fixture stale-descendant-mount
mkdir -- "$source_dir/dot_tree" "$fixture/outside"
printf 'managed baseline\n' >"$source_dir/dot_tree/dot_old"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
rm -rf -- "$source_dir/dot_tree"
mkdir -- "$destination/.tree/mounted"
printf 'outside sentinel\n' >"$fixture/outside/sentinel"
if unshare -Ur -m true 2>/dev/null; then
  unshare -Ur -m bash -s -- \
    "$subject" "$source_dir" "$destination" "$state_file" \
    "$backup_root" "$fixture/outside" <<'DESCENDANT_MOUNT_TEST'
set -euo pipefail
subject=$1
source_dir=$2
destination=$3
state_file=$4
backup_root=$5
outside=$6
mount --bind "$outside" "$destination/.tree/mounted"
trap 'umount -- "$destination/.tree/mounted"' EXIT
set +e
DOTFILES_SOURCE="$source_dir" \
  CHEZMOI_DESTINATION="$destination" \
  CHEZMOI_PERSISTENT_STATE="$state_file" \
  DOTFILES_BACKUP_ROOT="$backup_root" \
  "$subject" --apply overwrite >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 4 ]]
[[ $(<"$outside/sentinel") == "outside sentinel" ]]
DESCENDANT_MOUNT_TEST
else
  echo "==> Skipping descendant-mount regression: unprivileged mount namespaces unavailable"
fi

echo "==> symlink destinations are rejected before conflict handling"
new_fixture symlink-destination
mv -- "$destination" "$fixture/real-home"
ln -s -- "$fixture/real-home" "$destination"
set +e
run_subject --check backup >/dev/null 2>&1
symlink_destination_status=$?
set -e
[[ $symlink_destination_status -ne 0 ]] || fail "symlink destination was accepted"

echo "==> removing a run hook never deletes its synthetic target path"
new_fixture stale-script
printf '#!/usr/bin/env bash\n:\n' >"$source_dir/run_once_probe"
chmod +x "$source_dir/run_once_probe"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" --force apply
script_target=$(chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$state_file" state dump |
  jq -r '(.entryState // {}) | to_entries[] | select(.value.type == "script") | .key')
[[ -n $script_target ]] || fail "run hook did not create a script state entry"
rm -- "$source_dir/run_once_probe"
printf 'unrelated user file\n' >"$script_target"
run_subject --apply overwrite >/dev/null
assert_contents "$script_target" "unrelated user file"

echo "==> keep runs independent after hooks despite unrelated conflicts"
new_fixture hook-dependency
printf '#!/usr/bin/env bash\nprintf hook-ran > %q\n' "$destination/hook-ran" \
  >"$source_dir/run_after_hook.sh"
run_subject --apply keep >/dev/null
assert_contents "$destination/hook-ran" "hook-ran"

echo "==> legacy chezmoi baseline migrates before classifying updates"
new_fixture legacy-migration
mkdir -p -- "$destination/.config/chezmoi"
legacy_state="$destination/.config/chezmoi/chezmoistate.boltdb"
printf 'legacy baseline\n' >"$source_dir/dot_legacy"
chezmoi --config /dev/null --config-format toml \
  --source "$source_dir" --destination "$destination" \
  --persistent-state "$legacy_state" --force apply
printf 'repository update\n' >"$source_dir/dot_legacy"
run_subject --apply keep >/dev/null
assert_contents "$destination/.legacy" "repository update"

echo "Dotfile conflict policy tests passed."
