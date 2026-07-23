#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest=${AUR_MANIFEST:-$repo_root/packages/aur.txt}
paru_url=${AUR_PARU_URL:-https://aur.archlinux.org/paru.git}
sudo_command=${SUDO_COMMAND_WRAPPER:-sudo}
max_attempts=${AUR_INSTALL_MAX_ATTEMPTS:-4}
retry_delay_seconds=${AUR_INSTALL_RETRY_DELAY_SECONDS:-10}
bootstrap_dir=

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

if ((${#aur_packages[@]} == 0)); then
  echo "No AUR packages are approved."
  exit 0
fi

echo "==> Converging approved AUR package bases at their current revisions"
printf '  %s\n' "${aur_packages[@]}"

bootstrap_paru() {
  local makepkg_config status

  bootstrap_dir=$(mktemp -d)
  if git clone --quiet --depth 1 "$paru_url" "$bootstrap_dir/paru"; then
    :
  else
    status=$?
    record_failure "bootstrap paru clone" "$status"
    return 1
  fi

  makepkg_config=$bootstrap_dir/makepkg.conf
  if cp -- /etc/makepkg.conf "$makepkg_config"; then
    :
  else
    status=$?
    record_failure "bootstrap paru makepkg configuration" "$status"
    return 1
  fi
  printf '\nPACMAN_AUTH=(%q)\n' "$sudo_command" >>"$makepkg_config"

  if (
    cd "$bootstrap_dir/paru"
    makepkg --config "$makepkg_config" --install --noconfirm --syncdeps
  ); then
    :
  else
    status=$?
    record_failure "bootstrap paru build" "$status"
    return 1
  fi
}

if ! command -v paru >/dev/null 2>&1 || ! paru --version >/dev/null 2>&1; then
  echo "==> Bootstrapping paru from its currently approved AUR package base"
  bootstrap_paru || true
fi

if ! command -v paru >/dev/null 2>&1 || ! paru --version >/dev/null 2>&1; then
  record_failure "AUR package convergence: paru is unavailable" 127
else
  for package in "${aur_packages[@]}"; do
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

if ((${#failures[@]} > 0)); then
  printf 'AUR convergence completed with %d FAILURE(S):\n' "${#failures[@]}" >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "Approved AUR package convergence completed successfully."
