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
pacstrap_block=$(sed -n '/^pacstrap -K /,/^$/p' "$builder")
# Match literal safeguards in the builder source.
# shellcheck disable=SC2016
grep -Fq '[[ $disk == /dev/vdb ]]' "$builder" ||
  fail 'disk builder does not pin its destructive target to /dev/vdb'
# shellcheck disable=SC2016
grep -Fq 'wipefs --all --force "$disk"' "$builder" ||
  fail 'disk preparation is not explicit'
grep -Eq '^  parted \\$' "$builder" ||
  fail 'disk builder does not install the package that provides partprobe'
grep -Eq '^  chezmoi \\$' <<<"$pacstrap_block" ||
  fail 'boot target lacks the dotfile client required by bootstrap'
grep -Fq 'recovery key must contain exactly 64 bytes without a newline' "$builder" ||
  fail 'interactive recovery key format is not enforced'
grep -Fq 'console=tty0 console=ttyS0,115200n8' "$builder" ||
  fail 'recovery input is not isolated from the graphical firmware console'
grep -Fq 'cryptsetup luksFormat --type luks2' "$builder" ||
  fail 'boot target is not formatted as LUKS2'
grep -Fq 'mkfs.fat -F 32 -n ENOSHIMAESP' "$builder" ||
  fail 'EFI filesystem label exceeds the FAT 11-character limit'
grep -Fq 'for subvolume in @ @home @var_log @swap' "$builder" ||
  fail 'boot target omits the managed Btrfs layout'
# shellcheck disable=SC2016
grep -Fq 'gpgconf --homedir "$target/etc/pacman.d/gnupg" --kill all' "$builder" ||
  fail 'boot target cleanup does not stop the pacstrap keyring agent'
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
grep -Fq '<log file="{{ run_dir }}/serial.log" append="off"/>' \
  "$domain_template" || fail 'serial recovery prompt output is not retained'

grep -Fq 'test_unsigned_rejection' "$repo_root/tests/vm/src/enoshima_vm/service.py" ||
  fail 'suite service omits the negative Secure Boot test'
grep -Fq 'set-oneshot' "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'unsigned UKI test must preserve the persistent signed default'
grep -Fq 'service.backend.reset' "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'unsigned UKI test cannot recover from the firmware boot manager'
grep -Fq 'test_recovery_path' "$repo_root/tests/vm/src/enoshima_vm/service.py" ||
  fail 'suite service omits the LUKS recovery path'
grep -Fq 'type_serial_text' "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'LUKS recovery still injects text through the firmware keyboard path'
grep -Fq 'read_serial_text' "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'LUKS recovery input is not gated on the serial passphrase prompt'
grep -Fq 'prompt_count > submitted_prompt_count' \
  "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'LUKS recovery input repeats without a new passphrase prompt'
grep -Fq 'serial_size <= prompt_input_serial_size' \
  "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'lost serial input is not retried from observable console state'
grep -Fq 'managed_fstab_static_entries' \
  "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'runtime inventory does not preserve dedicated Btrfs mounts'
grep -Fq 'assert-recovery-mounts' \
  "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'recovery validation does not prove dedicated mounts survived reboot'
grep -Fq 'sbverify --cert /var/lib/sbctl/keys/db/db.pem' \
  "$repo_root/tests/vm/src/enoshima_vm/boot_security.py" ||
  fail 'runtime assertions do not verify UKIs against the enrolled db certificate'
grep -Fq 'apply_boot_artifacts: true' "$suite" ||
  fail 'kernel-update UKI regeneration is not exercised'
validate_line=$(grep -n -- '  - run_validate' "$suite" | cut -d: -f1)
prepare_line=$(grep -n -- '  - prepare_boot_disk' "$suite" | cut -d: -f1)
[[ -n $validate_line && -n $prepare_line && $validate_line -lt $prepare_line ]] ||
  fail 'source validation must run on the prepared base guest before disk creation'
grep -Fq 'ENOSHIMA_UKI_SECURE_BOOT_SIGNING' \
  "$repo_root/ansible/roles/system/handlers/main.yml" ||
  fail 'Ansible does not pass the explicit UKI signing policy'

printf 'VM boot-security contract tests passed.\n'
