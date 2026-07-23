#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/ansible/roles/system/files/enoshima-rebuild-uki
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/presets" "$work/esp"
printf 'root=/dev/mapper/cryptroot resume=UUID=test resume_offset=42\n' >"$work/cmdline"
printf 'old-uki\n' >"$work/esp/arch-linux.efi"
cat >"$work/presets/linux.preset" <<EOF
ALL_kver="/boot/vmlinuz-linux"
ALL_cmdline="$work/cmdline"
PRESETS=('default')
default_uki="$work/esp/arch-linux.efi"
EOF

cat >"$work/mkinitcpio" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -p ]]
destination=$(sed -n -E 's/^default_uki="([^"]+)"$/\1/p' "$2")
printf 'candidate-uki\n' >"$destination"
EOF

cat >"$work/objcopy" <<EOF
#!/usr/bin/env bash
set -euo pipefail
section=\$2
destination=\${section#*=}
cp "$work/cmdline" "\$destination"
EOF
chmod 0700 "$work/mkinitcpio" "$work/objcopy"

ENOSHIMA_UKI_ALLOW_UNPRIVILEGED=true \
  ENOSHIMA_UKI_PRESET_DIR=$work/presets \
  ENOSHIMA_UKI_MKINITCPIO=$work/mkinitcpio \
  ENOSHIMA_UKI_OBJCOPY=$work/objcopy \
  ENOSHIMA_UKI_CMDLINE_FILE=$work/cmdline \
  ENOSHIMA_UKI_OUTPUT_ROOT=$work/esp \
  ENOSHIMA_UKI_TEMP_DIR=$work \
  bash "$helper"

[[ $(<"$work/esp/arch-linux.efi") == candidate-uki ]]
[[ $(<"$work/esp/arch-linux-previous.efi") == old-uki ]]
[[ ! -e $work/esp/.arch-linux.efi.enoshima-new ]]
# shellcheck disable=SC2016 # Match the literal helper source.
grep -Fq 'sync -f "${destination%/*}"' "$helper"
grep -Fq 'rollback UKI verification failed' "$helper"
grep -Fq 'installed UKI verification failed' "$helper"

cat >"$work/sbsign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($# > 0)); do
  case $1 in
    --key | --cert) shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done
printf 'signed\n' >"$output"
cat "$input" >>"$output"
EOF
cat >"$work/sbverify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --cert && -s $2 ]]
grep -Fq signed "$3"
EOF
chmod 0700 "$work/sbsign" "$work/sbverify"
install -d "$work/keys"
printf 'test key\n' >"$work/keys/db.key"
printf 'test certificate\n' >"$work/keys/db.pem"

ENOSHIMA_UKI_ALLOW_UNPRIVILEGED=true \
  ENOSHIMA_UKI_PRESET_DIR=$work/presets \
  ENOSHIMA_UKI_MKINITCPIO=$work/mkinitcpio \
  ENOSHIMA_UKI_OBJCOPY=$work/objcopy \
  ENOSHIMA_UKI_CMDLINE_FILE=$work/cmdline \
  ENOSHIMA_UKI_OUTPUT_ROOT=$work/esp \
  ENOSHIMA_UKI_TEMP_DIR=$work \
  ENOSHIMA_UKI_SECURE_BOOT_SIGNING=true \
  ENOSHIMA_UKI_SBSIGN=$work/sbsign \
  ENOSHIMA_UKI_SBVERIFY=$work/sbverify \
  ENOSHIMA_UKI_SECURE_BOOT_KEY=$work/keys/db.key \
  ENOSHIMA_UKI_SECURE_BOOT_CERTIFICATE=$work/keys/db.pem \
  bash "$helper"

grep -Fq signed "$work/esp/arch-linux.efi"

# A failed candidate validation must preserve both bootable generations.
printf 'known-good\n' >"$work/esp/arch-linux.efi"
printf 'known-previous\n' >"$work/esp/arch-linux-previous.efi"
cat >"$work/objcopy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
section=$2
destination=${section#*=}
printf 'wrong-command-line\n' >"$destination"
EOF
chmod 0700 "$work/objcopy"
if ENOSHIMA_UKI_ALLOW_UNPRIVILEGED=true \
  ENOSHIMA_UKI_PRESET_DIR=$work/presets \
  ENOSHIMA_UKI_MKINITCPIO=$work/mkinitcpio \
  ENOSHIMA_UKI_OBJCOPY=$work/objcopy \
  ENOSHIMA_UKI_CMDLINE_FILE=$work/cmdline \
  ENOSHIMA_UKI_OUTPUT_ROOT=$work/esp \
  ENOSHIMA_UKI_TEMP_DIR=$work \
  bash "$helper" >/dev/null 2>&1; then
  printf 'Invalid UKI candidate unexpectedly replaced the current image.\n' >&2
  exit 1
fi
[[ $(<"$work/esp/arch-linux.efi") == known-good ]]
[[ $(<"$work/esp/arch-linux-previous.efi") == known-previous ]]

grep -Fq '/usr/local/libexec/enoshima-rebuild-uki' \
  "$repo_root/ansible/roles/system/handlers/main.yml"
system_tasks=$repo_root/ansible/roles/system/tasks/main.yml
helper_directory_line=$(grep -n -m1 'path: /usr/local/libexec' "$system_tasks" | cut -d: -f1)
helper_install_line=$(grep -n -m1 'dest: /usr/local/libexec/enoshima-rebuild-uki' \
  "$system_tasks" | cut -d: -f1)
[[ -n $helper_directory_line && -n $helper_install_line ]]
((helper_directory_line < helper_install_line))
postflight=$repo_root/scripts/postflight.sh
grep -Fq 'check "managed UKIs are present" sudo -n bash -c' "$postflight"
grep -Fq \
  'check_or_warn "managed UKIs carry a Secure Boot signature" sudo -n bash -c' \
  "$postflight"
printf 'Transactional UKI tests passed.\n'
