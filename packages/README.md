# Package manifests

`native.txt`, `management.txt`, `optional-deps.txt`, and `absent.txt` are
consumed by the Ansible package role. `aur.txt` is consumed by
`scripts/install-aur.sh`; every entry must have an exact AUR commit and recipe
hashes in `aur-review.lock`. Reviewed, pinned PKGBUILDs under `local/` are
built by `scripts/install-local-packages.sh`.

Comments and blank lines are allowed. Keep one package name per line.

Before accepting an AUR change, run `scripts/review-aur.sh update PKGBASE`,
inspect the full Git diff, and type `REVIEW`. Normal convergence first clones
all locked package bases, verifies their commit, `PKGBUILD`, `.SRCINFO`, and
declared package-base name, then builds those exact local directories. It never
asks paru to fetch a second unreviewed recipe.

`absent.txt` is applied before desired packages are installed so conflicting
packages, such as `power-profiles-daemon`, are removed deterministically.

The manifests intentionally contain names rather than versions. Arch is a
rolling release and is restored through a full system upgrade. Exact versions
at capture time are retained in `state/<host>/packages.lock`; reproducing those
versions requires a matching Arch Linux Archive snapshot or package cache.
