![Enoshima, a calm, coherent, accessible, keyboard-first Cyberpunk Arch Linux remix](docs/assets/branding/enoshima-readme-header.png)

# enoshima

Arch Linux desired-state monorepo for the `tpx1c13` laptop. It combines
Ansible for system state, chezmoi for user configuration, and package/state
inventories for auditing and rebuilding the machine.

The complete ThinkPad, Hyprland, workspace, power, fingerprint, WWAN, Korean
input, and application decisions are documented in
[docs/WORKSTATION.md](docs/WORKSTATION.md).

The desktop's Windows/macOS usability research and the reviewed Cyberpunk
Library interface studies are kept in
[docs/DESKTOP-UX-REFERENCES.md](docs/DESKTOP-UX-REFERENCES.md) and
[docs/DESKTOP-UI-CONCEPT.md](docs/DESKTOP-UI-CONCEPT.md).
The pinned, repository-only AI design workflow and its review rationale are
documented in [docs/DESIGN-SKILLS.md](docs/DESIGN-SKILLS.md).

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
| AUR packages | review-locked AUR Git revisions built through paru |
| User dotfiles | chezmoi (`home/`) |
| Enabled system and user units | Ansible |
| Exact installed versions and hardware facts | `state/tpx1c13/` |
| Disk layout, Secure Boot keys and TPM enrollment | Documented manual prerequisite |

Do not manage the same file with both Ansible and chezmoi.

## Repository layout

```text
.
├── .agents/skills/         # repository-only Codex design skills
├── .chezmoiroot            # points chezmoi at home/
├── ansible/                # system desired state
├── docs/                   # design, scope and installation notes
├── home/                   # chezmoi source state
├── packages/               # desired package manifests
├── scripts/                # capture, AUR install and validation helpers
└── state/tpx1c13/          # observed state; not an install manifest
```

## One-command convergence

Read [docs/INSTALL.md](docs/INSTALL.md) first. Partitioning, LUKS formatting,
TPM enrollment and Secure Boot key enrollment are deliberately not automated.
After those prerequisites, the same command is used for both a new Arch
installation and every later configuration update:

```bash
git clone <repository-url> ~/src/enoshima
cd ~/src/enoshima
./bootstrap.sh
```

At startup it asks once how all conflicting chezmoi-managed user files should
be handled: back up and replace, overwrite, keep local, or abort. It then asks
sudo to authenticate once and keeps that credential alive without allowing any
later password prompt. The command performs a supported full Arch upgrade,
installs only missing or changed local/AUR packages, converges Ansible state,
applies non-conflicting or selected dotfile state, and runs postflight checks.

The default conflict policy stores preserved files beneath
`~/.enoshima/backups/`. For unattended use, select a
policy without a prompt:

```bash
./bootstrap.sh --conflict-policy backup
```

The conflict engine never follows symlinks or crosses mounted subtrees during
recursive backup or replacement. `keep` preserves such a mounted tree;
`backup` and `overwrite` stop before changing user files so the mount can be
reviewed and removed explicitly.

`make` and `make apply` are aliases for the same complete convergence path.
Root-owned text configuration remains Ansible-authoritative and receives
Ansible backups when its contents are replaced. Unexpected pacman file
conflicts fail safely;
the command never uses a blanket `pacman --overwrite` rule.

Optional diagnostic commands (none is a required completion step):

```bash
make audit PROFILE=tpx1c13
make validate
make postflight
make chezmoi-diff
make ansible-check PROFILE=tpx1c13
```

Postflight can warn about work that inherently requires a person or hardware,
such as fingerprint enrollment, APN credentials, a disconnected monitor, or a
KakaoTalk login, or a failed third-party session unit. Those warnings do not
turn a completed automated convergence into a failure.

## Desired versus observed packages

- `packages/native.txt` is the explicit native package install manifest.
- `packages/aur.txt` contains AUR package bases to install.
- `packages/aur-review.lock` binds every AUR base to its reviewed Git commit,
  `PKGBUILD`, and `.SRCINFO` hashes.
- `packages/optional-deps.txt` preserves intentionally installed optional
  dependencies with dependency install reason.
- `packages/management.txt` contains tooling needed to reproduce the system
  but not explicitly installed at the time of the initial capture.
- `packages/absent.txt` declares packages deliberately removed from the
  workstation profile.
- `packages/local/` contains reviewable PKGBUILDs for pinned fixes that are not
  correctly represented by an official or current AUR package.
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
