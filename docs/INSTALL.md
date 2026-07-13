# Installation and recovery

This repository configures an already bootable Arch Linux installation. The
storage and trust setup below is intentionally manual because applying it to
the wrong device can destroy data or invalidate Secure Boot.

## Current host storage/trust model

- UEFI with Secure Boot enabled and Microsoft vendor keys enrolled
- Existing EFI System Partition mounted at `/efi`
- LUKS2 root partition unlocked as `/dev/mapper/cryptroot`
- TPM2 automatic unlock via `/etc/crypttab.initramfs`
- Btrfs filesystem labeled `ARCH`, root subvolume `@`
- Root mount selected by the UKI kernel command line; `/etc/fstab` has no
  persistent mounts
- systemd-boot with `arch-linux.efi` and `arch-linux-lts.efi` UKIs
- Snapper root configuration with timeline and cleanup timers

The captured UUIDs are inventory for `tpx1c13`, not values to reuse after
repartitioning. Update the host variables after creating a new filesystem.

## Manual prerequisite

1. Partition and format the target disk.
2. Create LUKS2 and Btrfs, including the `@` subvolume.
3. Install a minimal Arch system and make it bootable.
4. Create the target user, add it to `wheel`, and configure password-based
   sudo.
5. Mount the ESP at `/efi` and install systemd-boot if needed.
6. Clone this repository as the target user.
7. Update `ansible/inventory/host_vars/<host>.yml` with the new LUKS, Btrfs and
   ESP identifiers.

Then run:

```bash
./bootstrap.sh <host>
```

## Secure Boot and TPM2

Secure Boot keys are not stored in Git. After creating or restoring keys with
`sbctl`, enroll them with Microsoft vendor keys as appropriate, rebuild the
UKIs, sign them, and verify their signatures. The relevant operations are
typically:

```bash
sudo sbctl create-keys
sudo sbctl enroll-keys -m
sudo mkinitcpio -P
sudo sbctl sign-all
sudo sbctl verify
```

Review `sbctl` output before rebooting. Only after the LUKS passphrase has been
tested should TPM2 enrollment be performed, for example with
`systemd-cryptenroll`. TPM enrollment changes LUKS key slots and is not run by
Ansible.

By default Ansible writes the declared boot configuration without rebuilding
artifacts. After keys and mounts are ready, the playbook may be run with:

```bash
ansible-playbook -K -i ansible/inventory/hosts.yml ansible/site.yml \
  --limit <host> -e apply_boot_artifacts=true
sudo sbctl sign-all
sudo sbctl verify
```

## Snapper

If `/etc/snapper/configs/root` does not exist, Ansible runs the normal
`snapper -c root create-config /` command. Inspect the resulting Btrfs
subvolume/layout before relying on snapshots. The exact old root configuration
was not readable during the initial capture.

## Verification

Before rebooting:

```bash
make validate
make audit PROFILE=<host>
systemctl --failed
systemctl --user --failed
bootctl status
sudo sbctl verify
```
