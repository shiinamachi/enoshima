#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly manifest=${AUR_REVIEW_MANIFEST:-$repo_root/packages/aur.txt}
readonly lock_file=${AUR_REVIEW_LOCK:-$repo_root/packages/aur-review.lock}
readonly url_template=${AUR_REVIEW_URL_TEMPLATE:-'https://aur.archlinux.org/{pkgbase}.git'}
readonly update_lock=${AUR_REVIEW_UPDATE_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/enoshima-aur-review-$(id -u).lock}

die() {
  printf 'review-aur: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: review-aur.sh verify [--destination DIRECTORY]
       review-aur.sh update PKGBASE [PKGBASE...]
EOF
  exit 2
}

package_url() {
  local pkgbase=$1
  printf '%s\n' "${url_template//\{pkgbase\}/$pkgbase}"
}

mapfile -t packages < <(
  sed -E \
    -e 's/[[:space:]]+#.*$//' \
    -e '/^[[:space:]]*(#|$)/d' \
    "$manifest"
)
((${#packages[@]} > 0)) || die 'AUR manifest is empty'
command -v git >/dev/null 2>&1 || die 'git is required'
command -v jq >/dev/null 2>&1 || die 'jq is required'
[[ -f $lock_file && ! -L $lock_file ]] || die "review lock is missing: $lock_file"

validate_lock() {
  jq -e '
    .schema == 1 and (.reviewed_at | type == "string") and
    (.packages | type == "array") and
    all(.packages[];
      (.pkgbase | test("^[a-z0-9@._+-]+$")) and
      (.aur_commit | test("^[0-9a-f]{40}$")) and
      (.pkgbuild_sha256 | test("^[0-9a-f]{64}$")) and
      (.srcinfo_sha256 | test("^[0-9a-f]{64}$")) and
      (.reviewed_at | type == "string")
    ) and
    ([.packages[].pkgbase] | length == (unique | length))
  ' "$lock_file" >/dev/null || die 'AUR review lock failed schema validation'

  local manifest_json lock_json
  manifest_json=$(printf '%s\n' "${packages[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
  lock_json=$(jq -c '[.packages[].pkgbase] | sort' "$lock_file")
  [[ $manifest_json == "$lock_json" ]] ||
    die 'AUR manifest and review lock package sets differ'
}

entry_for() {
  local pkgbase=$1
  jq -c -e --arg pkgbase "$pkgbase" \
    '.packages[] | select(.pkgbase == $pkgbase)' "$lock_file" ||
    die "package is not review-locked: $pkgbase"
}

clone_and_verify() {
  local pkgbase=$1 destination=$2 entry expected_commit expected_pkgbuild expected_srcinfo
  local actual_commit actual_pkgbuild actual_srcinfo declared_pkgbase
  entry=$(entry_for "$pkgbase")
  expected_commit=$(jq -r '.aur_commit' <<<"$entry")
  expected_pkgbuild=$(jq -r '.pkgbuild_sha256' <<<"$entry")
  expected_srcinfo=$(jq -r '.srcinfo_sha256' <<<"$entry")

  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 \
    "$(package_url "$pkgbase")" "$destination"
  actual_commit=$(git -C "$destination" rev-parse HEAD)
  [[ $actual_commit == "$expected_commit" ]] ||
    die "AUR package changed since review: $pkgbase ($expected_commit -> $actual_commit)"
  [[ -f $destination/PKGBUILD && -f $destination/.SRCINFO ]] ||
    die "reviewed AUR metadata is incomplete: $pkgbase"
  actual_pkgbuild=$(sha256sum "$destination/PKGBUILD" | awk '{print $1}')
  actual_srcinfo=$(sha256sum "$destination/.SRCINFO" | awk '{print $1}')
  [[ $actual_pkgbuild == "$expected_pkgbuild" ]] ||
    die "PKGBUILD hash differs from the review lock: $pkgbase"
  [[ $actual_srcinfo == "$expected_srcinfo" ]] ||
    die ".SRCINFO hash differs from the review lock: $pkgbase"
  declared_pkgbase=$(awk -F ' = ' '$1 ~ /^[[:space:]]*pkgbase$/ {print $2; exit}' \
    "$destination/.SRCINFO")
  [[ $declared_pkgbase == "$pkgbase" ]] ||
    die ".SRCINFO declares an unexpected package base: $pkgbase"
}

verify_all() {
  local destination=$1 pkgbase
  [[ ! -L $destination ]] || die "destination must not be a symbolic link: $destination"
  install -d -m 0700 "$destination"
  [[ -z $(find "$destination" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
    die "destination is not empty: $destination"
  for pkgbase in "${packages[@]}"; do
    printf '==> Verifying reviewed AUR package: %s\n' "$pkgbase"
    clone_and_verify "$pkgbase" "$destination/$pkgbase"
  done
}

update_packages() {
  (($# > 0)) || usage
  [[ -t 0 && -t 1 ]] || die 'review updates require an interactive terminal'
  exec 9>"$update_lock"
  flock -x 9
  local pkgbase candidate found work old_commit new_commit pkgbuild_sha srcinfo_sha answer temporary
  for pkgbase in "$@"; do
    found=false
    for candidate in "${packages[@]}"; do
      if [[ $candidate == "$pkgbase" ]]; then
        found=true
        break
      fi
    done
    [[ $found == true ]] || die "package is not declared in the AUR manifest: $pkgbase"
    old_commit=$(entry_for "$pkgbase" | jq -r '.aur_commit')
    work=$(mktemp -d)
    GIT_TERMINAL_PROMPT=0 git clone --quiet "$(package_url "$pkgbase")" "$work/repository"
    new_commit=$(git -C "$work/repository" rev-parse HEAD)
    if [[ $new_commit == "$old_commit" ]]; then
      printf '==> %s is unchanged at %s\n' "$pkgbase" "$new_commit"
      rm -rf -- "$work"
      continue
    fi
    git -C "$work/repository" cat-file -e "$old_commit^{commit}" 2>/dev/null ||
      die "the previously reviewed commit is no longer available: $pkgbase"
    printf '==> Review every changed file for %s\n' "$pkgbase"
    git -C "$work/repository" diff --stat "$old_commit" "$new_commit"
    git -C "$work/repository" diff --find-renames "$old_commit" "$new_commit"
    read -r -p "Record $new_commit as reviewed for $pkgbase? Type REVIEW: " answer
    [[ $answer == REVIEW ]] || die "review was not accepted for $pkgbase"
    pkgbuild_sha=$(sha256sum "$work/repository/PKGBUILD" | awk '{print $1}')
    srcinfo_sha=$(sha256sum "$work/repository/.SRCINFO" | awk '{print $1}')
    temporary=$(mktemp "$(dirname -- "$lock_file")/.aur-review.XXXXXX")
    jq \
      --arg pkgbase "$pkgbase" \
      --arg commit "$new_commit" \
      --arg pkgbuild "$pkgbuild_sha" \
      --arg srcinfo "$srcinfo_sha" \
      --arg reviewedAt "$(date -u +%Y-%m-%d)" '
        .reviewed_at = $reviewedAt |
        .packages |= map(
          if .pkgbase == $pkgbase then
            .aur_commit = $commit |
            .pkgbuild_sha256 = $pkgbuild |
            .srcinfo_sha256 = $srcinfo |
            .reviewed_at = $reviewedAt
          else . end
        )
      ' "$lock_file" >"$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$lock_file"
    rm -rf -- "$work"
  done
}

validate_lock
case ${1:-} in
  verify)
    shift
    destination=''
    if [[ ${1:-} == --destination ]]; then
      [[ $# -eq 2 ]] || usage
      destination=$2
    elif (($# != 0)); then
      usage
    fi
    if [[ -n $destination ]]; then
      verify_all "$destination"
    else
      work=$(mktemp -d)
      trap 'rm -rf -- "$work"' EXIT
      verify_all "$work"
    fi
    ;;
  update)
    shift
    update_packages "$@"
    ;;
  *) usage ;;
esac
