# Enoshima decoration

This is a narrow fork of the Hyprland 0.55/0.56 `hyprbars` plugin. It keeps the
upstream decoration, input, rendering, and ABI checks while changing ownership
from global opt-out to a comma-separated positive class allowlist.

Enoshima additions render Papirus SVG application/caption icons through
`librsvg`, switch Maximize to Restore from the exact owner window state, expose
bilingual pointer tooltips, and route keyboard access through the anchored
Alt+Space system menu without stealing Tab from applications.

The fork is based on official `hyprland-plugins` tag `v0.55.0`, pinned source
commit `90e66baf99c9025b1d5e9c9e58dd3c80d0911ea2`, whose Hyprland 0.55 source pin
is `3aa21f2e0ca72412f1b434c3126f8f1fec3c716c`. Compatibility shims for the
state registries, view hit testing, fullscreen controller, geometry accessors,
and animation namespace track official `hyprbars` tag `v0.56.0` commit
`7644cecdb947060682891a0db2a0cdc5c0b9e704`.

`bootstrap.sh` rebuilds the shared object against the locally installed
Hyprland headers after plugin-manager convergence. The stable installed path is
`~/.local/lib/enoshima/enoshima-decoration.so`; a recorded Hyprland API hash
prevents a stale object from loading after an upgrade.

The BSD-3-Clause upstream license is retained in `LICENSE`. New Enoshima
changes remain under the same license.
