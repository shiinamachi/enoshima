#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
checker="$repo_root/scripts/check-vicinae-provenance"
package_dir="$repo_root/packages/local/vicinae-bin"

"$checker"

python - "$package_dir/provenance.json" <<'PY'
import json
from pathlib import Path
import re
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert set(manifest) == {
    "schemaVersion",
    "package",
    "upstream",
    "sourceArchive",
    "glaze",
    "licenseSource",
    "noticeSources",
    "build",
    "packaging",
}
assert manifest["schemaVersion"] == 3
assert manifest["package"]["version"] == "0.25.0-10"
assert manifest["upstream"] == {
    "repository": "vicinaehq/vicinae",
    "tag": "v0.25.0",
    "tagCommit": "7e13b3f5450e9d91b09be2fec2f05c021c8ebb95",
    "sourceDateEpoch": 1786353281,
}
assert manifest["sourceArchive"]["sha256"] == (
    "31480daaeda83a943c8cf2f96ea3d86580c30fbca225b6d31c021b80f5b56ee2"
)
assert manifest["glaze"]["archive"]["sha256"] == (
    "0d108903feb443df316fb53eaec2fd6c1c6d96b368562ad830debc5c6c29c304"
)
assert len(manifest["noticeSources"]) == 21
assert manifest["build"]["npmLocks"] == {
    "src/typescript/api/package-lock.json":
        "8b87b633cbee1497cd61b54c75d07946e5ee56e14e371c78f4a07ec86778a72f",
    "src/typescript/extension-manager/package-lock.json":
        "418d4cf1d74edb0c922f56b08a65387bd0314785d45dbacffe2331b8538d73fe",
    "src/typescript/raycast-api-compat/package-lock.json":
        "8209dcfab24ef08d9f4ae24985915656cdffcbd635d899222d73e2d2f2a79053",
}
assert len(manifest["build"]["cmakeFlags"]) == 25

packaging = manifest["packaging"]
assert len(packaging["localSources"]) == 11
assert len(packaging["staticPolicyFiles"]) == 9
assert "repositoryPolicyFiles" not in packaging
assert len(packaging["sourcePayloadFiles"]) == 49
assert "usr/share/vicinae/themes/icons/kanagawa.png" in packaging[
    "sourcePayloadFiles"
]
assert packaging["runtimeDependencies"][0] == "binutils"
assert "systemd" in packaging["runtimeDependencies"]
assert "systemd-libs" not in packaging["runtimeDependencies"]
for dependency_group in (
    "runtimeDependencies",
    "makeDependencies",
    "checkDependencies",
):
    assert all(
        re.search(r"[<>=]", dependency) is None
        for dependency in packaging[dependency_group]
    )

elf = packaging["elf"]
assert set(elf) == {"interpreter", "identity", "needed"}
assert elf["identity"]["strings"] == ["v0.25.0", "7e13b3f54", "arch_source"]
assert len(elf["needed"]) == 6
assert all(isinstance(contract, list) for contract in elf["needed"].values())
assert elf["needed"]["usr/libexec/vicinae/vicinae-data-control-server"] == [
    "libc.so.6",
    "libgcc_s.so.1",
    "libstdc++.so.6",
    "libwayland-client.so.0",
]
encoded_elf_contract = json.dumps(elf)
assert '"sha256"' not in encoded_elf_contract
assert '"buildId"' not in encoded_elf_contract
assert "asset" not in manifest
assert "archiveTree" not in packaging
assert "packageArchive" in packaging
assert set(packaging["packageArchive"]) == {
    "metadataFiles",
    "buildEnvironmentPath",
}
PY

fixture_root=$(mktemp -d)
trap 'rm -rf -- "$fixture_root"' EXIT

reset_fixture() {
  rm -rf -- "${fixture_root:?}/packages"
  mkdir -p "$fixture_root/packages/local/vicinae-bin"
  cp -a "$package_dir/." "$fixture_root/packages/local/vicinae-bin/"
}

assert_fixture_baseline() {
  "$checker" --root "$fixture_root" >/dev/null || {
    printf 'Vicinae provenance fixture baseline is invalid.\n' >&2
    exit 1
  }
}

