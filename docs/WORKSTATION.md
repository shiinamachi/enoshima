# ThinkPad X1 Carbon Gen 13 workstation profile

This document records the decisions behind the `tpx1c13` profile. It is the
operational contract for the repository, not a claim that every proprietary
application is supported by its vendor on Linux.

## Hardware baseline

The profile targets the observed ThinkPad X1 Carbon Gen 13 (`21NX`) with an
Intel Core Ultra 7 255H and 32 GiB RAM.

| Function | Selected Linux path |
| --- | --- |
| Intel graphics and video decode | in-kernel `i915`, Mesa, `intel-media-driver` |
| NPU | in-kernel `intel_vpu` |
| RGB and IR cameras | standard USB UVC/V4L2; no IPU6 DKMS stack |
| Fingerprint reader | upstream `libfprint`/`fprintd` for Synaptics `06cb:0123` |
| Audio | SOF firmware, PipeWire, WirePlumber, RealtimeKit |
| Wi-Fi | `iwlwifi` managed by NetworkManager |
| 5G WWAN | `mhi-pci-generic`, ModemManager, Lenovo FCC/SAR service |
| Thunderbolt/USB4 dock trust | `bolt`; enrollment remains an explicit user action |
| Suspend | `s2idle` |

The camera is already exposed as normal UVC devices. Installing an IPU6 DKMS
or proprietary camera HAL on this machine would add failure modes without
providing the active camera path.

## Login and fingerprint model

SDDM remains the boot-time display manager. Hyprlock is a session locker and
does not create a login session, so SDDM autologin followed by Hyprlock is not
treated as an equivalent security boundary. The repository does not enable
autologin.

Authentication behavior is deliberately service-specific:

- SDDM: type the password normally, or submit an empty password field and then
  scan the enrolled finger.
- Hyprlock: its native fingerprint support runs alongside the PAM password
  path.
- `sudo`: type the password normally, or submit an empty prompt and then scan.
- `su`, Polkit, `system-auth`, and SSH are not changed.

The service-specific password/fingerprint branch retains Arch's shell,
`nologin`, environment, and `pam_faillock` checks; a successful fingerprint
does not bypass those checks.

GNOME Keyring supplies the Secret Service used by Zed, Chrome, and Slack. A
password login lets the SDDM PAM session unlock the login keyring. Fingerprint
authentication cannot provide that password, so after a fingerprint-only login
the keyring may remain locked until it is unlocked interactively.

Fingerprint authentication for `sudo` accepts the trusted-attention weakness
described by CVE-2024-37408. A background process may be able to race or reuse
a fingerprint interaction. This is an explicit convenience-versus-security
decision for this profile.

Keep an authenticated root shell open while testing PAM after the first apply.
Test `sudo -k && sudo -v`, SDDM, and Hyprlock before relying on fingerprint-only
access.

## Displays and HiDPI

Both panels use scale `1.5` and 120 Hz on AC and battery. The coordinates are
Hyprland logical pixels after scaling:

| Output | Mode | Logical size | Position | Role |
| --- | --- | --- | --- | --- |
| ThinkPad `eDP-1` | 2880x1800@120 | 1920x1200 | `0x240` | lower-left |
| Dell U2725QE | 3840x2160@120 | 2560x1440 | `1920x0` | upper-right |

This bottom-aligns the panels while putting the Dell fully to the right. The
240 logical-pixel vertical offset represents the external display sitting
higher than the laptop. The internal panel stays enabled while the Dell is
connected.

The Dell rule uses an EDID description selector because the USB-C connector
may appear as a different `DP-*` name depending on the port and dock topology.
After the first connected login, verify the exact value with:

```bash
hyprctl monitors all
make postflight
```

The profile uses SDR, 8-bit output, and VRR off. This is the conservative path
for Parsec, portals, screenshots, and Wine capture. XWayland zero-scaling is
enabled so legacy applications render sharply; the KakaoTalk bottle is set to
144 DPI to match scale 1.5.

## Workspaces and window control

| Workspace | Purpose | Preferred output | Routed applications |
| --- | --- | --- | --- |
| 1 DEV | development | Dell | Zed, Ghostty |
| 2 WEB | browser | Dell | Google Chrome |
| 3 DOCUMENT | communication and notes | internal | KakaoTalk, Discord, Slack, Notion, Obsidian |
| 4 REMOTE | remote control | Dell | Parsec |
| 5 MISC | files and utilities | internal | Thunar and other tools |

Workspaces 6–10 remain persistent reserves. When the Dell is unplugged, the
workspace routing falls back to `eDP-1`. Application class rules are broad
enough for the known packages, but Notion, Parsec, and Wine can change their
runtime class. Inspect first-run values without exposing application data:

```bash
hyprctl -j clients | jq -r \
  '.[] | [.initialClass, .class, .initialTitle, .xwayland] | @tsv'
```

Core bindings:

| Binding | Action |
| --- | --- |
| `Super+Space` or `Super+R` | toggle the pre-warmed Hyprlauncher |
| `Super+Enter` | Ghostty |
| `Super+D` | Zed |
| `Super+B` | Chrome |
| `Super+E` | Thunar |
| `Super+H/J/K/L` | focus left/down/up/right |
| `Super+Shift+H/J/K/L` | move the active window |
| `Super+Alt+H/J/K/L` | resize the active split |
| `Super+1..0` | select workspace 1..10 |
| `Super+Shift+1..0` | move a window to workspace 1..10 |
| `Super+left mouse drag` | move a window |
| `Super+right mouse drag` | resize a window |

