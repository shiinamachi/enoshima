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
package_block=$(sed -n '/^boot_target_packages=(/,/^)/p' "$builder")
# Match literal safeguards in the builder source.
# shellcheck disable=SC2016
grep -Fq '[[ $disk == /dev/vdb ]]' "$builder" ||
  fail 'disk builder does not pin its destructive target to /dev/vdb'
# shellcheck disable=SC2016
grep -Fq 'wipefs --all --force "$disk"' "$builder" ||
  fail 'disk preparation is not explicit'
grep -Eq '^  parted \\$' "$builder" ||
  fail 'disk builder does not install the package that provides partprobe'
grep -Eq '^  chezmoi$' <<<"$package_block" ||
  fail 'boot target lacks the dotfile client required by bootstrap'
grep -Fq 'BOOT_SECURITY_PACKAGE_DOWNLOAD_MAX_ATTEMPTS:-4' "$builder" ||
  fail 'boot target package download has no bounded retry budget'
grep -Fq 'BOOT_SECURITY_PACKAGE_DOWNLOAD_RETRY_DELAY_SECONDS:-10' "$builder" ||
  fail 'boot target package download has no bounded retry delay'
grep -Fq 'boot-security package download exhausted' "$builder" ||
  fail 'boot target package download does not report exhausted retries'
# shellcheck disable=SC2016
grep -Fq 'pacstrap -c -K "$target" --downloadonly "${boot_target_packages[@]}"' \
  "$builder" || fail 'boot target dependency closure has no download-only retry phase'
# shellcheck disable=SC2016
grep -Fq 'pacstrap -c -K "$target" "${boot_target_packages[@]}"' "$builder" ||
  fail 'boot target installation does not reuse the verified host cache'
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
grep -Fq 'DNS=1.1.1.1 9.9.9.9' "$builder" ||
  fail 'boot target does not retain the isolated public resolver policy'
grep -Fq 'FallbackDNS=' "$builder" ||
  fail 'boot target resolver policy permits an inherited fallback'
grep -Fq 'Domains=~.' "$builder" ||
  fail 'boot target resolver policy does not own the default route'
# shellcheck disable=SC2016
grep -Fq 'ln -sfn ../run/systemd/resolve/stub-resolv.conf "$target/etc/resolv.conf"' \
  "$builder" || fail 'boot target does not use the systemd-resolved stub'
grep -Eq '^  systemd-resolved\.service \\$' "$builder" ||
  fail 'boot target does not enable systemd-resolved before bootstrap'
grep -Fq 'ip daddr 10.0.2.3 udp dport 53 accept' "$builder" ||
  fail 'boot target firewall does not permit slirp UDP DNS'
grep -Fq 'ip daddr 10.0.2.3 tcp dport 53 accept' "$builder" ||
  fail 'boot target firewall does not permit slirp TCP DNS'
grep -Fq 'arch-linux-unsigned.efi' "$builder" ||
  fail 'negative unsigned-UKI fixture is missing'

package_download_retry_impl=$(
  sed -n '/^download_boot_target_packages_with_bounded_retries()/,/^}/p' "$builder"
)
retry_work=$(mktemp -d)
trap 'rm -rf -- "$retry_work"' EXIT
(
  eval "$package_download_retry_impl"
  # shellcheck disable=SC2034 # Consumed by the production helpers loaded via eval.
  target=$retry_work/target boot_target_packages=(fixture) package_download_max_attempts=3 package_download_retry_delay_seconds=0
  export BOOT_SECURITY_PACKAGE_DOWNLOAD_ATTEMPT_FILE=$retry_work/attempts
  # shellcheck disable=SC2329 # Invoked by the production helper loaded via eval.
  clear_stale_pacman_lock() { :; }
  # shellcheck disable=SC2329 # Invoked by the production helper loaded via eval.
  pacstrap() {
    local count=0
    [[ ! -f $BOOT_SECURITY_PACKAGE_DOWNLOAD_ATTEMPT_FILE ]] ||
      read -r count <"$BOOT_SECURITY_PACKAGE_DOWNLOAD_ATTEMPT_FILE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$BOOT_SECURITY_PACKAGE_DOWNLOAD_ATTEMPT_FILE"
    ((count >= 3))
  }
  download_boot_target_packages_with_bounded_retries >/dev/null 2>&1
) || fail 'boot target package download did not recover within its retry budget'
[[ $(<"$retry_work/attempts") == 3 ]] ||
  fail 'boot target package download did not exercise the expected retries'

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