refresh_recipe_hash() {
  python - "$fixture_root/packages/local/vicinae-bin" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

package_dir = Path(sys.argv[1])
manifest_path = package_dir / "provenance.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["package"]["recipeSha256"] = hashlib.sha256(
    (package_dir / "PKGBUILD").read_bytes()
).hexdigest()
manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
PY
}

expect_rejected() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'Vicinae provenance accepted %s.\n' "$description" >&2
    exit 1
  fi
}

reset_fixture
assert_fixture_baseline
printf '\n# unexpected mutation\n' \
  >>"$fixture_root/packages/local/vicinae-bin/40-vicinae-qt-pre.hook"
expect_rejected 'a mutated local hook hash' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
printf '\ninstall=vicinae-bin.install\n' \
  >>"$fixture_root/packages/local/vicinae-bin/PKGBUILD"
refresh_recipe_hash
expect_rejected 'a package install script' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

package_dir = Path(sys.argv[1])
desktop = package_dir / "vicinae.desktop"
desktop.write_text(
    desktop.read_text(encoding="utf-8").replace(
        "Exec=vicinae-control toggle", "Exec=vicinae server --replace"
    ),
    encoding="utf-8",
)
digest = hashlib.sha256(desktop.read_bytes()).hexdigest()
manifest_path = package_dir / "provenance.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["packaging"]["localSources"]["vicinae.desktop"] = digest
manifest["packaging"]["staticPolicyFiles"][
    "usr/share/applications/vicinae.desktop"
] = digest
manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
PY
expect_rejected 'an unsafe managed desktop command' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
sed -i 's/-DVICINAE_NODE_RUNTIME_DOWNLOAD=OFF/-DVICINAE_NODE_RUNTIME_DOWNLOAD=ON/' \
  "$fixture_root/packages/local/vicinae-bin/PKGBUILD"
refresh_recipe_hash
expect_rejected 'a changed CMake trust boundary' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
# shellcheck disable=SC2016
sed -i 's|npm_config_cache="$srcdir/npm-cache"|npm_config_cache="$srcdir/npm-seed-cache"|' \
  "$fixture_root/packages/local/vicinae-bin/PKGBUILD"
refresh_recipe_hash
expect_rejected 'different prepare and build npm caches' \
  "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
sed -i 's/ci --ignore-scripts/ci/' \
  "$fixture_root/packages/local/vicinae-bin/PKGBUILD"
refresh_recipe_hash
expect_rejected 'npm lifecycle scripts during the networked prepare phase' \
  "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
# shellcheck disable=SC2016
sed -i '/rm -rf -- "$workspace\/node_modules"/d' \
  "$fixture_root/packages/local/vicinae-bin/PKGBUILD"
refresh_recipe_hash
expect_rejected 'network-prepared node_modules entering the build phase' \
  "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin/PKGBUILD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
text = text.replace(
    "  configure_npm_environment\n  local workspace\n",
    "  configure_npm_environment\n  export npm_config_offline=true\n"
    "  local workspace\n",
    1,
)
text = text.replace(
    "  configure_npm_environment\n  export npm_config_offline=true\n\n"
    "  local -a cmake_flags=(\n",
    "  configure_npm_environment\n\n  local -a cmake_flags=(\n",
    1,
)
path.write_text(text, encoding="utf-8")
PY
refresh_recipe_hash
expect_rejected 'offline npm policy applied to the wrong build phase' \
  "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin/PKGBUILD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
digest = "5611def6c23b88f9958eb7ebb4d26ea1dea1bd1823478c1f7904b70451b88dcb"
path.write_text(text.replace(f"'{digest}'", "'SKIP'", 1), encoding="utf-8")
PY
refresh_recipe_hash
expect_rejected 'a SKIP checksum for a local source' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

