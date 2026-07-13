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

The local and AUR package phases are deliberately interactive so their
PKGBUILDs can be reviewed. `SKIP_LOCAL=true` and `SKIP_AUR=true` are available
for a partial recovery, but the complete `tpx1c13` profile requires both
phases. Local packages are built before Ansible so their systemd units exist
when service desired state is applied. AUR applications are installed after
Ansible enables multilib and installs their native prerequisites.

Before accepting the chezmoi apply, inspect the diff. The next graphical login
is required for UWSM to import the new input-method environment and for the XDG
autostart entries to take effect.

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

## PAM safety

The host profile changes only `/etc/pam.d/sddm` and `/etc/pam.d/sudo`. Ansible
creates backups, but a malformed PAM stack can still prevent authentication.
Keep an authenticated root shell open during the first apply. Before rebooting,
test both paths:

```bash
fprintd-verify
sudo -k
sudo -v
hyprlock
```

At the SDDM and sudo prompts, a normal password is checked first. Submit an
empty field to start fingerprint authentication. See
[WORKSTATION.md](WORKSTATION.md) for the accepted sudo fingerprint security
tradeoff and the reason SDDM is not replaced by Hyprlock.

## Interactive workstation completion

After a reboot and password login:

1. In SDDM, select **Hyprland (uwsm-managed)** rather than plain Hyprland. The
   UWSM session is required for the managed environment, graphical user units,
   and XDG autostart applications.
2. Connect the Dell U2725QE and verify its EDID selector, scale, geometry and
   120 Hz mode with `make postflight`.
3. Inspect and enroll the intended Thunderbolt/USB4 device with `boltctl`.
4. Run `kakaotalk-setup`, complete the official KakaoTalk installer and login,
   then create a Bottles snapshot.
5. Test Wi-Fi to WWAN handoff locally. Do not disconnect the link carrying a
   remote session.
6. Launch Notion, Parsec and KakaoTalk once and confirm their runtime classes
   with the command in `WORKSTATION.md`.

## Verification

Before rebooting:

```bash
make validate
make postflight
make audit PROFILE=<host>
systemctl --failed
systemctl --user --failed
bootctl status
sudo sbctl verify
```
