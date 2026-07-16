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

The inventory `target_user_home` must be the user's real, canonical home path,
not a symlink to another directory.

Then run:

```bash
./bootstrap.sh
```

If the inventory has one host, the command selects it automatically. With
multiple hosts, use `./bootstrap.sh --profile <host>`. The exact same command
is the maintenance/update command after pulling repository changes.

Before any system configuration is changed, the command asks once for a
run-wide chezmoi user-file conflict policy:

- `backup` (default): preserve every conflict under
  `~/.my-arch-configurations/backups/`, then apply the repository.
- `overwrite`: apply the repository without making conflict backups.
- `keep`: preserve all conflicting local targets and apply everything else.
- `abort`: stop before Ansible if any user-file conflict exists.

Recursive conflict handling never follows symlinks or crosses a mount beneath
the home directory. `keep` preserves a mounted tree. `backup` and `overwrite`
stop during preflight when replacement would cross a mount; unmount that tree
after reviewing it, or choose `keep` for the run.

For a non-interactive run, pass `--conflict-policy <policy>` or set
`CONFLICT_POLICY`. The command then requests sudo authentication once, refreshes
that credential in the background, and forces all child privilege escalation
to be non-interactive. If the credential cannot be refreshed, the run fails
instead of asking for a second password.

Local PKGBUILDs are reviewed and pinned in this repository. Every AUR package
base also has an exact AUR commit plus `PKGBUILD` and `.SRCINFO` hashes in
`packages/aur-review.lock`. Bootstrap materializes those reviewed commits and
builds the resulting local directories; it stops before any build when the AUR
head or either hash differs. Review an update and record the new revision with:

```bash
./scripts/review-aur.sh update PACKAGE_BASE
```

The command displays the complete AUR Git diff and accepts only the literal
`REVIEW` response. Move a recipe under `packages/local/` when its upstream
payload also needs a repository-owned content pin. The package phases do not
stop for individual approval after the review gate. `SKIP_LOCAL=true` and
`SKIP_AUR=true` remain available for partial recovery, but the complete
`tpx1c13` profile requires both phases. Local
packages are built only when the declared version differs from the installed
version and are installed before Ansible so their systemd units exist. AUR
applications follow Ansible after multilib and native prerequisites are
present.

Validation, chezmoi hooks, service refreshes, and postflight checks are part of
the command. No later `make validate`, `make apply`, or `make postflight` step
is required. The next graphical login is still required for UWSM to import a
new input-method environment and for XDG autostart entries to take effect;
session-dependent postflight checks are warnings when no graphical session is
active.

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
artifacts. This remains a deliberate trust boundary rather than a missing
postflight step. After keys and mounts are ready, include rebuilding in the
same convergence command with:

```bash
./bootstrap.sh --apply-boot-artifacts
sudo sbctl sign-all
sudo sbctl verify
```

The latter signing and verification commands are security-key operations, not
automated configuration. `--apply-boot-artifacts` rebuilds on the first
explicit request and thereafter only after a managed boot input changes.
Normal Arch kernel and firmware package transactions may independently run
their standard mkinitcpio hooks with the configuration present at that point.

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
   120 Hz mode with `hyprctl monitors all` if it was disconnected during the
   integrated postflight.
3. Inspect and enroll the intended Thunderbolt/USB4 device with `boltctl`.
4. Run `kakaotalk-setup`; an existing bottle receives a private pre-profile
   snapshot automatically. Complete the official KakaoTalk installer and login,
   then create a post-login Bottles snapshot. Run `kakaotalk-smoke-test`; promote the
   checksum-pinned candidate only after its acceptance report passes.
5. Test Wi-Fi to WWAN handoff locally. Do not disconnect the link carrying a
   remote session.
6. Launch Notion, Parsec and KakaoTalk once and confirm their runtime classes
   with the command in `WORKSTATION.md`.

## Optional diagnostics

The convergence command already runs repository validation and postflight.
The following remain useful when investigating a warning or capturing a new
observation, but they are not installation completion steps:

```bash
make validate
make postflight
make audit PROFILE=<host>
systemctl --failed
systemctl --user --failed
bootctl status
sudo sbctl verify
```