package_dir = Path(sys.argv[1])
recipe = package_dir / "PKGBUILD"
recipe.write_text(
    recipe.read_text(encoding="utf-8").replace("  gcc-libs\n", "  gcc-libs>=1\n", 1),
    encoding="utf-8",
)
manifest_path = package_dir / "provenance.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["packaging"]["runtimeDependencies"][1] = "gcc-libs>=1"
manifest["package"]["recipeSha256"] = hashlib.sha256(recipe.read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
PY
expect_rejected 'a versioned rolling-release dependency' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin/provenance.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["build"]["npmLocks"].pop("src/typescript/api/package-lock.json")
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
expect_rejected 'an incomplete npm lock contract' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin/provenance.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["packaging"]["elf"]["sha256"] = "0" * 64
path.write_text(json.dumps(manifest), encoding="utf-8")
PY
expect_rejected 'a pinned build-output hash' "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

package_dir = Path(sys.argv[1])
hook = package_dir / "vicinae.hook"
old_digest = hashlib.sha256(hook.read_bytes()).hexdigest()
hook.write_text(
    hook.read_text(encoding="utf-8").replace("Operation = Install\n", "", 1),
    encoding="utf-8",
)
digest = hashlib.sha256(hook.read_bytes()).hexdigest()
recipe = package_dir / "PKGBUILD"
recipe.write_text(
    recipe.read_text(encoding="utf-8").replace(old_digest, digest, 1),
    encoding="utf-8",
)
manifest_path = package_dir / "provenance.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["packaging"]["localSources"]["vicinae.hook"] = digest
manifest["packaging"]["staticPolicyFiles"][
    "usr/share/libalpm/hooks/vicinae.hook"
] = digest
manifest["package"]["recipeSha256"] = hashlib.sha256(recipe.read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
PY
expect_rejected 'a coherently rehashed unsafe package hook' \
  "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root/packages/local/vicinae-bin" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

package_dir = Path(sys.argv[1])
guard = package_dir / "vicinae-qt-guard"
old_digest = hashlib.sha256(guard.read_bytes()).hexdigest()
guard.write_text(
    guard.read_text(encoding="utf-8").replace("run_root=/run", "run_root=/tmp", 1),
    encoding="utf-8",
)
digest = hashlib.sha256(guard.read_bytes()).hexdigest()
recipe = package_dir / "PKGBUILD"
recipe.write_text(
    recipe.read_text(encoding="utf-8").replace(old_digest, digest, 1),
    encoding="utf-8",
)
manifest_path = package_dir / "provenance.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["packaging"]["localSources"]["vicinae-qt-guard"] = digest
manifest["packaging"]["staticPolicyFiles"][
    "usr/libexec/vicinae/vicinae-qt-guard"
] = digest
manifest["package"]["recipeSha256"] = hashlib.sha256(recipe.read_bytes()).hexdigest()
manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
PY
expect_rejected 'a coherently rehashed guard outside /run' \
  "$checker" --root "$fixture_root"

reset_fixture
assert_fixture_baseline
python - "$fixture_root" <<'PY'
import io
from pathlib import Path
import tarfile
import sys

root = Path(sys.argv[1])

def member(name, *, mode=0o755, kind="file", pax=None):
    info = tarfile.TarInfo(name)
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mode = mode
    info.pax_headers = pax or {}
    if kind == "link":
        info.type = tarfile.SYMTYPE
        info.linkname = "/tmp/unmanaged"
        return info, None
    info.size = 4
    return info, io.BytesIO(b"ELF!")

fixtures = {
    "unsafe.tar": member("../escape"),
    "link.tar": member("usr/bin/vicinae", kind="link"),
    "pax.tar": member("usr/bin/vicinae", pax={"comment": "unreviewed"}),
    "setid.tar": member("usr/bin/vicinae", mode=0o4755),
}
for name, (info, stream) in fixtures.items():
    with tarfile.open(root / name, "w", format=tarfile.PAX_FORMAT) as archive:
        archive.addfile(info, stream)
PY
for mutation in unsafe link pax setid; do
  expect_rejected "a package archive $mutation mutation" \
    "$checker" --root "$fixture_root" \
    --package-archive "$fixture_root/$mutation.tar"
done

echo 'Vicinae provenance tests passed.'
