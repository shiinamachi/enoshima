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
printf 'Transactional UKI tests passed.\n'
