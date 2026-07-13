# Package manifests

`native.txt`, `management.txt`, `optional-deps.txt`, and `absent.txt` are
consumed by the Ansible package role. `aur.txt` is consumed by
`scripts/install-aur.sh`. Reviewed, pinned PKGBUILDs under `local/` are built
by `scripts/install-local-packages.sh`.

Comments and blank lines are allowed. Keep one package name per line.

`absent.txt` is applied before desired packages are installed so conflicting
packages, such as `power-profiles-daemon`, are removed deterministically.

The manifests intentionally contain names rather than versions. Arch is a
rolling release and is restored through a full system upgrade. Exact versions
at capture time are retained in `state/<host>/packages.lock`; reproducing those
versions requires a matching Arch Linux Archive snapshot or package cache.
