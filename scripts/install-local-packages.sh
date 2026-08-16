#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
local_package_build_attempts=${LOCAL_PACKAGE_BUILD_ATTEMPTS:-4}
local_package_retry_delay_seconds=${LOCAL_PACKAGE_BUILD_RETRY_DELAY_SECONDS:-10}
sudo_command=${SUDO_COMMAND_WRAPPER:-sudo}
vicinae_keep_held=${VICINAE_KEEP_HELD:-false}
local_package_cache_home=${XDG_CACHE_HOME:-$HOME/.cache}
local_package_build_parent=$local_package_cache_home/enoshima/local-package-builds
local_package_build_root=
verified_local_install_stage=
verified_local_staged_archive=
verified_local_install_attempted=false
verified_local_install_stage_parent=/var/lib/enoshima/local-package-install-staging
verified_local_dependency_hook_dir=
verified_local_attestation_sha256=a3e3e3452cf038a1fc86ccf04f89f2ebb5f6bae3c7fd952648e42cd7732cd222
vicinae_reviewed_guard_sha256=952bbd60b19af764d06fcc9833169b9b9f0e671c791b1b12d36ca3a27c2504c9

[[ $local_package_build_attempts =~ ^[1-9][0-9]*$ ]] || {
  echo "LOCAL_PACKAGE_BUILD_ATTEMPTS must be a positive integer." >&2
  exit 1
}
[[ $local_package_retry_delay_seconds =~ ^[0-9]+$ ]] || {
  echo "LOCAL_PACKAGE_BUILD_RETRY_DELAY_SECONDS must be zero or a positive integer." >&2
  exit 1
}
[[ $vicinae_keep_held =~ ^(true|false)$ ]] || {
  echo 'VICINAE_KEEP_HELD must be true or false.' >&2
  exit 1
}

prepare_local_package_build_parent() {
  [[ ! -L $local_package_build_parent ]] || {
    echo "Local package build parent is a symlink: $local_package_build_parent" >&2
    return 1
  }
  install -d -m 0700 -- "$local_package_build_parent"
  [[ -d $local_package_build_parent && ! -L $local_package_build_parent ]] || {
    echo "Local package build parent is missing or unsafe: $local_package_build_parent" >&2
    return 1
  }
  [[ $(stat -c '%u:%a' -- "$local_package_build_parent") == "$EUID:700" ]] || {
    echo "Local package build parent has unsafe ownership or mode: $local_package_build_parent" >&2
    return 1
  }
}

cleanup_local_package_build_root() {
  local root=${local_package_build_root:-}

  [[ -n $root ]] || return 0
  if [[ ${root%/*} != "$local_package_build_parent" ||
    ${root##*/} != run.* ||
    ! -d $root || -L $root ]]; then
    echo "Refusing to clean an unsafe local package build root: $root" >&2
    return 1
  fi
  rm -rf -- "$root"
  local_package_build_root=
}

cleanup_local_package_build() {
  local status=$? cleanup_status=0
  trap - EXIT
  cleanup_verified_local_dependency_hooks || cleanup_status=1
  cleanup_verified_local_install_stage || cleanup_status=1
  cleanup_local_package_build_root || cleanup_status=1
  if ((status != 0)); then
    exit "$status"
  fi
  exit "$cleanup_status"
}

cleanup_verified_local_dependency_hooks() {
  local hook_dir=${verified_local_dependency_hook_dir:-}

  [[ -n $hook_dir ]] || return 0
  [[ ${hook_dir%/*} == /run && ${hook_dir##*/} == enoshima-local-hooks.* &&
    -d $hook_dir && ! -L $hook_dir &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$hook_dir") == root:root:700 ]] ||
    return 70
  "$sudo_command" /usr/bin/rm -rf -- "$hook_dir" || return 70
  verified_local_dependency_hook_dir=
}

cleanup_verified_local_install_stage() {
  local stage=${verified_local_install_stage:-}

  [[ -n $stage ]] || return 0
  if [[ ${stage%/*} != "$verified_local_install_stage_parent" ||
    ${stage##*/} != run.* || ! -d $stage || -L $stage ||
    $(/usr/bin/stat -c '%U:%G:%a' -- "$stage") != root:root:711 ]]; then
    echo "Refusing to clean an unsafe verified local install stage: $stage" >&2
    return 70
  fi
  "$sudo_command" /usr/bin/rm -rf -- "$stage" || return 70
  verified_local_install_stage=
  verified_local_staged_archive=
  verified_local_install_attempted=false
}

build_local_package() {
  local package_name=$1 package_dir=$2
  local attempt status

  for ((attempt = 1; attempt <= local_package_build_attempts; attempt++)); do
    if (
      cd "$package_dir"
      makepkg \
        --clean \
        --cleanbuild \
        --install \
        --needed \
        --noconfirm \
        --rmdeps \
        --syncdeps
    ); then
      return 0
    else
      status=$?
    fi

    if ((attempt == local_package_build_attempts)); then
      printf \
        'ERROR: local package %s exhausted %d build attempts (last status: %d).\n' \
        "$package_name" "$local_package_build_attempts" "$status" >&2
      return "$status"
    fi

    printf \
      'WARNING: local package %s build attempt %d/%d failed with status %d; retrying in %ss.\n' \
      "$package_name" "$attempt" "$local_package_build_attempts" "$status" \
      "$local_package_retry_delay_seconds" >&2
    sleep "$local_package_retry_delay_seconds"
  done
}

verified_local_package() {
  case $1 in
    hyprshell-bin | vicinae-bin) return 0 ;;
    *) return 1 ;;
  esac
}