Tiled split boundaries can also be dragged directly with the pointer. Waybar's
workspace labels use the compositor's ext-workspace protocol, so they can be
clicked without relying on Hyprland's removed legacy dispatcher syntax.

## Power policy

TLP 1.10 and `tlp-pd` replace `power-profiles-daemon`. Only the agreed policy
knobs are enabled; broad USB, PCI runtime, radio, and disk defaults are disabled
to avoid destabilizing WWAN, the camera, and Thunderbolt.

| Condition/profile | Platform profile | Energy preference | Boost |
| --- | --- | --- | --- |
| AC / performance | performance | performance | on |
| Battery / balanced | balanced | balance_power | on |
| Manually selected power-saver | low-power | power | off |

No charge threshold is configured. The profile does not cap maximum CPU
frequency or lower either display to 60 Hz on battery. Hypridle locks after
five minutes, powers displays down after ten minutes, and suspends after thirty
minutes only when on battery.

Use `tlpctl performance`, `tlpctl balanced`, or `tlpctl power-saver` for a
temporary manual selection. `tlp-stat -s -c -p -b` is the authoritative
diagnostic output.

## Korean input

Fcitx5 remains the input framework. The perceived switching delay came from
using Right Alt as a modifier-only hotkey with a qualification timeout. XKB now
maps the physical Right Alt key directly to `Hangul`, and Fcitx listens for
`Hangul` and `Ctrl+Space`.

- Right Alt: immediate Korean/English toggle; it is no longer available as Alt.
- F9: Hanja conversion.
- Right Ctrl remains Ctrl.
- Native Wayland GTK applications use the text-input protocol.
- `XMODIFIERS=@im=fcitx` is exported for Wine/XWayland.

A logout/login is required after applying the UWSM environment.

## Applications and trust boundaries

Official Arch packages provide Ghostty, Zed, Discord, and Obsidian. Bottles is
installed from user-scoped Flathub. Google Chrome, Slack, Parsec, and the
requested unofficial Notion package are reviewed AUR builds. Firefox and Kitty
are removed.

`notion-app-electron` is not published or supported by Notion. Its PKGBUILD and
upstream payload must be reviewed at every meaningful update. Parsec on Linux
is a client and uses XWayland; this profile installs it but does not configure
hosting.

The two local PKGBUILDs have narrow purposes:

- Lenovo WWAN unlock repackages Lenovo's official release while recursively
  including the Gen 13 `cs25` SAR data omitted by the current AUR recipe.
- `xembed-sni-proxy` is pinned to a reviewed upstream commit and translates
  legacy Wine tray icons to the StatusNotifier protocol used by Waybar.

Neither proprietary Lenovo blobs nor built packages are committed to Git.

## KakaoTalk through Bottles

Bottles is installed from the user-scoped Flathub remote. The repository does
not create a bottle automatically because accepting the application installer,
logging in, and choosing a runner are interactive trust decisions.

After bootstrap and a fresh login:

```bash
kakaotalk-setup
```

The helper creates a dedicated 64-bit application bottle, grants only
Downloads/Documents/Pictures, exports Fcitx XIM, applies 144 DPI, launches the
official Kakao installer, and registers the installed executable. The
`kakaotalk` wrapper and login autostart remain silent until provisioning is
complete.

After the first successful login, create a Bottles snapshot and keep the known
working runner instead of changing it during an urgent KakaoTalk update. Verify
chat, Korean input, file send/receive, clipboard, tray restore, and desktop
notifications. Voice/video calls and screen sharing are out of scope. Wine and
KakaoTalk updates can still regress otherwise working behavior.

## Network preference

NetworkManager stores SIM, APN, and Wi-Fi credentials outside Git. The fallback
policy discovers the existing GSM profile at runtime:

- connected Wi-Fi causes the active WWAN connection to be released;
- loss of Wi-Fi enables WWAN and starts the GSM profile;
- WWAN is marked metered and receives a higher route metric;
- a locked, nonblocking oneshot avoids NetworkManager dispatcher recursion.

The Lenovo configuration service and Gen 13 SAR file must be healthy before
judging fallback behavior. Test handoff locally; never turn off the link that
is carrying a remote administration session.

## First-apply checklist

1. Run `make validate` and review both local PKGBUILDs and every AUR PKGBUILD.
2. Run `./bootstrap.sh tpx1c13` from the target desktop user.
3. Reboot, select **Hyprland (uwsm-managed)** in SDDM (not plain Hyprland),
   then log in once with the password so the new UWSM environment is imported.
4. Keep a root shell open and test SDDM, Hyprlock, and `sudo` fingerprint paths.
5. Connect the Dell by USB-C and run `make postflight`.
6. Enroll the Dell/Thunderbolt device with `boltctl` only after confirming its
   identity.
7. Run `kakaotalk-setup` and validate KakaoTalk behavior.
8. Test Wi-Fi to 5G fallback locally.
9. Launch Notion, Parsec, and KakaoTalk once and confirm their Hyprland classes.

Warnings from a disconnected Dell or an unprovisioned Kakao bottle are expected
in postflight. Core package, PAM, power, SAR, service, and internal-display
failures are not.
