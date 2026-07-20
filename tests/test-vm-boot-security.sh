#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder=$repo_root/tests/vm/scripts/prepare-boot-security.sh
domain_template=$repo_root/tests/vm/templates/domain-secure-boot.xml.j2
suite=$repo_root/tests/vm/suites/boot-security.yaml

fail() {
  printf 'VM boot-security test failed: %s\n' "$*" >&2
  exit 1
}

bash -n "$builder"
# Match literal safeguards in the builder source.
# shellcheck disable=SC2016
grep -Fq '[[ $disk == /dev/vdb ]]' "$builder" ||
  fail 'disk builder does not pin its destructive target to /dev/vdb'
# shellcheck disable=SC2016
grep -Fq 'wipefs --all --force "$disk"' "$builder" ||
  fail 'disk preparation is not explicit'
grep -Fq 'cryptsetup luksFormat --type luks2' "$builder" ||
  fail 'boot target is not formatted as LUKS2'
grep -Fq 'for subvolume in @ @home @var_log @swap' "$builder" ||
  fail 'boot target omits the managed Btrfs layout'
grep -Fq 'sbctl enroll-keys -m' "$builder" ||
  fail 'VM-only Secure Boot key enrollment is missing'
# shellcheck disable=SC2016
grep -Fq '"$target/etc/pacman.d/mirrorlist"' "$builder" ||
  fail 'boot target does not retain the reproducible repository snapshot'
grep -Fq 'arch-linux-unsigned.efi' "$builder" ||
  fail 'negative unsigned-UKI fixture is missing'

grep -Fq '<feature enabled="yes" name="secure-boot"/>' "$domain_template" ||
  fail 'secure firmware is not requested'
grep -Fq '<feature enabled="no" name="enrolled-keys"/>' "$domain_template" ||
  fail 'OVMF setup mode is not requested for disposable keys'
grep -Fq '<backend type="emulator" version="2.0" persistent_state="yes"/>' \
  "$domain_template" || fail 'persistent per-domain swtpm is not configured'

grep -Fq 'test_unsigned_rejection' "$repo_root/tests/vm/src/enoshima_vm/service.py" ||
  fail 'suite service omits the negative Secure Boot test'
grep -Fq 'test_recovery_path' "$repo_root/tests/vm/src/enoshima_vm/service.py" ||
  fail 'suite service omits the LUKS recovery path'
grep -Fq 'apply_boot_artifacts: true' "$suite" ||
  fail 'kernel-update UKI regeneration is not exercised'
grep -Fq 'ENOSHIMA_UKI_SECURE_BOOT_SIGNING' \
  "$repo_root/ansible/roles/system/handlers/main.yml" ||
  fail 'Ansible does not pass the explicit UKI signing policy'

printf 'VM boot-security contract tests passed.\n'
