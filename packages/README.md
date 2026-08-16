# Package manifests

`native.txt`, `management.txt`, `optional-deps.txt`, `accessibility.txt`, and
`absent.txt` are consumed by the Ansible package role. `accessibility.txt` is
included only when the inventory host explicitly sets
`desktop_accessibility_profile_enabled: true`; its default is false. `aur.txt` is consumed by
`scripts/install-aur.sh`. Entries approve installation of the current AUR
revision through paru. `aur-provenance.json` retains the schema for future
packages that need a reviewed AUR revision; its protected list is currently
empty. Reviewed, pinned PKGBUILDs under `local/` are built by
`scripts/install-local-packages.sh`.

Codex Desktop and Vicinae use dedicated, repository-reviewed upstream source
builds. Codex Desktop is intentionally absent from `aur.txt`:
`scripts/install-codex-desktop.sh` builds the native
`codex-desktop` package from `ilysenko/codex-desktop-linux`, while its host build
inputs remain declared in `management.txt`. The superseded
`chatgpt-desktop-bin` package is declared in `absent.txt` so the two packages
cannot coexist after convergence.

Comments and blank lines are allowed. Keep one package name per line.

Normal convergence asks paru to install the latest revision of each legacy AUR
package base without a per-revision review prompt. A failure in one package is
reported as `FAILURE`, and the remaining approved package bases are still
attempted with the existing bounded retry policy.

`scripts/validate.sh` performs offline schema, lock, and reviewed-fixture
checks. The protected-AUR framework remains fail-closed and is exercised with
an isolated historical fixture; production convergence currently classifies
every approved AUR entry as a normal current-revision package.

`local/vicinae-bin` is such a pinned source recipe. The package name is retained
as a migration-compatible legacy name, but v0.25.0-10 builds commit
`7e13b3f54` from its pinned source archive. The previously selected AppImage was
rejected because its bundled Qt lacks the GLib event dispatcher: QtKeychain's
asynchronous libsecret callback never completes and encrypted startup hangs.
The official native archive was also rejected because its QML AOT objects bind
to the exact build-time Qt private ABI. The repository build disables
`qmlcachegen`, records `arch_source` provenance, and pins the source, Glaze, npm
lockfiles, notices, compiler inputs, and CMake options.
The Enoshima patch also preserves every MIME offer and its exact bytes when a
clipboard-history record is selected. Its package check executes rich
`image/png` + `text/html` + `text/plain`, URI-list, charset, and X11 fallback
round trips so an upstream refactor cannot silently collapse a compound item
to plain text.

The final package archive is inspected before installation and none of its
executables run during provenance review. The reviewed CLI, five
helpers, themes, managed desktop entries, packaged user service, pinned GPL
license, reviewed bundled third-party notices, and runtime-hold hooks are
installed as regular files under `/usr`.
The managed application and URI entries route through `vicinae-control`, so
they cannot bypass the keyring gate. The upstream install script and
modules-load file that enable global input injection are excluded. The service
pins `VICINAE_NODE_BIN=/usr/bin/node` and removes inherited loader, Qt plugin,
QML path, and `QT_NO_GLIB` overrides, so only the reviewed system Qt dispatcher
can deliver libsecret callbacks. A locked login keyring cleanly skips startup
through `ExecCondition`; it does not consume the service restart limit.
`scripts/check-vicinae-provenance` verifies the structured recipe metadata,
exact upstream and final package trees, every ELF build ID/dependency,
Node and Qt environment policy, notices, and bounded transition hooks before `pacman -U` is
allowed. CI also verifies that v0.25.0 is a stable GitHub release, matches its
tag commit and pinned source inputs, and inspects the package ABI and privilege
surface for unexpected units, links, install scripts, set-ID bits, or
capability metadata.

The packaged `vicinae-server` embeds modified Raycast-derived icon assets whose
source and binary redistribution grant is not recorded upstream. The recipe
does not mislabel those assets as MIT and is limited to a local source build;
do not redistribute its package archive or claim complete third-party
provenance until an upstream permission or freely licensed replacement is
reviewed and pinned.

`local/hyprshell-bin` now builds the exact v4.10.8 tag commit with a reviewed
direct-input patch. The patch also lets a topology-owning verification harness
start Hyprshell without its eager full-compositor reload when the existing
no-listeners mode is explicitly enabled. The build runs inside the same
restricted bubblewrap path as Vicinae and exposes only the mise-selected Rust
toolchain read-only. A single
job, bounded code-generation profiles, disabled LTO/debug splitting, and the
slim feature keep the previous 6.6--6.9 GiB `rustc` OOM failure below the VM
budget. `scripts/check-hyprshell-provenance` pins the stable release/tag/commit,
source archive, Cargo lock, patch, static payload, package metadata, MTREE and
ELF policy. Recipe or payload changes must increment `pkgrel`; same-version
installed files cannot otherwise prove which reviewed archive produced them.

Vicinae still uses `Qt6::GuiPrivate` for Wayland integration. Pacman hooks
publish systemd's native global runtime mask, require every existing user
manager to observe `LoadState=masked`, and stop active
instances before any Qt shared-library transaction. Bootstrap rebuilds against
the current full Arch system, verifies every recorded Qt SONAME
target/hash/build ID, validates the current user's managed policy, then
declaratively enables the service. ABI mismatch leaves the runtime mask in
place; policy deployment uses systemd's persistent user mask so interruption
or reboot remains fail-closed without a custom durable state machine.

`absent.txt` is applied before desired packages are installed so conflicting
packages, such as `power-profiles-daemon`, are removed deterministically.

The manifests intentionally contain names rather than versions. Arch is a
rolling release and is restored through a full system upgrade. Exact versions
at capture time are retained in `state/<host>/packages.lock`; reproducing those
versions requires a matching Arch Linux Archive snapshot or package cache.
