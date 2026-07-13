# tpx1c13 observed state

Captured on 2026-07-13 by `scripts/capture-state.sh`.

This directory is evidence of the live machine, not direct Ansible input.
Package locks include dependencies and versions that may no longer be present
on current Arch mirrors.

Initial counts:

- 792 total packages
- 122 explicit native packages
- 6 explicit foreign packages
- 2 orphan packages (`node-gyp`, `rustup`)
- 15 enabled system units
- 10 enabled user units

The desired configuration intentionally promotes `rustup` to a managed package
because an active stable Rust toolchain is installed. `node-gyp` is not
promoted because no user-level npm package state was found.

The observed foreign list contains `lenovo-wwan-unlock-debug` and `paru-debug`.
These build artifacts remain in `packages.lock` but their package bases are the
reprovisioning targets in `packages/aur.txt`.

`observed-system-config/` contains only explicitly allowlisted, non-secret,
readable text configuration. It excludes root-only crypttab/Snapper settings,
NetworkManager connection profiles, keys and generated security databases.

`observed-user-drafts/` retains the unused `~/.config/hyprland.lua` entrypoint
and `~/.config/hypr/personal.lua`. Live Hyprland values match the active
`~/.config/hypr/hyprland.lua`; `personal.lua` is also invalid standard Lua, so
neither draft is deployed by chezmoi.
