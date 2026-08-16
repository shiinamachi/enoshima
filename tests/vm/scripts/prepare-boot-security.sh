#!/usr/bin/env bash
set -euo pipefail

disk=${1:-/dev/vdb}
recovery_key=${2:-}
authorized_key=${3:-}
target=/mnt/enoshima-vm-target
mapper=enoshima-vm-cryptroot
package_download_max_attempts=${BOOT_SECURITY_PACKAGE_DOWNLOAD_MAX_ATTEMPTS:-4}
package_download_retry_delay_seconds=${BOOT_SECURITY_PACKAGE_DOWNLOAD_RETRY_DELAY_SECONDS:-10}
boot_target_packages=(
  ansible-core
  base
  btrfs-progs
  chezmoi
  cryptsetup
  git
  jq
  linux
  linux-firmware
  linux-lts
  networkmanager
  nftables
  openssh
  qemu-guest-agent
  sbctl
  sbsigntools
  sudo
  tpm2-tools
  zsh
)

die() {
  printf 'prepare-boot-security: %s\n' "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die 'root privileges are required'
[[ $disk == /dev/vdb ]] || die 'only the disposable /dev/vdb disk is allowed'
[[ -b $disk ]] || die "$disk is not a block device"
[[ -r $recovery_key && ! -L $recovery_key ]] || die 'recovery key is unavailable'
[[ -r $authorized_key && ! -L $authorized_key ]] || die 'SSH public key is unavailable'
[[ $(stat -c '%a' "$recovery_key") == 600 ]] || die 'recovery key must have mode 0600'
[[ $(stat -c '%s' "$recovery_key") == 64 ]] ||
  die 'recovery key must contain exactly 64 bytes without a newline'
LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$recovery_key" ||
  die 'recovery key must be lowercase hexadecimal'
[[ $package_download_max_attempts =~ ^[1-9][0-9]*$ ]] ||
  die 'BOOT_SECURITY_PACKAGE_DOWNLOAD_MAX_ATTEMPTS must be a positive integer'
[[ $package_download_retry_delay_seconds =~ ^[0-9]+$ ]] ||
  die 'BOOT_SECURITY_PACKAGE_DOWNLOAD_RETRY_DELAY_SECONDS must be zero or a positive integer'

cleanup() {
  set +e
  umount -R "$target" 2>/dev/null
  cryptsetup close "$mapper" 2>/dev/null
}
trap cleanup EXIT

clear_stale_pacman_lock() {
  local pacman_running=false process_state

  while IFS= read -r process_state; do
    if [[ ${process_state:0:1} != Z ]]; then
      pacman_running=true
      break
    fi
  done < <(ps -C pacman -o stat=)
  if [[ -e $target/var/lib/pacman/db.lck && $pacman_running == false ]]; then
    rm -f "$target/var/lib/pacman/db.lck"
    printf 'Removed stale pacman database lock after failed boot-target download.\n' >&2
  fi
}

download_boot_target_packages_with_bounded_retries() {
  local attempt status

  for ((attempt = 1; attempt <= package_download_max_attempts; attempt++)); do
    if pacstrap -c -K "$target" --downloadonly "${boot_target_packages[@]}"; then
      return 0
    else
      status=$?
    fi

    clear_stale_pacman_lock
    if ((attempt == package_download_max_attempts)); then
      printf \
        'ERROR: boot-security package download exhausted %d attempts (last status: %d).\n' \
        "$package_download_max_attempts" "$status" >&2
      return "$status"
    fi

    printf \
      'WARNING: boot-security package download attempt %d/%d failed with status %d; retrying the same pinned package set in %ss.\n' \
      "$attempt" "$package_download_max_attempts" "$status" \
      "$package_download_retry_delay_seconds" >&2
    sleep "$package_download_retry_delay_seconds"
  done
}

pacman -Syu --needed --noconfirm \
  arch-install-scripts \
  binutils \
  btrfs-progs \
  cryptsetup \
  dosfstools \
  gptfdisk \
  parted \
  sbsigntools

if findmnt --source "${disk}1" >/dev/null 2>&1 ||
  findmnt --source "${disk}2" >/dev/null 2>&1; then
  die 'the disposable target disk is already mounted'
fi

wipefs --all --force "$disk"
sgdisk --zap-all "$disk"
sgdisk --new=1:1MiB:+1GiB --typecode=1:ef00 --change-name=1:EFI "$disk"
sgdisk --new=2:0:0 --typecode=2:8309 --change-name=2:cryptroot "$disk"
partprobe "$disk"
udevadm settle

cryptsetup luksFormat --type luks2 --batch-mode --key-file "$recovery_key" "${disk}2"
cryptsetup open --key-file "$recovery_key" "${disk}2" "$mapper"
mkfs.fat -F 32 -n ENOSHIMAESP "${disk}1"
mkfs.btrfs -f -L ENOSHIMA_VM "/dev/mapper/$mapper"

install -d -m 0700 "$target"
mount "/dev/mapper/$mapper" "$target"
for subvolume in @ @home @var_log @swap; do
  btrfs subvolume create "$target/$subvolume"
done
umount "$target"

mount -o subvol=@,compress=zstd,noatime "/dev/mapper/$mapper" "$target"
install -d "$target/home" "$target/var/log" "$target/swap" "$target/efi"
mount -o subvol=@home,compress=zstd,noatime "/dev/mapper/$mapper" "$target/home"
mount -o subvol=@var_log,compress=zstd,noatime "/dev/mapper/$mapper" "$target/var/log"
mount -o subvol=@swap,noatime "/dev/mapper/$mapper" "$target/swap"
mount "${disk}1" "$target/efi"

# The runner has already installed a checksum-verified snapshot cache into the
# guest host. Resolve the clean target's complete dependency closure and finish
# any missing downloads with bounded retries, then perform the package
# transaction exactly once so a failed hook or install is never replayed.
download_boot_target_packages_with_bounded_retries
pacstrap -c -K "$target" "${boot_target_packages[@]}"

# pacstrap can leave the target pacman keyring's gpg-agent alive with files
# open below the chroot. Stop that scoped agent before the final recursive
# unmount so the disposable boot disk is always cleanly detached.
gpgconf --homedir "$target/etc/pacman.d/gnupg" --kill all || true

# Preserve the suite's whole-repository Arch Linux Archive snapshot in the
# installed target. This prevents its later bootstrap from becoming a partial
# or moving-release package transaction.
install -m 0644 /etc/pacman.d/mirrorlist "$target/etc/pacman.d/mirrorlist"

# The prepared target replaces the NoCloud image, so it must carry the same
# resolver isolation policy itself. NetworkManager selects systemd-resolved
# when resolv.conf points at its stub; enable that service before the target's
# first bootstrap so the pinned Archive mirror remains resolvable after reboot.
install -d -m 0755 "$target/etc/systemd/resolved.conf.d"
cat >"$target/etc/systemd/resolved.conf.d/20-enoshima-vm.conf" <<'EOF'
[Resolve]
DNS=1.1.1.1 9.9.9.9
FallbackDNS=
Domains=~.
EOF
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$target/etc/resolv.conf"

root_luks_uuid=$(cryptsetup luksUUID "${disk}2")
root_btrfs_uuid=$(btrfs filesystem show "/dev/mapper/$mapper" | sed -n 's/.*uuid: //p' | head -n1)
esp_uuid=$(blkid -s UUID -o value "${disk}1")
esp_partuuid=$(blkid -s PARTUUID -o value "${disk}1")
[[ -n $root_luks_uuid && -n $root_btrfs_uuid && -n $esp_uuid && -n $esp_partuuid ]] ||
  die 'generated storage identifiers are incomplete'

cat >"$target/etc/fstab" <<EOF
UUID=$root_btrfs_uuid / btrfs rw,noatime,compress=zstd,subvol=@ 0 0
UUID=$root_btrfs_uuid /home btrfs rw,noatime,compress=zstd,subvol=@home 0 0
UUID=$root_btrfs_uuid /var/log btrfs rw,noatime,compress=zstd,subvol=@var_log 0 0
UUID=$root_btrfs_uuid /swap btrfs rw,noatime,subvol=@swap 0 0
UUID=$esp_uuid /efi vfat rw,umask=0077 0 2
EOF
cat >"$target/etc/crypttab.initramfs" <<EOF
cryptroot UUID=$root_luks_uuid none tpm2-device=auto,x-initrd.attach,discard
EOF
printf '%s\n' \
  'root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw console=tty0 console=ttyS0,115200n8' \
  >"$target/etc/kernel/cmdline"
cat >"$target/etc/mkinitcpio.conf" <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
EOF
for kernel in linux linux-lts; do
  cat >"$target/etc/mkinitcpio.d/$kernel.preset" <<EOF
ALL_kver="/boot/vmlinuz-$kernel"
ALL_cmdline="/etc/kernel/cmdline"
PRESETS=('default')
default_uki="/efi/EFI/Linux/arch-$kernel.efi"
EOF
done

printf 'en_US.UTF-8 UTF-8\nko_KR.UTF-8 UTF-8\n' >"$target/etc/locale.gen"
printf 'LANG=en_US.UTF-8\n' >"$target/etc/locale.conf"
printf 'enoshima-vm-boot\n' >"$target/etc/hostname"
ln -sf /usr/share/zoneinfo/Asia/Seoul "$target/etc/localtime"
arch-chroot "$target" locale-gen
arch-chroot "$target" systemd-machine-id-setup
arch-chroot "$target" useradd --create-home --groups wheel --shell /bin/bash kentakang
arch-chroot "$target" passwd --lock root
arch-chroot "$target" passwd --lock kentakang
install -d -m 0700 -o 1000 -g 1000 "$target/home/kentakang/.ssh"
install -m 0600 -o 1000 -g 1000 "$authorized_key" \
  "$target/home/kentakang/.ssh/authorized_keys"
printf 'kentakang ALL=(ALL) NOPASSWD:ALL\n' >"$target/etc/sudoers.d/90-enoshima-vm"
chmod 0440 "$target/etc/sudoers.d/90-enoshima-vm"
install -m 0600 "$recovery_key" "$target/root/enoshima-vm-recovery-key"

cat >"$target/etc/nftables.conf" <<'EOF'
table inet enoshima_vm {
  chain output {
    type filter hook output priority 0; policy accept;
    ct state established,related accept
    ip daddr 10.0.2.3 udp dport 53 accept
    ip daddr 10.0.2.3 tcp dport 53 accept
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } reject
  }
}
EOF
arch-chroot "$target" systemctl enable \
  NetworkManager.service \
  nftables.service \
  qemu-guest-agent.service \
  systemd-resolved.service \
  sshd.service