verified_local_provenance_checker() {
  case $1 in
    hyprshell-bin) printf '%s\n' "$repo_root/scripts/check-hyprshell-provenance" ;;
    vicinae-bin) printf '%s\n' "$repo_root/scripts/check-vicinae-provenance" ;;
    *) return 1 ;;
  esac
}

verified_local_source_date_epoch() {
  case $1 in
    hyprshell-bin) printf '%s\n' 1781132855 ;;
    vicinae-bin) printf '%s\n' 1786353281 ;;
    *) return 1 ;;
  esac
}

verified_local_desired_version() {
  local package_name=$1 verification_root=${2:-$repo_root}

  jq -er '.package.version' \
    "$verification_root/packages/local/$package_name/provenance.json"
}

verified_local_attestation_helper() {
  printf '%s\n' "$repo_root/scripts/lib/verified-local-attestation"
}

stage_verified_local_attestation_helper() {
  local source stage_root=/run/enoshima-verified-local-attestation
  local staged=$stage_root/verified-local-attestation actual

  source=$(verified_local_attestation_helper) || return 70
  [[ -f $source && ! -L $source ]] || return 70
  actual=$(/usr/bin/sha256sum -- "$source") || return 70
  [[ ${actual%% *} == "$verified_local_attestation_sha256" ]] || return 70
  verified_root_owned_ancestor_safe / || return 70
  verified_root_owned_ancestor_safe /run || return 70
  if [[ -e $stage_root || -L $stage_root ]]; then
    [[ -d $stage_root && ! -L $stage_root &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$stage_root") == root:root:711 ]] ||
      return 70
  else
    "$sudo_command" /usr/bin/install -d -o root -g root -m 0711 -- "$stage_root" ||
      return 70
  fi
  if [[ -e $staged || -L $staged ]]; then
    [[ -f $staged && ! -L $staged &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$staged") == root:root:755 ]] ||
      return 70
  fi
  [[ -f $source && ! -L $source ]] || return 70
  "$sudo_command" /usr/bin/tee "$staged" <"$source" >/dev/null || return 70
  "$sudo_command" /usr/bin/chown root:root "$staged" || return 70
  "$sudo_command" /usr/bin/chmod 0755 "$staged" || return 70
  actual=$(/usr/bin/sha256sum -- "$staged") || return 70
  [[ -f $staged && ! -L $staged &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$staged") == root:root:755 &&
    ${actual%% *} == "$verified_local_attestation_sha256" ]] || return 70
  printf '%s\n' "$staged"
}

run_verified_local_attestation() {
  local action=$1 package_name=$2 version=${3:-} verification_root=${4:-$repo_root}
  local archive_path=${5:-}
  local helper checker manifest
  local -a args=()

  helper=$(stage_verified_local_attestation_helper) || return 70
  checker=$(verified_local_provenance_checker "$package_name") || return 70
  manifest=$verification_root/packages/local/$package_name/provenance.json
  [[ -x $helper && -f $checker && ! -L $checker &&
    -f $manifest && ! -L $manifest ]] || return 70
  args=(
    "$action"
    --package "$package_name"
  )
  if [[ $action != invalidate ]]; then
    args+=(
      --version "$version"
      --policy-file "checker=$checker"
      --policy-file "manifest=$manifest"
    )
  fi
  if [[ $action == record ]]; then
    args+=(--archive "$archive_path")
  fi
  "$sudo_command" "$helper" "${args[@]}"
}

verify_verified_local_install_attestation() {
  run_verified_local_attestation verify "$1" "$2" "${3:-$repo_root}"
}

record_verified_local_install_attestation() {
  run_verified_local_attestation record "$1" "$2" "${3:-$repo_root}" "$4"
}

invalidate_verified_local_install_attestation() {
  run_verified_local_attestation invalidate "$1"
}

verify_local_package_provenance() {
  local package_name=$1 archive_path=${2:-} verification_root=${3:-$repo_root}
  local checker

  checker=$(verified_local_provenance_checker "$package_name") || return 1
  if [[ -n $archive_path ]]; then
    "$checker" --root "$verification_root" --package-archive "$archive_path"
  else
    "$checker" --root "$verification_root"
  fi
}

build_verified_local_package() {
  local package_name=$1 package_dir=$2 workspace=$3 verification_root=$4
  local sandbox_runner=${5:-run_verified_local_sandboxed_makepkg}
  local makepkg_config=$workspace/makepkg.conf
  local package_output=$workspace/packages
  local attempt archive_path status=1 install_status=0 desired_version
  local -a package_paths=()

  [[ -f /etc/makepkg.conf && ! -L /etc/makepkg.conf ]] || {
    echo 'ERROR: /etc/makepkg.conf is missing or unsafe.' >&2
    return 1
  }
  install -d -m 0700 -- "$package_output" "$workspace/build" "$workspace/sources"
  cp -- /etc/makepkg.conf "$makepkg_config"
  printf '\nPKGDEST=/build/workspace/packages\nSRCDEST=/build/workspace/sources\nBUILDDIR=/build/workspace/build\n' \
    >>"$makepkg_config"

  verify_local_package_provenance "$package_name" '' "$verification_root"
  install_verified_local_build_dependencies "$package_name" "$verification_root"

  for ((attempt = 1; attempt <= local_package_build_attempts; attempt++)); do
    # Each retry begins from a fresh srcdir. The network-enabled preparation
    # phase may repopulate verified downloads, but no failed build artifact is
    # allowed to become the next attempt's source input.
    rm -rf -- "$workspace/build"
    install -d -m 0700 -- "$workspace/build"
    if (
      "$sandbox_runner" \
        "$package_name" "$package_dir" "$workspace" prepare "$verification_root" &&
        "$sandbox_runner" \
          "$package_name" "$package_dir" "$workspace" build "$verification_root"
    ); then
      status=0
      break
    else
      status=$?
    fi

    if ((attempt == local_package_build_attempts)); then
      printf \
        'ERROR: verified local package %s exhausted %d build attempts (last status: %d).\n' \
        "$package_name" "$local_package_build_attempts" "$status" >&2
      return "$status"
    fi
    printf \
      'WARNING: verified local package %s build attempt %d/%d failed with status %d; retrying in %ss.\n' \
      "$package_name" "$attempt" "$local_package_build_attempts" "$status" \
      "$local_package_retry_delay_seconds" >&2
    sleep "$local_package_retry_delay_seconds"
  done

  mapfile -t package_paths < <(
    find "$package_output" -maxdepth 1 -type f -name "$package_name-*.pkg.tar.*" \
      -print | LC_ALL=C sort
  )
  if ((${#package_paths[@]} != 1)); then
    echo "ERROR: verified $package_name build must produce exactly one package archive." >&2
    return 1
  fi
  archive_path=${package_paths[0]}

  [[ $status == 0 && -f $archive_path && ! -L $archive_path ]] || {
    echo "ERROR: verified $package_name package archive is missing or unsafe." >&2
    return 1
  }
  if ! verify_local_package_provenance \
    "$package_name" "$archive_path" "$verification_root"; then
    echo "ERROR: refusing to install an unverified $package_name package archive." >&2
    return 1
  fi
  desired_version=$(verified_local_desired_version \
    "$package_name" "$verification_root") || return 70
  verified_local_install_attempted=false
  if install_verified_local_archive \
    "$package_name" "$archive_path" "$verification_root"; then
    install_status=0
  else
    install_status=$?
  fi
  if [[ $verified_local_install_attempted != true ]]; then
    cleanup_verified_local_install_stage || return 70
    return "$install_status"
  fi
  # pacman may return nonzero after committing a package. Establish live
  # safety and an exact root-owned attestation before preserving that status.
  enforce_verified_local_installed_safety \
    "$package_name" "$desired_version" || {
    cleanup_verified_local_install_stage || true
    return 70
  }
  record_verified_local_install_attestation \
    "$package_name" "$desired_version" "$verification_root" \
    "$verified_local_staged_archive" || {
    cleanup_verified_local_install_stage || true
    return 70
  }
  # The root-owned archive remains available until live installed-file safety
  # has been established. The EXIT trap owns cleanup on every failure path.
  cleanup_verified_local_install_stage || return 70
  ((install_status == 0)) || return "$install_status"
  [[ $package_name == vicinae-bin ]] || return 0
  converge_vicinae_runtime_hold
}

install_verified_local_build_dependencies() {
  local package_name=$1 verification_root=${2:-$repo_root}
  local manifest=$verification_root/packages/local/$package_name/provenance.json
  local -a dependencies=()

  mapfile -t dependencies < <(
    jq -er '
      .packaging |
      [.runtimeDependencies[], .makeDependencies[], .checkDependencies[]] |
      unique[]
    ' "$manifest"
  )
  ((${#dependencies[@]} > 0)) || return 1
  hold_vicinae_for_build_dependencies "$package_name" "$verification_root" ||
    return 70
  prepare_verified_local_dependency_hooks "$package_name" || return 70
  local dependency_status=0
  if "$sudo_command" /usr/bin/pacman \
    --hookdir "$verified_local_dependency_hook_dir" \
    -S --needed --asdeps --noconfirm -- "${dependencies[@]}"; then
    dependency_status=0
  else
    dependency_status=$?
  fi
  cleanup_verified_local_dependency_hooks || return 70
  return "$dependency_status"
}

stage_reviewed_vicinae_dependency_guard() {
  local verification_root=${1:-$repo_root}
  local source=$verification_root/packages/local/vicinae-bin/vicinae-qt-guard
  local manifest=$verification_root/packages/local/vicinae-bin/provenance.json
  local stage_dir=/run/enoshima-vicinae-reviewed
  local staged=$stage_dir/vicinae-qt-guard
  local expected actual

  [[ -f $source && ! -L $source && -f $manifest && ! -L $manifest ]] ||
    return 70
  expected=$(jq -er '.packaging.localSources["vicinae-qt-guard"]' "$manifest") ||
    return 70
  [[ $expected == "$vicinae_reviewed_guard_sha256" ]] || return 70
  verified_root_owned_ancestor_safe / || return 70
  verified_root_owned_ancestor_safe /run || return 70
  if [[ -e $stage_dir || -L $stage_dir ]]; then
    [[ -d $stage_dir && ! -L $stage_dir &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$stage_dir") == root:root:711 ]] ||
      return 70
  else
    "$sudo_command" /usr/bin/install -d -o root -g root -m 0711 -- "$stage_dir" ||
      return 70
  fi
  if [[ -e $staged || -L $staged ]]; then
    [[ -f $staged && ! -L $staged &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$staged") == root:root:755 ]] ||
      return 70
  fi
  [[ -f $source && ! -L $source ]] || return 70
  "$sudo_command" /usr/bin/tee "$staged" <"$source" >/dev/null || return 70
  "$sudo_command" /usr/bin/chown root:root "$staged" || return 70
  "$sudo_command" /usr/bin/chmod 0755 "$staged" || return 70
  actual=$(/usr/bin/sha256sum -- "$staged") || return 70
  [[ -f $staged && ! -L $staged &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$staged") == root:root:755 &&
    ${actual%% *} == "$vicinae_reviewed_guard_sha256" ]] || return 70
  printf '%s\n' "$staged"
}

hold_vicinae_for_build_dependencies() {
  local package_name=$1 verification_root=${2:-$repo_root} staged_guard

  [[ $package_name == vicinae-bin ]] || return 0
  staged_guard=$(stage_reviewed_vicinae_dependency_guard "$verification_root") ||
    return 70
  if ! "$sudo_command" "$staged_guard" hold; then
    printf '%s\n' \
      'ERROR: refusing to change Vicinae build dependencies while its runtime is active.' \
      >&2 || true
    return 70
  fi
}

prepare_verified_local_dependency_hooks() {
  local package_name=$1

  verified_root_owned_ancestor_safe / || return 70
  verified_root_owned_ancestor_safe /run || return 70
  verified_local_dependency_hook_dir=$(
    "$sudo_command" /usr/bin/mktemp -d --tmpdir=/run enoshima-local-hooks.XXXXXXXX
  ) || return 70
  [[ ${verified_local_dependency_hook_dir%/*} == /run &&
    ${verified_local_dependency_hook_dir##*/} == enoshima-local-hooks.* ]] ||
    return 70
  "$sudo_command" /usr/bin/chown root:root "$verified_local_dependency_hook_dir" ||
    return 70
  "$sudo_command" /usr/bin/chmod 0700 "$verified_local_dependency_hook_dir" ||
    return 70
  prepare_verified_local_hook_overrides \
    "$package_name" "$verified_local_dependency_hook_dir" || return 70
}

run_verified_local_sandboxed_makepkg() {
  local package_name=$1 package_dir=$2 workspace=$3 phase=${4:-build}
  local verification_root=${5:-$repo_root}
  local sandbox_home=/build/home
  local resolver_source source_date_epoch rustc_version cargo_version toolchain_root
  local manifest rustc_commit cargo_commit rust_host=x86_64-unknown-linux-gnu
  local expected_toolchain_root
  local -a resolver_bind_args=()
  local -a toolchain_bind_args=()
  local -a network_args=(--unshare-net)
  local -a makepkg_args=(--noextract --noprepare)

  [[ -x /usr/bin/bwrap ]] || {
    echo "ERROR: bubblewrap is required for the unprivileged $package_name build." >&2
    return 1
  }
  resolver_source=$(readlink -f -- /etc/resolv.conf) || {
    echo 'ERROR: the system resolver configuration cannot be resolved.' >&2
    return 1
  }
  [[ -f $resolver_source && ! -L $resolver_source ]] || {
    echo 'ERROR: the resolved system resolver configuration is unsafe.' >&2
    return 1
  }
  case $resolver_source in
    /etc/*) ;;
    /run/systemd/resolve/*)
      resolver_bind_args=(
        --dir /run/systemd
        --dir /run/systemd/resolve
        --ro-bind "$resolver_source" "$resolver_source"
      )
      ;;
    *)
      echo "ERROR: unsupported system resolver path: $resolver_source" >&2
      return 1
      ;;
  esac
  source_date_epoch=$(verified_local_source_date_epoch "$package_name") || return 1
  case $phase in
    prepare)
      network_args=(--share-net)
      makepkg_args=(--nobuild)
      ;;
    build) ;;
    *)
      echo "ERROR: unsupported verified local build phase: $phase" >&2
      return 1
      ;;
  esac
  if [[ $package_name == hyprshell-bin ]]; then
    manifest=$verification_root/packages/local/$package_name/provenance.json
    rustc_commit=$(jq -er '.build.rustToolchain.rustcCommit' "$manifest") || return 1
    cargo_commit=$(jq -er '.build.rustToolchain.cargoCommit' "$manifest") || return 1
    [[ ${RUSTUP_TOOLCHAIN:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
      echo 'ERROR: a managed numeric RUSTUP_TOOLCHAIN is required for Hyprshell.' >&2
      return 1
    }
    [[ ${LOCAL_PACKAGE_RUST_TOOLCHAIN_ROOT:-} == /* ]] || {
      echo 'ERROR: the managed Rust toolchain root is missing or relative.' >&2
      return 1
    }
    toolchain_root=$(readlink -f -- "$LOCAL_PACKAGE_RUST_TOOLCHAIN_ROOT") || {
      echo 'ERROR: the managed Rust toolchain root could not be resolved.' >&2
      return 1
    }
    expected_toolchain_root=$HOME/.rustup/toolchains/$RUSTUP_TOOLCHAIN-$rust_host
    [[ $toolchain_root == /* && $toolchain_root != / &&
      $toolchain_root == "$LOCAL_PACKAGE_RUST_TOOLCHAIN_ROOT" &&
      $toolchain_root == "$expected_toolchain_root" &&
      $toolchain_root != "$HOME" && $toolchain_root != "$HOME"/*/../* &&
      -d $HOME/.rustup && ! -L $HOME/.rustup &&
      $(stat -Lc '%u:%a' -- "$HOME/.rustup") == "$EUID:755" &&
      -d $HOME/.rustup/toolchains && ! -L $HOME/.rustup/toolchains &&
      $(stat -Lc '%u:%a' -- "$HOME/.rustup/toolchains") == "$EUID:755" &&
      -d $toolchain_root && ! -L $toolchain_root &&
      -f $toolchain_root/bin/rustc && ! -L $toolchain_root/bin/rustc &&
      -x $toolchain_root/bin/rustc &&
      -f $toolchain_root/bin/cargo && ! -L $toolchain_root/bin/cargo &&
      -x $toolchain_root/bin/cargo &&
      $(stat -Lc '%u:%a' -- "$toolchain_root") == "$EUID:755" ]] || {
      echo "ERROR: the selected Rust toolchain is unsafe: $toolchain_root" >&2
      return 1
    }
    rustc_version=$(
      /usr/bin/bwrap \
        --unshare-all --unshare-net --unshare-user \
        --uid "$EUID" --gid "$(id -g)" --disable-userns \
        --ro-bind /usr /usr \
        --symlink usr/bin /bin \
        --symlink usr/lib /lib \
        --symlink usr/lib /lib64 \
        --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
        --dir /build --ro-bind "$toolchain_root" /build/rust-toolchain \
        --dir "$sandbox_home" --clearenv \
        --setenv HOME "$sandbox_home" \
        --setenv PATH /build/rust-toolchain/bin:/usr/bin:/bin \
        --setenv LANG C.UTF-8 \
        --new-session --die-with-parent -- \
        /build/rust-toolchain/bin/rustc -vV
    ) || return 1
    cargo_version=$(
      /usr/bin/bwrap \
        --unshare-all --unshare-net --unshare-user \
        --uid "$EUID" --gid "$(id -g)" --disable-userns \
        --ro-bind /usr /usr \
        --symlink usr/bin /bin \
        --symlink usr/lib /lib \
        --symlink usr/lib /lib64 \
        --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
        --dir /build --ro-bind "$toolchain_root" /build/rust-toolchain \
        --dir "$sandbox_home" --clearenv \
        --setenv HOME "$sandbox_home" \
        --setenv PATH /build/rust-toolchain/bin:/usr/bin:/bin \
        --setenv LANG C.UTF-8 \
        --new-session --die-with-parent -- \
        /build/rust-toolchain/bin/cargo -Vv
    ) || return 1
    [[ $rustc_version == *$'\n'"commit-hash: $rustc_commit"$'\n'* &&
      $rustc_version == *$'\n'"host: $rust_host"$'\n'* &&
      $rustc_version == *$'\n'"release: $RUSTUP_TOOLCHAIN"$'\n'* &&
      $cargo_version == *$'\n'"commit-hash: $cargo_commit"$'\n'* &&
      $cargo_version == *$'\n'"host: $rust_host"$'\n'* &&
      $cargo_version == *$'\n'"release: $RUSTUP_TOOLCHAIN"$'\n'* ]] || {
      echo "ERROR: selected Rust compiler does not match the exact provenance manifest." >&2
      return 1
    }
    toolchain_bind_args=(--ro-bind "$toolchain_root" /build/rust-toolchain)
  fi
  # /etc/resolv.conf commonly targets systemd-resolved state under /run.
  # Rebind only that resolved file after replacing /run so source downloads
  # retain DNS without exposing the host runtime directory.
  /usr/bin/bwrap \
    --unshare-all \
    "${network_args[@]}" \
    --unshare-user \
    --uid "$EUID" \
    --gid "$(id -g)" \
    --disable-userns \
    --ro-bind /usr /usr \
    --symlink usr/bin /bin \
    --symlink usr/bin /sbin \
    --symlink usr/lib /lib \
    --symlink usr/lib /lib64 \
    --ro-bind /etc /etc \
    --proc /proc \
    --dev /dev \
    --tmpfs /run \
    "${resolver_bind_args[@]}" \
    --tmpfs /tmp \
    --tmpfs /var \
    --dir /var/lib \
    --ro-bind /var/lib/pacman /var/lib/pacman \
    --dir /build \
    "${toolchain_bind_args[@]}" \
    --dir "$sandbox_home" \
    --ro-bind "$package_dir" /build/package \
    --bind "$workspace" /build/workspace \
    --chdir /build/package \
    --clearenv \
    --setenv HOME "$sandbox_home" \
    --setenv PATH /build/rust-toolchain/bin:/usr/bin:/bin \
    --setenv LANG C.UTF-8 \
    --setenv SOURCE_DATE_EPOCH "$source_date_epoch" \
    --new-session \
    --die-with-parent \
    -- \
    /usr/bin/makepkg \
    --config /build/workspace/makepkg.conf \
    --clean \
    --noconfirm \
    "${makepkg_args[@]}"
}

prepare_verified_local_hook_overrides() {
  local package_name=$1 hook_dir=$2 owned_path hook_name owned_paths
  local hook_target hook_owner
  local -a hook_names=()

  "$sudo_command" /usr/bin/install -d -o root -g root -m 0700 -- "$hook_dir" ||
    return 70
  [[ -d $hook_dir && ! -L $hook_dir &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$hook_dir") == root:root:700 ]] ||
    return 70
  if /usr/bin/pacman -Qq -- "$package_name" >/dev/null 2>&1; then
    owned_paths=$(/usr/bin/pacman -Qlq -- "$package_name") || return 70
    while IFS= read -r owned_path; do
      [[ $owned_path == *.hook ]] || continue
      hook_name=${owned_path##*/}
      if [[ ! $hook_name =~ ^[A-Za-z0-9._+-]+\.hook$ ]]; then
        printf 'ERROR: installed %s owns an unsafe ALPM hook path.\n' \
          "$package_name" >&2 || true
        return 70
      fi
      [[ $owned_path == /* && $owned_path != *'//'* &&
        $owned_path != *'/./'* && $owned_path != *'/../'* ]] || return 70
      hook_names+=("$hook_name")
    done <<<"$owned_paths"
  fi
  if [[ $package_name == vicinae-bin ]]; then
    hook_names+=(
      40-vicinae-qt-pre.hook
      40-vicinae-qt-post.hook
      41-vicinae-package-pre.hook
      vicinae.hook
    )
  fi
  if ((${#hook_names[@]} > 0)); then
    mapfile -t hook_names < <(printf '%s\n' "${hook_names[@]}" | LC_ALL=C sort -u)
  fi
  for hook_name in "${hook_names[@]}"; do
    "$sudo_command" /usr/bin/ln -s -- /dev/null "$hook_dir/$hook_name" ||
      return 70
    # HookDir stays root-only (0700), so the unprivileged build shell cannot
    # safely inspect children after creation. Validate the exact root-owned
    # symlink through the already authenticated non-interactive sudo path.
    "$sudo_command" /usr/bin/test -L "$hook_dir/$hook_name" || {
      printf 'ERROR: root-owned ALPM hook override is not a symlink: %s\n' \
        "$hook_name" >&2 || true
      return 70
    }
    hook_target=$("$sudo_command" /usr/bin/readlink -- "$hook_dir/$hook_name") ||
      return 70
    hook_owner=$("$sudo_command" /usr/bin/stat -c '%U:%G' -- \
      "$hook_dir/$hook_name") || return 70
    [[ $hook_target == /dev/null && $hook_owner == root:root ]] || {
      printf 'ERROR: root-owned ALPM hook override is unsafe: %s\n' \
        "$hook_name" >&2 || true
      return 70
    }
  done
}

verified_root_owned_ancestor_safe() {
  local path=$1 uid gid mode

  [[ -d $path && ! -L $path ]] || return 1
  read -r uid gid mode < <(/usr/bin/stat -c '%u %g %a' -- "$path") || return 1
  [[ $uid == 0 && $gid == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  (((8#$mode & 8#022) == 0))
}

install_verified_local_archive() {
  local package_name=$1 archive_path=$2 verification_root=${3:-$repo_root}
  local staged_archive staged_guard hook_dir
  local stage_base=${verified_local_install_stage_parent%/*}

  local staging_ancestor
  for staging_ancestor in / /var /var/lib; do
    verified_root_owned_ancestor_safe "$staging_ancestor" || {
      printf 'ERROR: verified local install staging ancestor is unsafe: %s\n' \
        "$staging_ancestor" >&2 || true
      return 70
    }
  done
  if [[ -e $stage_base || -L $stage_base ]]; then
    [[ -d $stage_base && ! -L $stage_base &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$stage_base") == root:root:755 ]] || {
      printf 'ERROR: verified local install staging base is unsafe: %s\n' \
        "$stage_base" >&2 || true
      return 70
    }
  else
    "$sudo_command" /usr/bin/install -d -o root -g root -m 0755 -- "$stage_base" ||
      return 70
  fi
  [[ -d $stage_base && ! -L $stage_base &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$stage_base") == root:root:755 ]] || {
    printf 'ERROR: verified local install staging base is unsafe: %s\n' \
      "$stage_base" >&2 || true
    return 70
  }
  if [[ -e $verified_local_install_stage_parent ||
    -L $verified_local_install_stage_parent ]]; then
    [[ -d $verified_local_install_stage_parent &&
      ! -L $verified_local_install_stage_parent &&
      $(/usr/bin/stat -c '%U:%G:%a' -- "$verified_local_install_stage_parent") == root:root:711 ]] || {
      printf '%s\n' 'ERROR: verified local install staging parent is unsafe.' >&2 || true
      return 70
    }
  else
    "$sudo_command" /usr/bin/install -d -o root -g root -m 0711 -- \
      "$verified_local_install_stage_parent" || return 70
  fi
  [[ -d $verified_local_install_stage_parent &&
    ! -L $verified_local_install_stage_parent &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$verified_local_install_stage_parent") == root:root:711 ]] || {
    printf '%s\n' 'ERROR: verified local install staging parent is unsafe.' >&2 || true
    return 70
  }
  verified_local_install_stage=$(
    "$sudo_command" /usr/bin/mktemp -d \
      --tmpdir="$verified_local_install_stage_parent" run.XXXXXXXX
  )
  [[ ${verified_local_install_stage%/*} == "$verified_local_install_stage_parent" &&
    ${verified_local_install_stage##*/} == run.* ]] || return 70
  "$sudo_command" /usr/bin/chown root:root "$verified_local_install_stage" || return 70
  "$sudo_command" /usr/bin/chmod 0711 "$verified_local_install_stage" || return 70
  [[ -d $verified_local_install_stage && ! -L $verified_local_install_stage &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$verified_local_install_stage") == root:root:711 ]] ||
    return 70
  staged_archive=$verified_local_install_stage/$(basename -- "$archive_path")
  # The unprivileged shell opens the build output; root only consumes stdin.
  # This prevents a symlink swap from making a privileged process disclose a
  # root-only file through the world-readable staging directory.
  /usr/bin/test -f "$archive_path" && /usr/bin/test ! -L "$archive_path" ||
    return 70
  "$sudo_command" /usr/bin/tee "$staged_archive" <"$archive_path" >/dev/null ||
    return 70
  "$sudo_command" /usr/bin/chown root:root "$staged_archive" || return 70
  "$sudo_command" /usr/bin/chmod 0644 "$staged_archive" || return 70
  [[ -f $staged_archive && ! -L $staged_archive &&
    $(/usr/bin/stat -c '%U:%G:%a' -- "$staged_archive") == root:root:644 ]] ||
    return 70

  # Verify after the user-writable build path has been copied. Every root
  # action below consumes only these immutable, root-owned bytes.
  verify_local_package_provenance \
    "$package_name" "$staged_archive" "$verification_root" || return 70
  verified_local_staged_archive=$staged_archive
  hook_dir=$verified_local_install_stage/hooks
  # Scriptlets are disabled below, but libalpm hooks are independent. Suppress
  # every hook owned by the package being replaced, including unknown legacy
  # hooks, and suppress the reviewed incoming Vicinae hooks as well.
  prepare_verified_local_hook_overrides "$package_name" "$hook_dir" || return 70
  if [[ $package_name == vicinae-bin ]]; then
    "$sudo_command" /usr/bin/bsdtar \
      -xf "$staged_archive" \
      -C "$verified_local_install_stage" \
      --strip-components 3 \
      usr/libexec/vicinae/vicinae-qt-guard || return 70
    staged_guard=$verified_local_install_stage/vicinae-qt-guard
    [[ -f $staged_guard && ! -L $staged_guard &&
      $(/usr/bin/stat -c '%U:%G:%a' "$staged_guard") == root:root:755 ]] ||
      return 70
    if ! "$sudo_command" "$staged_guard" hold; then
      printf '%s\n' \
        'ERROR: refusing to replace Vicinae without stopping its active user services.' \
        >&2 || true
      return 1
    fi
  fi
  invalidate_verified_local_install_attestation "$package_name" || return 70
  verified_local_install_attempted=true
  "$sudo_command" /usr/bin/pacman \
    --hookdir "$hook_dir" --noconfirm --noscriptlet -U -- "$staged_archive"
}

enforce_verified_local_installed_safety() {
  local status

  if "$repo_root/scripts/lib/aur-provenance" enforce-installed-safety \
    --package "$1" \
    --version "$2" \
    --sudo-command "$sudo_command"; then
    return 0
  else
    status=$?
  fi
  printf \
    'ERROR: installed safety could not be established for %s %s (status %d).\n' \
    "$1" "$2" "$status" >&2 || true
  return 70
}

vicinae_compatibility_helper_trusted() {
  local installed=$1 reviewed=$2 expected_owner=${3:-root:root}
  local installed_sha256 reviewed_sha256

  [[ -f $installed && ! -L $installed && -x $installed &&
    $(stat -c '%U:%G:%a' -- "$installed") == "$expected_owner:755" &&
    -f $reviewed && ! -L $reviewed ]] || return 1
  installed_sha256=$(sha256sum -- "$installed") || return 1
  reviewed_sha256=$(sha256sum -- "$reviewed") || return 1
  [[ ${installed_sha256%% *} == "${reviewed_sha256%% *}" ]]
}

vicinae_abi_rebuild_required() {
  local compatibility=/usr/libexec/vicinae/vicinae-build-compatible
  local reviewed=$repo_root/packages/local/vicinae-bin/vicinae-build-compatible

  vicinae_compatibility_helper_trusted "$compatibility" "$reviewed" || return 0
  ! timeout --signal=TERM --kill-after=2s 60s "$compatibility"
}

converge_vicinae_runtime_hold() {
  local runtime_mask=/run/systemd/user/vicinae.service

  if ! timeout --signal=TERM --kill-after=2s 60s \
    /usr/libexec/vicinae/vicinae-build-compatible; then
    echo 'ERROR: rebuilt Vicinae does not match the installed Qt runtime.' >&2
    return 1
  fi
  [[ $vicinae_keep_held != true ]] || return 0
  if ! "$sudo_command" /usr/libexec/vicinae/vicinae-qt-guard \
    release-if-compatible; then
    echo 'ERROR: compatible Vicinae could not release its runtime hold.' >&2
    return 1
  fi
  [[ ! -e $runtime_mask && ! -L $runtime_mask ]] || {
    echo 'ERROR: compatible Vicinae retained an unexpected runtime hold.' >&2
    return 1
  }
}

main() {
  if [[ $EUID -eq 0 ]]; then
    echo "Local packages must be built as an unprivileged user." >&2
    return 1
  fi

  mapfile -t local_package_names < <(
    find "$repo_root/packages/local" -mindepth 2 -maxdepth 2 -type f -name PKGBUILD \
      -printf '%h\n' 2>/dev/null |
      xargs -r -n1 basename |
      sort -u
  )

  if ((${#local_package_names[@]} == 0)); then
    echo "No local packages are declared."
    return 0
  fi

  declare -a pending_packages=()
  local package_name package_dir srcinfo pkgver pkgrel epoch desired_version
  local installed_name installed_version installed_query version_comparison
  local force_vicinae_rebuild attestation_status attestation_current
  for package_name in "${local_package_names[@]}"; do
    package_dir="$repo_root/packages/local/$package_name"
    if verified_local_package "$package_name"; then
      # PKGBUILD is executable shell. Establish its reviewed hash before asking
      # makepkg to source it, then compare generated metadata to the manifest.
      verify_local_package_provenance "$package_name"
      desired_version=$(verified_local_desired_version "$package_name")
      srcinfo=$(cd "$package_dir" && makepkg --printsrcinfo)
      pkgver=$(awk '$1 == "pkgver" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
      pkgrel=$(awk '$1 == "pkgrel" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
      epoch=$(awk '$1 == "epoch" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
      [[ -z $epoch || $epoch == 0 ]] || {
        echo "Verified local package must not use an epoch: $package_name" >&2
        return 1
      }
      [[ -n $pkgver && -n $pkgrel && "$pkgver-$pkgrel" == "$desired_version" ]] || {
        echo "Verified local package metadata disagrees with PKGBUILD: $package_name" >&2
        return 1
      }
    else
      srcinfo=$(cd "$package_dir" && makepkg --printsrcinfo)
      pkgver=$(awk '$1 == "pkgver" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
      pkgrel=$(awk '$1 == "pkgrel" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
      epoch=$(awk '$1 == "epoch" && $2 == "=" { print $3; exit }' <<<"$srcinfo")
      [[ -n $pkgver && -n $pkgrel ]] || {
        echo "Could not determine the desired version for $package_name." >&2
        return 1
      }
      desired_version="$pkgver-$pkgrel"
      if [[ -n $epoch && $epoch != 0 ]]; then
        desired_version="$epoch:$desired_version"
      fi
    fi

    installed_name=
    installed_version=
    installed_query=$(pacman -Q "$package_name" 2>/dev/null || true)
    read -r installed_name installed_version <<<"$installed_query"
    if [[ $installed_name != "$package_name" ]]; then
      installed_version=
    fi
    version_comparison=1
    if [[ -n $installed_version ]]; then
      version_comparison=$(vercmp "$installed_version" "$desired_version")
    fi
    force_vicinae_rebuild=false
    attestation_current=false
    if [[ $package_name == vicinae-bin && -n $installed_version ]] &&
      vicinae_abi_rebuild_required; then
      force_vicinae_rebuild=true
    fi
    if ((version_comparison == 0)) && verified_local_package "$package_name"; then
      verify_local_package_provenance "$package_name"
      if verify_verified_local_install_attestation \
        "$package_name" "$desired_version" "$repo_root"; then
        attestation_current=true
      else
        attestation_status=$?
        if ((attestation_status != 2)); then
          printf 'ERROR: refusing an unattested %s fast path (status %d).\n' \
            "$package_name" "$attestation_status" >&2 || true
          return 70
        fi
      fi
    fi
    if ((version_comparison == 0)) &&
      [[ $force_vicinae_rebuild == false ]] &&
      { ! verified_local_package "$package_name" ||
        [[ $attestation_current == true ]]; }; then
      if verified_local_package "$package_name"; then
        enforce_verified_local_installed_safety "$package_name" "$desired_version"
      fi
      if [[ $package_name == vicinae-bin ]]; then
        converge_vicinae_runtime_hold
      fi
      echo "==> Local package is current: $package_name $desired_version"
    else
      if [[ $force_vicinae_rebuild == true && $version_comparison == 0 ]]; then
        echo "==> Local package ABI rebuild required: $package_name $desired_version"
      elif ((version_comparison == 0)) && verified_local_package "$package_name"; then
        echo "==> Verified local package attestation rebuild required: $package_name $desired_version"
      elif [[ -n $installed_version ]]; then
        echo "==> Local package update required: $package_name $installed_version -> $desired_version"
      else
        echo "==> Local package install required: $package_name $desired_version"
      fi
      pending_packages+=("$package_name")
    fi
  done

  if ((${#pending_packages[@]} == 0)); then
    echo "All local packages are already current."
    return 0
  fi

  prepare_local_package_build_parent
  local_package_build_root=$(mktemp -d "$local_package_build_parent/run.XXXXXXXX")
  [[ -d $local_package_build_root && ! -L $local_package_build_root &&
    $(stat -c '%u:%a' -- "$local_package_build_root") == "$EUID:700" ]] || {
    echo "Local package build root is unsafe: $local_package_build_root" >&2
    return 1
  }

  local verification_root
  for package_name in "${pending_packages[@]}"; do
    verification_root=$local_package_build_root/$package_name-source-root
    install -d -m 0700 -- "$verification_root/packages/local"
    cp -a -- "$repo_root/packages/local/$package_name" \
      "$verification_root/packages/local/$package_name"
    printf '\n==> Building declared local package: %s\n' "$package_name"
    if verified_local_package "$package_name"; then
      build_verified_local_package \
        "$package_name" \
        "$verification_root/packages/local/$package_name" \
        "$local_package_build_root/$package_name-workspace" \
        "$verification_root"
    else
      build_local_package \
        "$package_name" \
        "$verification_root/packages/local/$package_name"
    fi
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  trap cleanup_local_package_build EXIT
  main "$@"
fi
