#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_revision_file=$repo_root/packages/codex-desktop-source-revision.txt
dmg_digest_file=$repo_root/packages/codex-desktop-dmg-sha256.txt
repository=${CODEX_DESKTOP_REPOSITORY:-https://github.com/ilysenko/codex-desktop-linux.git}
cache_home=${XDG_CACHE_HOME:-$HOME/.cache}
state_home=${XDG_STATE_HOME:-$HOME/.local/state}
source_dir=${CODEX_DESKTOP_SOURCE_DIR:-$cache_home/enoshima/codex-desktop-linux/source}
state_dir=${CODEX_DESKTOP_STATE_DIR:-$state_home/enoshima/codex-desktop-linux}
dmg_cache=${CODEX_DESKTOP_DMG_CACHE:-$cache_home/codex-desktop/Codex.dmg}
revision_marker=$state_dir/installed-source-revision
max_build_threads=${CODEX_DESKTOP_MAX_BUILD_THREADS:-0}
build_timeout_seconds=${CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS:-1800}
build_attempts=${CODEX_DESKTOP_BUILD_ATTEMPTS:-3}
build_retry_delay_seconds=${CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS:-15}
mise_config=$repo_root/home/dot_config/mise/config.toml

export GIT_TERMINAL_PROMPT=0

die() {
  printf 'Codex Desktop install failed: %s\n' "$*" >&2
  exit 1
}

if [[ $EUID -eq 0 ]]; then
  die 'build the application as the target desktop user, not root'
fi

for command in git make mise pacman sha256sum sudo timeout; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

[[ -f $mise_config ]] || die "managed mise configuration is missing: $mise_config"
[[ -f $source_revision_file ]] ||
  die "source revision lock is missing: $source_revision_file"
[[ -f $dmg_digest_file ]] ||
  die "DMG digest lock is missing: $dmg_digest_file"
read -r locked_ref <"$source_revision_file"
read -r locked_dmg_sha256 <"$dmg_digest_file"
ref=${CODEX_DESKTOP_REF:-$locked_ref}
expected_dmg_sha256=${CODEX_DESKTOP_DMG_SHA256:-$locked_dmg_sha256}
[[ -n $repository && $repository != -* ]] || die 'CODEX_DESKTOP_REPOSITORY is invalid'
if [[ ! $ref =~ ^[A-Za-z0-9._/-]+$ || $ref == -* || $ref == */.. || $ref == ../* ]]; then
  die 'CODEX_DESKTOP_REF must be a revision or branch without whitespace or option syntax'
fi
if [[ ! $expected_dmg_sha256 =~ ^[0-9a-f]{64}$ ]]; then
  die 'CODEX_DESKTOP_DMG_SHA256 must be a lowercase SHA-256 digest'
fi
if [[ ! $max_build_threads =~ ^[0-9]+$ ]]; then
  die 'CODEX_DESKTOP_MAX_BUILD_THREADS must be 0 or a positive integer'
fi
if [[ ! $build_timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
  die 'CODEX_DESKTOP_BUILD_TIMEOUT_SECONDS must be a positive integer'
fi
if [[ ! $build_attempts =~ ^[1-9][0-9]*$ ]]; then
  die 'CODEX_DESKTOP_BUILD_ATTEMPTS must be a positive integer'
fi
if [[ ! $build_retry_delay_seconds =~ ^[0-9]+$ ]]; then
  die 'CODEX_DESKTOP_BUILD_RETRY_DELAY_SECONDS must be zero or a positive integer'
fi
if [[ -e $dmg_cache || -L $dmg_cache ]]; then
  [[ -f $dmg_cache && ! -L $dmg_cache ]] ||
    die "Codex DMG cache is not a regular file: $dmg_cache"
  [[ $(stat -c %s -- "$dmg_cache") -ge 512 ]] ||
    die "Codex DMG cache is too small: $dmg_cache"
  [[ $(tail -c 512 -- "$dmg_cache" | head -c 4) == koly ]] ||
    die "Codex DMG cache has no UDIF trailer: $dmg_cache"
  actual_dmg_sha256=$(sha256sum -- "$dmg_cache")
  actual_dmg_sha256=${actual_dmg_sha256%% *}
  [[ $actual_dmg_sha256 == "$expected_dmg_sha256" ]] ||
    die "Codex DMG cache digest is $actual_dmg_sha256, expected $expected_dmg_sha256"
fi

mkdir -p -- "$(dirname -- "$source_dir")" "$state_dir"

if [[ -e $source_dir && ! -d $source_dir/.git ]]; then
  die "managed source path exists but is not a Git checkout: $source_dir"
fi

if [[ -d $source_dir/.git ]]; then
  current_origin=$(git -C "$source_dir" remote get-url origin)
  [[ $current_origin == "$repository" ]] ||
    die "managed checkout origin is $current_origin, expected $repository"

  if [[ -n $(git -C "$source_dir" status --porcelain --untracked-files=all) ]]; then
    die "managed checkout contains local changes: $source_dir"
  fi

  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    current_revision=$(git -C "$source_dir" rev-parse HEAD)
    if [[ $current_revision != "$ref" ]]; then
      echo "==> Fetching pinned ilysenko/codex-desktop-linux revision ($ref)"
      git -C "$source_dir" fetch --depth 1 origin "$ref"
      fetched_revision=$(git -C "$source_dir" rev-parse FETCH_HEAD)
      [[ $fetched_revision == "$ref" ]] ||
        die "fetched source revision is $fetched_revision, expected $ref"
      git -C "$source_dir" checkout --detach "$fetched_revision"
    elif [[ -n $(git -C "$source_dir" symbolic-ref --quiet --short HEAD || true) ]]; then
      git -C "$source_dir" checkout --detach "$ref"
    fi
    echo "==> Using pinned ilysenko/codex-desktop-linux revision ($ref)"
  else
    current_branch=$(git -C "$source_dir" symbolic-ref --quiet --short HEAD || true)
    [[ $current_branch == "$ref" ]] ||
      die "managed checkout branch is ${current_branch:-detached}, expected $ref"
    echo "==> Updating ilysenko/codex-desktop-linux checkout ($ref)"
    git -C "$source_dir" pull --ff-only --no-rebase origin "$ref"
  fi
else
  clone_root=$(mktemp -d "$(dirname -- "$source_dir")/.codex-desktop-clone.XXXXXX")
  cleanup_clone() {
    rm -rf -- "$clone_root"
  }
  trap cleanup_clone EXIT
  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    echo "==> Cloning pinned ilysenko/codex-desktop-linux revision ($ref)"
    git -C "$clone_root" init --quiet source
    git -C "$clone_root/source" remote add origin "$repository"
    git -C "$clone_root/source" fetch --depth 1 origin "$ref"
    fetched_revision=$(git -C "$clone_root/source" rev-parse FETCH_HEAD)
    [[ $fetched_revision == "$ref" ]] ||
      die "fetched source revision is $fetched_revision, expected $ref"
    git -C "$clone_root/source" checkout --quiet --detach "$fetched_revision"
  else
    echo "==> Cloning ilysenko/codex-desktop-linux checkout ($ref)"
    git clone --depth 1 --single-branch --branch "$ref" \
      "$repository" "$clone_root/source"
  fi
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
dmg_make_arg=()
if [[ -f $dmg_cache ]]; then
  printf '==> Using the verified Codex DMG cache: %s\n' "$dmg_cache"
  dmg_make_arg+=("DMG=$dmg_cache")
fi
build_succeeded=false
for ((attempt = 1; attempt <= build_attempts; attempt++)); do
  printf '==> Codex Desktop build attempt %d/%d (timeout: %ss)\n' \
    "$attempt" "$build_attempts" "$build_timeout_seconds"
  if MISE_CONFIG_FILE="$mise_config" timeout \
    --signal=TERM \
    --kill-after=30s \
    "${build_timeout_seconds}s" \
    mise exec -- \
    make -C "$source_dir" install-native \
    "PACKAGE_VERSION=$package_version" \
    'PACKAGE_WITH_UPDATER=1' \
    "MAX_BUILD_THREADS=$max_build_threads" \
    "${dmg_make_arg[@]}"; then
    build_succeeded=true
    break
  else
    status=$?
  fi

  if ((attempt == build_attempts)); then
    if ((status == 124 || status == 137)); then
      die "the upstream build exceeded ${build_timeout_seconds}s on all attempts"
    fi
    die "the upstream build failed with status $status after $build_attempts attempts"
  fi
  printf \
    'WARNING: Codex Desktop build attempt %d/%d failed with status %d; retrying in %ss.\n' \
    "$attempt" "$build_attempts" "$status" "$build_retry_delay_seconds" >&2
  sleep "$build_retry_delay_seconds"
done

[[ $build_succeeded == true ]] || die 'the upstream build did not complete'

pacman -Q codex-desktop >/dev/null 2>&1 ||
  die 'the upstream build completed without installing codex-desktop'

marker_candidate=$revision_marker.new
printf '%s\n' "$revision" >"$marker_candidate"
mv -- "$marker_candidate" "$revision_marker"
printf '==> Installed Codex Desktop from source revision %s\n' "${revision:0:12}"
