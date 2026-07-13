# Package manifests

`native.txt`, `management.txt`, and `optional-deps.txt` are consumed by the
Ansible package role. `aur.txt` is consumed by `scripts/install-aur.sh`.

Comments and blank lines are allowed. Keep one package name per line.

The manifests intentionally contain names rather than versions. Arch is a
rolling release and is restored through a full system upgrade. Exact versions
at capture time are retained in `state/<host>/packages.lock`; reproducing those
versions requires a matching Arch Linux Archive snapshot or package cache.
