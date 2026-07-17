#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repository=${CODEX_DESKTOP_REPOSITORY:-https://github.com/ilysenko/codex-desktop-linux.git}
ref=${CODEX_DESKTOP_REF:-main}
cache_home=${XDG_CACHE_HOME:-$HOME/.cache}
state_home=${XDG_STATE_HOME:-$HOME/.local/state}
source_dir=${CODEX_DESKTOP_SOURCE_DIR:-$cache_home/enoshima/codex-desktop-linux/source}
state_dir=${CODEX_DESKTOP_STATE_DIR:-$state_home/enoshima/codex-desktop-linux}
revision_marker=$state_dir/installed-source-revision
max_build_threads=${CODEX_DESKTOP_MAX_BUILD_THREADS:-0}
mise_config=$repo_root/home/dot_config/mise/config.toml

export GIT_TERMINAL_PROMPT=0

die() {
  printf 'Codex Desktop install failed: %s\n' "$*" >&2
  exit 1
}

if [[ $EUID -eq 0 ]]; then
  die 'build the application as the target desktop user, not root'
fi

for command in git make mise pacman sudo; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

[[ -f $mise_config ]] || die "managed mise configuration is missing: $mise_config"
[[ -n $repository && $repository != -* ]] || die 'CODEX_DESKTOP_REPOSITORY is invalid'
if [[ ! $ref =~ ^[A-Za-z0-9._/-]+$ || $ref == -* || $ref == */.. || $ref == ../* ]]; then
  die 'CODEX_DESKTOP_REF must be a branch name without whitespace or option syntax'
fi
if [[ ! $max_build_threads =~ ^[0-9]+$ ]]; then
  die 'CODEX_DESKTOP_MAX_BUILD_THREADS must be 0 or a positive integer'
fi

mkdir -p -- "$(dirname -- "$source_dir")" "$state_dir"

if [[ -e $source_dir && ! -d $source_dir/.git ]]; then
  die "managed source path exists but is not a Git checkout: $source_dir"
fi

if [[ -d $source_dir/.git ]]; then
  current_origin=$(git -C "$source_dir" remote get-url origin)
  [[ $current_origin == "$repository" ]] ||
    die "managed checkout origin is $current_origin, expected $repository"

  current_branch=$(git -C "$source_dir" symbolic-ref --quiet --short HEAD || true)
  [[ $current_branch == "$ref" ]] ||
    die "managed checkout branch is ${current_branch:-detached}, expected $ref"

  if [[ -n $(git -C "$source_dir" status --porcelain --untracked-files=all) ]]; then
    die "managed checkout contains local changes: $source_dir"
  fi

  echo "==> Updating ilysenko/codex-desktop-linux checkout ($ref)"
  git -C "$source_dir" pull --ff-only --no-rebase origin "$ref"
else
  echo "==> Cloning ilysenko/codex-desktop-linux checkout ($ref)"
  clone_root=$(mktemp -d "$(dirname -- "$source_dir")/.codex-desktop-clone.XXXXXX")
  cleanup_clone() {
    rm -rf -- "$clone_root"
  }
  trap cleanup_clone EXIT
  git clone --depth 1 --single-branch --branch "$ref" \
    "$repository" "$clone_root/source"
  mv -- "$clone_root/source" "$source_dir"
  rmdir -- "$clone_root"
  trap - EXIT
fi

revision=$(git -C "$source_dir" rev-parse HEAD)
installed_revision=
if [[ -f $revision_marker ]]; then
  read -r installed_revision <"$revision_marker" || true
fi

if [[ $installed_revision == "$revision" ]] &&
  pacman -Q codex-desktop >/dev/null 2>&1; then
  printf '==> Codex Desktop is current at source revision %s\n' "${revision:0:12}"
  exit 0
fi

commit_epoch=$(git -C "$source_dir" show -s --format=%ct HEAD)
commit_short=$(git -C "$source_dir" rev-parse --short=12 HEAD)
package_version=$(date -u --date="@$commit_epoch" +%Y.%m.%d.%H%M%S)+$commit_short

printf '==> Building Codex Desktop %s from ilysenko/codex-desktop-linux\n' \
  "$package_version"
MISE_CONFIG_FILE="$mise_config" mise exec -- \
  make -C "$source_dir" install-native \
  "PACKAGE_VERSION=$package_version" \
  'PACKAGE_WITH_UPDATER=1' \
  "MAX_BUILD_THREADS=$max_build_threads"

pacman -Q codex-desktop >/dev/null 2>&1 ||
  die 'the upstream build completed without installing codex-desktop'

marker_candidate=$revision_marker.new
printf '%s\n' "$revision" >"$marker_candidate"
mv -- "$marker_candidate" "$revision_marker"
printf '==> Installed Codex Desktop from source revision %s\n' "${revision:0:12}"
