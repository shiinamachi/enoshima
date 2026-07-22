#!/usr/bin/env bash
set -euo pipefail

disk=${1:-/dev/vdb}
recovery_key=${2:-}
authorized_key=${3:-}
target=/mnt/enoshima-vm-target
mapper=enoshima-vm-cryptroot

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

cleanup() {
  set +e
  umount -R "$target" 2>/dev/null
  cryptsetup close "$mapper" 2>/dev/null
}
trap cleanup EXIT

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

pacstrap -K "$target" \
  ansible-core \
  base \
  btrfs-progs \
  cryptsetup \
  git \
  jq \
  linux \
  linux-firmware \
  linux-lts \
  make \
  networkmanager \
  nftables \
  openssh \
  qemu-guest-agent \
  ripgrep \
  sbctl \
  sbsigntools \
  sudo \
  tpm2-tools \
  yq \
  zsh

# pacstrap can leave the target pacman keyring's gpg-agent alive with files
# open below the chroot. Stop that scoped agent before the final recursive
# unmount so the disposable boot disk is always cleanly detached.
gpgconf --homedir "$target/etc/pacman.d/gnupg" --kill all || true

# Preserve the suite's whole-repository Arch Linux Archive snapshot in the
# installed target. This prevents its later bootstrap from becoming a partial
# or moving-release package transaction.
install -m 0644 /etc/pacman.d/mirrorlist "$target/etc/pacman.d/mirrorlist"

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
  'root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw' \
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
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } reject
  }
}
EOF
arch-chroot "$target" systemctl enable \
  NetworkManager.service \
  nftables.service \
  qemu-guest-agent.service \
  sshd.service
install -d -m 0755 "$target/var/lib/systemd/linger"
touch "$target/var/lib/systemd/linger/kentakang"

arch-chroot "$target" bootctl install
arch-chroot "$target" mkinitcpio -P
install -m 0600 "$target/efi/EFI/Linux/arch-linux.efi" \
  "$target/root/arch-linux-unsigned.efi"
printf '%s\0' \
  'root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@ rw enoshima.unsigned_test=1' \
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
