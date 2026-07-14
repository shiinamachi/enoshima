# Design

## Goal

Rebuild the useful software and configuration state of an Arch Linux laptop
without treating Git as a filesystem backup.

## Principles

1. Keep desired state separate from observed state.
2. Make system changes idempotent and reviewable.
3. Keep hardware-bound values in host variables.
4. Exclude secrets and mutable user data rather than encrypting them here.
5. Never automate destructive storage or key-enrollment operations.
6. Preserve Arch's full-upgrade model; do not perform partial upgrades.

## Layers

### Bootstrap

`bootstrap.sh` is the only convergence orchestrator for both first install and
later updates. It selects one user-file conflict policy, authenticates sudo
once with a non-interactive keepalive, installs only the tools needed to
continue, validates the repository, and invokes every remaining layer through
postflight. Child tools cannot open another sudo prompt; loss of the cached
credential fails the run safely.

### Package desired state

Line-oriented manifests remain easy to diff and can be consumed by both shell
and Ansible. Native, absent, and optional dependency packages are managed by
Ansible. Pinned local packages are rebuilt only when their declared version
changes. AUR operations run in the user context without extra prompts, so
the declared AUR package bases are an allowlist, not a content pin. Each run
explicitly trusts the then-current AUR PKGBUILDs; audit or pin a recipe locally
when stronger provenance is required.

### System desired state

Ansible owns root-managed text configuration, host identity, locales,
subordinate IDs, boot configuration declarations, Snapper setup, and systemd
enablement. Ansible performs a post-configuration boot rebuild only when
`apply_boot_artifacts=true` is explicitly supplied after Secure Boot keys are
available. Arch package transactions can still invoke their normal mkinitcpio
hooks; the flag controls the later rebuild using newly declared inputs.

### User desired state

chezmoi owns only selected configuration beneath the user's home directory.
The `.chezmoiroot` file isolates it to `home/`, allowing the rest of the Git
repository to coexist without ignore rules for every top-level directory.
Its persistent state is isolated under the reserved, non-managed
`~/.my-arch-configurations/` directory. Pre-existing targets and edits made
after the last apply are classified before privileged changes whenever the
bootstrap tools already exist, or immediately after installing those tools on
a fresh system. One run-wide backup/overwrite/keep/abort policy handles all of
them without following symlinks or crossing mounted filesystem boundaries.
Custom user units shipped through chezmoi are enabled after their files have
been applied, rather than from the earlier Ansible phase.

### Observed state

`scripts/capture-state.sh` records package versions, install reasons, service
enablement, hardware identifiers, filesystems, boot status, language toolchain
state, and checksums of selected system configuration. These files support
auditing; Ansible never consumes lock files as desired state.

## Host portability

Common defaults live in `ansible/inventory/group_vars/all.yml`. Values tied to
the current laptop live in `ansible/inventory/host_vars/tpx1c13.yml`, including
LUKS UUID, ESP partition UUID, UKI names, Btrfs identity and enabled hardware
services. A second machine should receive its own host file instead of copying
these identifiers.

## Workstation policy

The concrete ThinkPad hardware paths, SDDM/Hyprlock boundary, monitor geometry,
workspace routing, TLP profiles, fingerprint scope, Fcitx mapping, WWAN
fallback, Bottles isolation and proprietary application limits are recorded in
`docs/WORKSTATION.md`. Those decisions are desired state; `state/tpx1c13/`
remains the immutable observation made before this workstation profile was
designed.