install -d -m 0755 "$target/var/lib/systemd/linger"
touch "$target/var/lib/systemd/linger/kentakang"

arch-chroot "$target" bootctl install
arch-chroot "$target" mkinitcpio -P
install -m 0600 "$target/efi/EFI/Linux/arch-linux.efi" \
  "$target/root/arch-linux-unsigned.efi"
printf '%s\0' \
  'root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw console=tty0 console=ttyS0,115200n8 enoshima.unsigned_test=1' \
  >"$target/root/enoshima-unsigned-cmdline"
objcopy --update-section \
  ".cmdline=$target/root/enoshima-unsigned-cmdline" \
  "$target/root/arch-linux-unsigned.efi"
rm -f -- "$target/root/enoshima-unsigned-cmdline"
cat >"$target/efi/loader/loader.conf" <<'EOF'
default enoshima.conf
timeout 1
console-mode keep
editor no
EOF
cat >"$target/efi/loader/entries/enoshima.conf" <<'EOF'
title Enoshima VM (signed UKI)
efi /EFI/Linux/arch-linux.efi
EOF
cat >"$target/efi/loader/entries/enoshima-unsigned.conf" <<'EOF'
title Enoshima VM (unsigned negative test)
efi /EFI/Linux/arch-linux-unsigned.efi
EOF

arch-chroot "$target" sbctl create-keys
arch-chroot "$target" sbctl enroll-keys -m
for binary in \
  /efi/EFI/systemd/systemd-bootx64.efi \
  /efi/EFI/BOOT/BOOTX64.EFI \
  /efi/EFI/Linux/arch-linux.efi \
  /efi/EFI/Linux/arch-linux-lts.efi; do
  arch-chroot "$target" sbctl sign --save "$binary"
done
arch-chroot "$target" sbctl verify
install -m 0644 "$target/root/arch-linux-unsigned.efi" \
  "$target/efi/EFI/Linux/arch-linux-unsigned.efi"
rm -f -- "$target/root/arch-linux-unsigned.efi"

cat >"$target/root/enoshima-boot-metadata.json" <<EOF
{
  "root_luks_uuid": "$root_luks_uuid",
  "root_btrfs_uuid": "$root_btrfs_uuid",
  "esp_partition_uuid": "$esp_uuid",
  "esp_partition_partuuid": "$esp_partuuid"
}
EOF

sync
umount -R "$target"
cryptsetup close "$mapper"
trap - EXIT
printf 'Prepared signed LUKS2/Btrfs/UKI target on %s\n' "$disk"
