# my-arch-configurations

Arch Linux desired-state monorepo for the `tpx1c13` laptop. It combines
Ansible for system state, chezmoi for user configuration, and package/state
inventories for auditing and rebuilding the machine.

The initial inventory was captured on 2026-07-13 from Arch Linux on
`tpx1c13`:

- 792 installed pacman packages
- 122 explicitly installed native packages
- 6 explicitly installed foreign packages
- 15 enabled system units
- 10 enabled user units
- Hyprland, Waybar, Fcitx5, PipeWire, SDDM and NetworkManager desktop stack
- Btrfs root on LUKS2, systemd-boot UKIs, TPM2 unlock and Secure Boot

## Ownership boundaries

| State | Owner |
| --- | --- |
| Native packages and root-owned configuration | Ansible |
| AUR packages | `scripts/install-aur.sh` using paru |
| User dotfiles | chezmoi (`home/`) |
| Enabled system and user units | Ansible |
| Exact installed versions and hardware facts | `state/tpx1c13/` |
| Disk layout, Secure Boot keys and TPM enrollment | Documented manual prerequisite |

Do not manage the same file with both Ansible and chezmoi.

## Repository layout

```text
.
├── .chezmoiroot            # points chezmoi at home/
├── ansible/                # system desired state
├── docs/                   # design, scope and installation notes
├── home/                   # chezmoi source state
├── packages/               # desired package manifests
├── scripts/                # capture, AUR install and validation helpers
└── state/tpx1c13/          # observed state; not an install manifest
```

## Quick start on a newly installed Arch system

Read [docs/INSTALL.md](docs/INSTALL.md) first. Partitioning, LUKS formatting,
TPM enrollment and Secure Boot key enrollment are deliberately not automated.

```bash
git clone <repository-url> ~/src/my-arch-configurations
cd ~/src/my-arch-configurations
./bootstrap.sh tpx1c13
```

The bootstrap performs a full Arch upgrade, installs the management tools,
offers to build/install the reviewed AUR package list, runs Ansible, shows the
chezmoi diff, and asks before applying dotfiles.

Useful maintenance commands:

```bash
make audit PROFILE=tpx1c13
make validate
make chezmoi-diff
make ansible-check PROFILE=tpx1c13
```

## Desired versus observed packages

- `packages/native.txt` is the explicit native package install manifest.
- `packages/aur.txt` contains AUR package bases to install.
- `packages/optional-deps.txt` preserves intentionally installed optional
  dependencies with dependency install reason.
- `packages/management.txt` contains tooling needed to reproduce the system
  but not explicitly installed at the time of the initial capture.
- `state/tpx1c13/packages.lock` records every installed package and version,
  including dependencies and generated `-debug` AUR packages.

Generated AUR debug packages are retained in the observed lock but are not
direct install targets; they are produced by their package base when enabled by
makepkg configuration.

## Intentional normalizations

Two live files contain harmless but invalid spellings. The observed forms are
recorded under `state/tpx1c13/`, while the desired Ansible configuration uses
their valid equivalents:

- `/etc/vconsole.conf`: `KEYMAP=US` becomes `KEYMAP=us`. The live spelling is
  the cause of the currently failed `systemd-vconsole-setup.service`.
- `/etc/systemd/zram-generator.conf`: `comperssion-algorithm` becomes
  `compression-algorithm`.

No normalization is applied to the running system by this repository creation.

The live `~/.config/hyprland.lua` and `~/.config/hypr/personal.lua` are not
loaded by the active Hyprland Lua provider; the latter also has invalid Lua
syntax. They are preserved under `state/tpx1c13/observed-user-drafts/` rather
than applied by chezmoi. The active `~/.config/hypr/hyprland.lua` is managed.

## Known privileged gap

The current `/etc/snapper/configs/root` and `/etc/crypttab` are root-readable
only and non-interactive sudo was unavailable during capture. The active
initramfs crypttab entry was captured from the readable
`/etc/crypttab.initramfs`. Ansible can create a default Snapper root
configuration when absent, but the unreadable current Snapper tuning is not
guessed. See `state/tpx1c13/unreadable-settings.txt`.

## Safety

The repository intentionally excludes credentials, private keys, browser and
Codex application profiles, network connection profiles, histories, caches,
containers, user documents and other mutable data. A private Git remote does
not make committed secrets safe.
