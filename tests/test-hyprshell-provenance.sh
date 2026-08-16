#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
checker=$repo_root/scripts/check-hyprshell-provenance
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'Hyprshell provenance test failed: %s\n' "$*" >&2
  exit 1
}

expect_rejected() {
  local label=$1 expected=$2
  shift 2
  if "$@" >"$work/rejected.out" 2>&1; then
    fail "$label was accepted"
  fi
  grep -Eqi -- "$expected" "$work/rejected.out" || {
    sed -n '1,120p' "$work/rejected.out" >&2
    fail "$label did not report the expected rejection"
  }
}

"$checker" --root "$repo_root" >/dev/null

mutation_root=$work/mutation
mkdir -p "$mutation_root/packages/local"
cp -a -- "$repo_root/packages/local/hyprshell-bin" \
  "$mutation_root/packages/local/hyprshell-bin"
printf '\n# unreviewed mutation\n' \
  >>"$mutation_root/packages/local/hyprshell-bin/PKGBUILD"
expect_rejected 'a changed recipe' 'PKGBUILD differs' \
  "$checker" --root "$mutation_root"

cp -a -- "$repo_root/packages/local/hyprshell-bin" \
  "$work/patch-mutation"
printf '\ndiff --git a/README.md b/README.md\n' \
  >>"$work/patch-mutation/overview-direct-input.patch"
mkdir -p "$work/patch-root/packages/local"
mv -- "$work/patch-mutation" "$work/patch-root/packages/local/hyprshell-bin"
expect_rejected 'a changed overview patch' 'overview patch differs' \
  "$checker" --root "$work/patch-root"

python - "$checker" <<'PY'
from __future__ import annotations

import gzip
from pathlib import Path
import runpy
import sys

module = runpy.run_path(sys.argv[1], run_name="hyprshell_provenance_test")
verify_mtree = module["verify_mtree"]


def mtree(
    mode: str = "644",
    size: int = 7,
    digest: str | None = None,
    path: str = "value",
) -> bytes:
    payload = b"payload"
    digest = digest or module["sha256_bytes"](payload)
    text = (
        "#mtree\n"
        "/set type=file uid=0 gid=0 mode=644\n"
        "./usr type=dir mode=755\n"
        "./usr/share type=dir mode=755\n"
        f"./usr/share/{path} mode={mode} size={size} sha256digest={digest}\n"
    )
    return gzip.compress(text.encode())


files = {"usr/share/value": b"payload"}
directories = {"usr", "usr/share"}
verify_mtree(mtree(), files, directories)
for label, data in (
    ("mode", mtree(mode="755")),
    ("size", mtree(size=8)),
    ("digest", mtree(digest="0" * 64)),
    ("path", mtree(path="other")),
):
    try:
        verify_mtree(data, files, directories)
    except SystemExit:
        pass
    else:
        raise AssertionError(f".MTREE {label} mutation was accepted")
PY

grep -Fq -- '--unshare-net' "$repo_root/scripts/install-local-packages.sh" ||
  fail 'the compile/check/package phase does not disable networking'
grep -Fq -- '--nobuild' "$repo_root/scripts/install-local-packages.sh" ||
  fail 'the bounded source-fetch phase is missing'
grep -Fq -- '--noextract' "$repo_root/scripts/install-local-packages.sh" ||
  fail 'the offline build does not reuse the verified prepared tree'
grep -Fq -- '--noprepare' "$repo_root/scripts/install-local-packages.sh" ||
  fail 'the offline build reruns the networked source preparation step'
grep -Fq 'CARGO_PROFILE_TEST_CODEGEN_UNITS=64' \
  "$repo_root/packages/local/hyprshell-bin/PKGBUILD" ||
  fail 'the Hyprshell regression test compile is not memory-bounded'

printf 'Hyprshell provenance tests passed.\n'
