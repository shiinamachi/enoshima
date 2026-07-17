# Package manifests

`native.txt`, `management.txt`, `optional-deps.txt`, and `absent.txt` are
consumed by the Ansible package role. `aur.txt` is consumed by
`scripts/install-aur.sh`; listing a package base there approves installation of
its current AUR revision. Reviewed, pinned PKGBUILDs under `local/` are built by
`scripts/install-local-packages.sh`.

Codex Desktop is the one dedicated upstream source build. It is intentionally
absent from `aur.txt`: `scripts/install-codex-desktop.sh` builds the native
`codex-desktop` package from `ilysenko/codex-desktop-linux`, while its host build
inputs remain declared in `management.txt`. The superseded
`chatgpt-desktop-bin` package is declared in `absent.txt` so the two packages
cannot coexist after convergence.

Comments and blank lines are allowed. Keep one package name per line.

Normal convergence asks paru to install the latest revision of every approved
package base without a per-revision review prompt. A failure in one package is
reported as `FAILURE`, and the remaining approved package bases are still
attempted. Move a recipe under `local/` when its exact recipe or upstream
payload must remain repository-pinned.

`absent.txt` is applied before desired packages are installed so conflicting
packages, such as `power-profiles-daemon`, are removed deterministically.

The manifests intentionally contain names rather than versions. Arch is a
rolling release and is restored through a full system upgrade. Exact versions
at capture time are retained in `state/<host>/packages.lock`; reproducing those
versions requires a matching Arch Linux Archive snapshot or package cache.
