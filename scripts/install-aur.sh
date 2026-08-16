#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest=${AUR_MANIFEST:-$repo_root/packages/aur.txt}
provenance_lock=${AUR_PROVENANCE_LOCK:-$repo_root/packages/aur-provenance.json}
provenance_helper=${AUR_PROVENANCE_HELPER:-$repo_root/scripts/lib/aur-provenance}
paru_url=${AUR_PARU_URL:-https://aur.archlinux.org/paru.git}
mise_config_source=$repo_root/home/dot_config/mise/config.toml
sudo_command=${SUDO_COMMAND_WRAPPER:-sudo}
max_attempts=${AUR_INSTALL_MAX_ATTEMPTS:-4}
retry_delay_seconds=${AUR_INSTALL_RETRY_DELAY_SECONDS:-10}
bootstrap_dir=
paru_converged=1

cleanup() {
  if [[ -n $bootstrap_dir ]]; then
    rm -rf -- "$bootstrap_dir"
  fi
}
trap cleanup EXIT

declare -a failures=()
record_failure() {
  local label=$1 status=$2
  failures+=("$label (exit $status)")
  printf 'FAILURE: %s exited with status %s; continuing.\n' "$label" "$status" >&2
}

if [[ $EUID -eq 0 ]]; then
  echo "AUR packages must be built as an unprivileged user." >&2
  exit 1
fi
[[ -f $manifest && ! -L $manifest ]] || {
  echo "AUR approval manifest is missing or unsafe: $manifest" >&2
  exit 1
}
[[ -x $provenance_helper && ! -L $provenance_helper ]] || {
  echo "AUR provenance helper is missing or unsafe: $provenance_helper" >&2
  exit 1
}
[[ $max_attempts =~ ^[1-9][0-9]*$ ]] || {
  echo "AUR_INSTALL_MAX_ATTEMPTS must be a positive integer." >&2
  exit 1
}
[[ $retry_delay_seconds =~ ^[0-9]+$ ]] || {
  echo "AUR_INSTALL_RETRY_DELAY_SECONDS must be a non-negative integer." >&2
  exit 1
}

mapfile -t aur_packages < <(
  sed -E \
    -e 's/[[:space:]]+#.*$//' \
    -e '/^[[:space:]]*(#|$)/d' \
    "$manifest"
)

declare -A approved=()
for package in "${aur_packages[@]}"; do
  if [[ ! $package =~ ^[a-z0-9@._+-]+$ ]]; then
    echo "Invalid AUR package base in approval manifest: $package" >&2
    exit 1
  fi
  if [[ -v approved["$package"] ]]; then
    echo "Duplicate AUR package base in approval manifest: $package" >&2
    exit 1
  fi
  approved["$package"]=1
done

if ! "$provenance_helper" validate \
  --lock "$provenance_lock" \
  --manifest "$manifest" \
  --require-manifest-membership; then
  echo "Protected AUR provenance validation failed; refusing all AUR convergence." >&2
  exit 1
fi

protected_output=
if ! protected_output=$(
  "$provenance_helper" list --lock "$provenance_lock"
); then
  echo "Protected AUR package classification failed; refusing all AUR convergence." >&2
  exit 1
fi
declare -a protected_packages=()
if [[ -n $protected_output ]]; then
  mapfile -t protected_packages <<<"$protected_output"
fi
declare -A protected=()
for package in "${protected_packages[@]}"; do
  if [[ ! $package =~ ^[a-z0-9@._+-]+$ ]]; then
    echo "Invalid protected AUR package base in provenance lock: $package" >&2
    exit 1
  fi
  if [[ -v protected["$package"] ]]; then
    echo "Duplicate protected AUR package base in provenance lock: $package" >&2
    exit 1
  fi
  protected["$package"]=1
done
declare -a legacy_packages=()
declare -a requested_protected_packages=()
for package in "${aur_packages[@]}"; do
  if [[ -v protected["$package"] ]]; then
    requested_protected_packages+=("$package")
  else
    legacy_packages+=("$package")
  fi
done

if ((${#aur_packages[@]} == 0)); then
  echo "No AUR packages are approved."
  exit 0
fi

echo "==> Converging approved AUR package bases"
printf '  %s\n' "${aur_packages[@]}"

bootstrap_paru() {
  local makepkg_config rust_toolchain status

  if [[ -n $bootstrap_dir ]]; then
    rm -rf -- "$bootstrap_dir"
  fi
  bootstrap_dir=$(mktemp -d)
  if git clone --quiet --depth 1 "$paru_url" "$bootstrap_dir/paru"; then
    :
  else
    status=$?
    printf 'ERROR: bootstrap paru clone exited with status %d.\n' "$status" >&2
    return "$status"
  fi

  makepkg_config=$bootstrap_dir/makepkg.conf
  if cp -- /etc/makepkg.conf "$makepkg_config"; then
    :
  else
    status=$?
    printf \
      'ERROR: bootstrap paru makepkg configuration exited with status %d.\n' \
      "$status" >&2
    return "$status"
  fi
  printf '\nPACMAN_AUTH=(%q)\n' "$sudo_command" >>"$makepkg_config"

  # The bootstrap only needs the pinned version string. Treat the repository's
  # mise configuration as data so an installed, untrusted user config cannot
  # redirect or block the second convergence pass.
  rust_toolchain=$(
    /usr/bin/python - "$mise_config_source" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    value = tomllib.load(handle)["tools"]["rust"]
print(value["version"] if isinstance(value, dict) else value)
PY
  ) || {
    echo 'ERROR: failed to read the managed Rust toolchain for paru.' >&2
    return 1
  }
  if [[ ! $rust_toolchain =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'ERROR: the managed Rust toolchain for paru is not a pinned version.' >&2
    return 1
  fi

  if (
    cd "$bootstrap_dir/paru"
    RUSTUP_TOOLCHAIN="$rust_toolchain" \
      makepkg --config "$makepkg_config" --install --noconfirm --syncdeps
  ); then
    :
  else
    status=$?
    printf 'ERROR: bootstrap paru build exited with status %d.\n' "$status" >&2
    return "$status"
  fi
}

converge_paru() {
  local attempt status=1

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if bootstrap_paru; then
      return 0
    else
      status=$?
    fi
    if ((attempt < max_attempts)); then
      printf \
        'WARNING: bootstrap paru attempt %d/%d failed; retrying in %ss.\n' \
        "$attempt" "$max_attempts" "$retry_delay_seconds" >&2
      sleep "$retry_delay_seconds"
    fi
  done
  record_failure "bootstrap paru" "$status"
  return "$status"
}

if ((${#legacy_packages[@]} > 0)) && {
  [[ -v approved[paru] ]] ||
    ! command -v paru >/dev/null 2>&1 ||
    ! paru --version >/dev/null 2>&1
}; then
  echo "==> Converging paru from its currently approved AUR package base"
  if ! converge_paru; then
    paru_converged=0
  fi
fi

for package in "${requested_protected_packages[@]}"; do
  printf '==> Installing provenance-protected AUR package base: %s\n' "$package"
  if "$provenance_helper" install \
    --lock "$provenance_lock" \
    --package "$package" \
    --sudo-command "$sudo_command"; then
    printf 'SUCCESS: provenance-protected AUR package base converged: %s\n' \
      "$package"
  else
    status=$?
    if ((status == 70)); then
      printf \
        'FAILURE: unsafe installed state for protected AUR package base %s; stopping immediately.\n' \
        "$package" >&2
      exit 1
    fi
    record_failure "protected AUR package base $package" "$status"
  fi
done

if ((${#legacy_packages[@]} > 0)); then
  if ! command -v paru >/dev/null 2>&1 || ! paru --version >/dev/null 2>&1; then
    record_failure "AUR package convergence: paru is unavailable" 127
  else
    for package in "${legacy_packages[@]}"; do
      if [[ $package == paru ]]; then
        if ((paru_converged == 1)); then
          printf 'SUCCESS: approved AUR package base converged: paru\n'
        fi
        continue
      fi
      printf '==> Installing approved AUR package base: %s\n' "$package"
      status=1
      for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if paru \
          --sudo "$sudo_command" \
          --noupgrademenu \
          --nosudoloop \
          --skipreview \
          --pgpfetch \
          --noconfirm \
          --needed \
          -S \
          -- "$package"; then
          status=0
          break
        else
          status=$?
        fi
        if ((attempt < max_attempts)); then
          printf \
            'WARNING: approved AUR package base %s attempt %d/%d failed; retrying in %ss.\n' \
            "$package" "$attempt" "$max_attempts" "$retry_delay_seconds" >&2
          sleep "$retry_delay_seconds"
        fi
      done
      if ((status == 0)); then
        printf 'SUCCESS: approved AUR package base converged: %s\n' "$package"
      else
        record_failure "AUR package base $package" "$status"
      fi
    done
  fi
fi

if ((${#failures[@]} > 0)); then
  printf 'AUR convergence completed with %d FAILURE(S):\n' "${#failures[@]}" >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "Approved AUR package convergence completed successfully."
