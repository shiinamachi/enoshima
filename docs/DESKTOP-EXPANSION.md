# Desktop expansion design

## Status

Approved and implemented in the repository on 2026-07-13. Declarative package,
service, desktop, and validation state is complete. Account enrollment, SDDM
theme activation, and the visual/interactive acceptance items remain explicit
manual gates documented in `DESKTOP-EXPANSION-OPERATIONS.md`; their mutable
results are intentionally not committed.

## Goals

1. Turn the current Hyprland session into a coherent cyberpunk desktop based
   on the user-supplied wallpaper.
2. Add a macOS-like dock and usable close, minimize, maximize/restore, and
   fullscreen window controls.
3. Make the requested communication, cloud, mail, graphics, and office tools
   reproducible without committing account or document data.
4. Correct HiDPI behavior where an application has a safe native or per-app
   scaling path.
5. Preserve the repository's Ansible, chezmoi, observed-state, and secret
   ownership boundaries.

## Explicit non-goals

- Do not provision a Windows VM or disposable Windows sandbox in this phase.
- Do not create or select an Obsidian vault.
- Do not enlarge the Parsec UI. The user selected the sharp-stream option:
  keep Parsec on XWayland with zero scaling and accept its small management UI.
- Do not commit mail, cloud, Cloudflare, KakaoTalk, or Obsidian credentials and
  mutable data.
- Do not claim vendor support for Arch where a vendor supports only selected
  Linux distributions.

## Approved visual language

The source asset will be copied without generative modification from:

`/home/kentakang/Downloads/ChatGPT Image Jul 13, 2026, 05_31_02 PM.png`

to the managed chezmoi source:

`home/dot_local/share/backgrounds/cyberpunk-city.png`

The visual palette is sampled conceptually from the asset:

| Role | Color |
| --- | --- |
| Deep background | `#070b2a` |
| Glass surface | `#111447` |
| Neon cyan | `#33d6ff` |
| Neon magenta | `#ff3cc7` |
| Electric violet | `#8b5cff` |
| Primary text | `#e9e8ff` |
| Warning | `#ffb84d` |
| Critical | `#ff426d` |

The following surfaces share these tokens instead of defining unrelated
themes: Hyprland borders, Hyprpaper, Hyprlock, SDDM, Waybar, Quickshell dock,
Hyprbars, SwayNC, Hyprlauncher, tooltips, and session controls.

### Wallpaper and lock/login screens

- Hyprpaper uses the managed image on every output with `cover` behavior.
  The external 16:9 panel receives the near-native composition; the internal
  16:10 panel uses a centered crop.
- Hyprlock uses the same file rather than a live screenshot. It dims and blurs
  the background, places the clock and authentication field in the lower-left
  negative space, and keeps the character readable on the right.
- SDDM receives a matching theme only after the session theme is validated.
  The theme must not alter the existing PAM and fingerprint authentication
  policy, and SDDM must retain a known-good fallback theme.
- Waybar remains at the top and uses a translucent glass surface, thin cyan to
  magenta edge, violet focus state, and existing information modules.

## Font architecture

Jetendard is approved as the global sans-serif and monospace default. Serif
documents continue to use the existing serif fallback because Jetendard is
not a serif family.

Jetendard has no maintained Arch binary package. A reproducible local package
will therefore:

1. pin a reviewed `kuskhan/jetendard` commit and every upstream font input;
2. build and test the complete 16-variant TTF family;
3. install it below `/usr/share/fonts/TTF` through pacman; and
4. refresh fontconfig through the normal package hook.

A managed fontconfig rule puts `Jetendard` first for `sans-serif` and
`monospace`. GTK/dconf, Qt-facing UI, Waybar, Hyprlock, Hyprbars, Quickshell,
Ghostty, Zed, and SDDM explicitly request the family as well. Noto CJK and
emoji remain fallbacks. Carlito, Caladea, and Liberation remain installed for
metric-compatible Microsoft Office document rendering even though Jetendard
is the desktop default.

Acceptance checks include `fc-match sans-serif`, `fc-match monospace`, Korean
glyph width in terminal/editor output, Nerd Font icons, emoji fallback, and an
office document with explicit Calibri/Cambria-compatible fonts.

## Dock and window-state architecture

### Quickshell dock

The selected implementation is a repository-owned Quickshell shell, not
`nwg-dock-hyprland`. Quickshell is available as an official Arch package and
allows minimized-state behavior to be integrated with Hyprland IPC.

One dock instance is rendered on every connected monitor. Each instance:

- is hidden by default;
- exposes a one-pixel logical hotspot at the bottom edge;
- animates into view when the pointer enters the hotspot;
- hides after the pointer leaves the dock and hotspot;
- reserves no permanent work area;
- shows the same pinned applications and all running/minimized applications;
  and
- switches to the owning monitor/workspace when a window on another output is
  selected.

The approved pinned applications, in order, are:

1. Thunar
2. Google Chrome
3. Ghostty
4. Zed
5. KakaoTalk
6. Thunderbird
7. Obsidian
8. Bottles
9. PhotoGIMP
10. ONLYOFFICE
11. RHWP Desktop

The Windows VM pin from the preliminary proposal is removed because VM
provisioning was declined.

Dock click semantics are fixed:

- stopped pinned application: launch it;
- running, unfocused application: focus its most recent window;
- running, already focused application: no action;
- minimized application: return the window to its original workspace and
  focus it;
- multiple windows in one application: show a compact window chooser.

### Minimize model

Hyprland has no native desktop-style minimize state. The managed window-state
helper emulates it without killing or unmapping the client:

1. read the active window address, workspace, and monitor;
2. record only that runtime state beneath
   `$XDG_RUNTIME_DIR/cyberdock/`;
3. move the window silently to `special:minimized`;
4. mark the matching dock item as minimized; and
5. on restore, move it back to the recorded workspace, recover a valid output
   if the original output was disconnected, and focus it.

Runtime state is pruned when a client closes and is never committed. A
Quickshell crash must not strand windows: a recovery command lists every
client in `special:minimized` and restores it to a safe current workspace.

### Hyprbars controls

The official `hyprbars` plugin supplies compositor-owned title bars. Because
Hyprland plugins are ABI-coupled, an idempotent `hyprpm` helper selects the
official plugin revision matching the installed Hyprland version and
revalidates it after Hyprland upgrades.

Buttons follow the approved behavior:

- red: close;
- yellow: invoke the minimize helper;
- green: toggle maximized/work-area state while retaining bars;
- double-click the green button or press `Super+F`: toggle true fullscreen.

Native client-side decorations are suppressed or exempted per application so
that an application never receives two title bars. Plugin failure must leave
keyboard controls usable (`Super+C` close and recovery command for minimized
windows).

## HiDPI and input design

Both known displays stay at scale `1.5`. Hyprland
`xwayland.force_zero_scaling=true` remains enabled to preserve sharp
XWayland/Wine content.

- Chrome, Notion, Obsidian, Discord, Slack, RHWP Desktop, and any other
  compatible Electron application use native Wayland, Wayland window
  decorations, Fcitx Wayland IME, and text-input-v3 through per-app flag files
  or managed launch wrappers.
- Discord and Slack are the new correction targets. Their runtime class and
  `xwayland` value must be verified after launch; success means native Wayland
  and correct 1.5 compositor scaling without a forced Electron device scale.
- Thunderbird uses its native Wayland path.
- GIMP/PhotoGIMP and GTK utilities rely on native Wayland scaling.
- KakaoTalk stays XWayland/Wine and uses 144 DPI inside its bottle.
- Parsec stays XWayland with zero scaling. Its small UI is an approved
  exception; no Gamescope wrapper or global blurry scaling will be added.
- ONLYOFFICE receives an isolated wrapper adjustment only if its installed
  build fails the 1.5-scale smoke test. A global Qt/GDK scale override is not
  allowed.

Right Alt handling is already correct in desired and running state:

- XKB option `korean:ralt_hangul` maps physical Right Alt directly to
  `Hangul`;
- Fcitx5 listens for `Hangul` and `Ctrl+Space`;
- Right Alt is no longer available as an Alt modifier; and
- F9 remains the Hanja key.

Implementation still performs a physical-key acceptance test with `wev`,
Fcitx state inspection, a native Wayland editor, Electron, and KakaoTalk.

## Bottles and KakaoTalk

The current diagnosis is not a corrupt KakaoTalk installation: the user-scoped
Bottles Flatpak exists, but no `KakaoTalk` bottle or registered program exists.
The current WWAN DNS servers also caused Bottles' internal pycurl connection
probe to time out while normal host resolution continued working.

The existing interactive setup remains the ownership boundary but gains a
clear connectivity preflight and retry path:

1. verify Flatpak networking and `https://ping.usebottles.com` from inside the
   sandbox;
2. run the check again after Cloudflare One enrollment because WARP replaces
   the active DNS path;
3. create a dedicated 64-bit application bottle;
4. retain X11/Wine, 144 DPI, and `XMODIFIERS=@im=fcitx`;
5. allow only Downloads, Documents, and Pictures;
6. download the installer from Kakao's official CDN;
7. leave installer acceptance, login, and snapshot creation interactive; and
8. verify chat, Korean composition, clipboard, files, tray restoration, and
   notifications.

Voice/video calls and screen sharing remain unsupported acceptance targets.
Wine prefix, installer, login state, and account data stay outside Git.

## Cloud drive design

Google Drive and Proton Drive are both approved as rclone FUSE mounts. They are
on-demand filesystems, not promises that the complete remote is available
offline.

| Remote | Mount | Data cache limit | Directory policy |
| --- | --- | --- | --- |
| Google Drive | `~/Cloud/GoogleDrive` | 50 GiB | long directory cache with polling |
| Proton Drive | `~/Cloud/ProtonDrive` | 50 GiB | short directory cache, polling off |

Both use `--vfs-cache-mode full`, a bounded write-back delay, a minimum-free-
space guard, private mount/cache permissions, clean lazy unmount on service
stop, and user systemd service restart on transient network failure. They do
not use `--allow-other`.

The Proton backend is explicitly experimental because Proton publishes no
supported Linux Drive application or public Drive API. Its backend metadata
caching is disabled for the VFS mount, as rclone recommends, so changes from
other clients are less likely to remain hidden. Concurrent edits of the same
Proton Drive file from multiple clients are outside the safety contract.

Account onboarding is performed by an interactive helper. The rclone config
is encrypted, stored with mode `0600`, and unlocked from GNOME Keyring by a
small service wrapper; its password is never placed in a unit file or Git.
The decrypted VFS cache is protected by the laptop's existing LUKS volume and
mode `0700`, but remains plaintext while the system is unlocked.

Thunar receives bookmarks for both mounts. Postflight distinguishes
"not onboarded" from a configured mount failure and never treats missing
account tokens as repository drift.

## Mail design

Install official Arch Thunderbird and an audited local package made from
Proton's official `https://proton.me/download/bridge/PKGBUILD`. Do not install
the AUR `protonmail-bridge-free` variant: it carries third-party patches meant
to bypass plan checks, while this user has a paid Bridge-capable plan.

The local Proton package pins the reviewed upstream version, official package
URL, and SHA-256. GNOME Keyring remains its Secret Service provider.

Bridge starts with the graphical session after account onboarding. Thunderbird
is routed to DOCUMENT workspace 3 and configured interactively using the
localhost IMAP/SMTP credentials generated by Bridge. Neither those credentials
nor the Thunderbird profile is committed. Acceptance covers send/receive,
folders, attachments, notifications, offline reading, keyring unlock after a
password login, and a clear warning after fingerprint-only login if the
keyring remains locked.

## Cloudflare One design

Install the approved AUR `cloudflare-warp-bin` package. It repackages the
vendor's current Ubuntu package, including:

- `warp-svc` system daemon;
- `warp-taskbar` Linux GUI and tray item;
- `warp-cli`; and
- `warp-diag`.

Enable `warp-svc.service` and the packaged `warp-taskbar.service`. Enrollment
uses the GUI's **Zero Trust security** flow and remains interactive. Team name,
identity-provider session, organization token, and daemon state are excluded
from Git.

Arch is not a Cloudflare-supported distribution, even though the vendor
provides a Linux GUI. Postflight reports package/service/registration state and
points to `warp-diag` without uploading diagnostics automatically.

Cloudflare owns its local DNS proxy while connected. The repository must not
hard-code WARP DNS addresses or replace NetworkManager's `/etc/resolv.conf`.
After enrollment, re-test WWAN DNS, Wi-Fi-to-WWAN fallback, Bottles component
downloads, both rclone mounts, Proton Bridge, Parsec, and browser access.

## Graphics design

Install official Arch GIMP 3 and the approved AUR `photogimp` package. That
package stages PhotoGIMP 3.1 globally and initializes an isolated
`~/.config/PhotoGIMP` profile on first `photogimp` launch. It does not replace
the user's ordinary GIMP profile.

The Dock launches `photogimp`, not raw `gimp`. Acceptance covers the
Photoshop-like single-window layout, shortcuts, bracket brush resizing,
Wayland scaling, Korean text input, file association behavior, and clean
launch of unmodified GIMP as a rollback path.

## Office and HWP design

### ONLYOFFICE

Install the reviewed AUR `onlyoffice-bin` package and its metric-compatible
font dependencies. It is the default for DOCX, XLSX, and PPTX. PDF remains
assigned according to the existing MIME policy unless the user later requests
ONLYOFFICE PDF editing by default.

### RHWP Desktop

RHWP Desktop is approved as an experimental native HWP/HWPX client. Version
1.2.2 is installed through a pinned local package using release digest:

`sha256:94295aa3fe74ee505d115936edd5b8df7e5293a205e244be4301a31725bfdeb7`

The upstream AppImage disables Chromium's sandbox because its FUSE-mounted
helper cannot be root-owned and setuid. The local package must not preserve
that unsafe default. It extracts the AppImage to a root-owned application
directory, installs the Chromium sandbox helper with the same protected mode
used by Arch Electron packages, sets
`RHWP_ENABLE_CHROMIUM_SANDBOX=1`, and enables native Wayland/Fcitx flags.

RHWP Desktop becomes the default for HWP and HWPX only after sample validation.
It always uses **Save As** during the initial rollout and never performs a
destructive compatibility test on an original document. Complex government
forms are compared with Hancom Docs before delivery. Current rhwp v0.7.x is a
rapidly improving read/write foundation, not yet Hancom-parity layout.

## Obsidian design

Obsidian is already installed and routed to DOCUMENT workspace 3. Keep the
application and its native Wayland flags, add it to the Dock, and do not create
a vault, choose a sync provider, or commit application state.

## Package ownership summary

| Owner | Additions |
| --- | --- |
| Official Arch manifests | Quickshell, GIMP, Thunderbird, rclone, FUSE support, office-compatible fonts, required validation utilities |
| Reviewed AUR allowlist | `cloudflare-warp-bin`, `onlyoffice-bin`, `photogimp` |
| Pinned local packages | Jetendard, official Proton Mail Bridge PKGBUILD, sandboxed RHWP Desktop |
| User-scoped Flatpak | Existing Bottles |
| chezmoi | Wallpaper, UI configuration, launch wrappers, user services, setup helpers, MIME/bookmark declarations |
| Ansible | System packages, SDDM theme/config, Cloudflare daemon enablement, root-owned package/runtime configuration |

## Secret and mutable-data boundary

The following must remain ignored and unmanaged:

- rclone remote tokens, config password, and plaintext VFS cache;
- Proton Bridge account, generated IMAP/SMTP password, and message cache;
- Thunderbird and Obsidian profiles;
- Cloudflare organization enrollment and daemon state;
- Bottles prefixes, KakaoTalk installer/login/cache;
- GIMP/PhotoGIMP user edits after initial profile creation;
- Office recent files and document data; and
- RHWP recent files and edited documents.

## Implementation sequence and commit boundaries

Each numbered item is an independently recoverable Conventional Commit. Do
not combine all work at the end of a session.

1. `feat(packages): add desktop expansion dependencies`
2. `feat(fonts): package and apply Jetendard globally`
3. `feat(theme): add cyberpunk wallpaper and desktop surfaces`
4. `feat(dock): add Quickshell dock and minimized window state`
5. `feat(hyprland): add titlebar window controls`
6. `fix(hidpi): move supported desktop apps to native Wayland`
7. `feat(cloud): add encrypted rclone mount workflow`
8. `feat(mail): add Thunderbird and official Proton Bridge`
9. `feat(network): add Cloudflare One client integration`
10. `feat(office): add ONLYOFFICE and sandboxed RHWP Desktop`
11. `feat(graphics): add GIMP and isolated PhotoGIMP profile`
12. `fix(kakaotalk): add Bottles connectivity and onboarding checks`
13. `test(workstation): validate expanded desktop workflow`

Interactive enrollment can happen between commits without committing the
resulting account state.

## Acceptance matrix

| Area | Required result |
| --- | --- |
| Theme | Same managed wallpaper on both outputs; coherent bar, lock, launcher, notifications, Dock, titlebar, and login palette |
| Dock | Hidden by default on both outputs; bottom-edge reveal; leave-to-hide; approved click behavior; crash recovery for minimized clients |
| Window controls | Close, minimize, maximize/restore, and true fullscreen work for tiled and floating clients without duplicate titlebars |
| Fonts | Jetendard wins global sans/mono matching; Korean, Nerd Font, emoji, and office fallbacks render correctly |
| Electron HiDPI | Discord and Slack report `xwayland=false` and match Chrome/Obsidian sizing at scale 1.5 |
| Parsec | Remains XWayland, sharp, functional, and intentionally small in its management UI |
| Fcitx | Physical Right Alt immediately toggles Korean/English in native Wayland, Electron, and KakaoTalk |
| Drives | Both mounts survive reconnect/relogin, enforce 50 GiB caches, perform create/read/rename/delete tests, and expose no secret in Git |
| Mail | Bridge and Thunderbird send/receive through localhost with keyring-backed secrets and no committed profile |
| Cloudflare | GUI/tray visible, organization registered, daemon healthy, DNS and WWAN fallback retested |
| Office | ONLYOFFICE opens representative Microsoft files with acceptable layout; RHWP edits copies and round-trips selected HWP/HWPX samples |
| Graphics | PhotoGIMP profile and shortcuts work while unmodified GIMP remains available |
| KakaoTalk | Bottle exists; chat, Hangul, clipboard, files, tray, and notifications pass |
| Obsidian | App launches on DOCUMENT workspace 3 without creating a vault |

The final implementation pass runs repository validation, shell tests,
Ansible syntax/check mode where safe, chezmoi diff inspection, Hyprland config
validation, user/system unit checks, and manual visual/interactive acceptance.

## Upstream references

- [Jetendard](https://github.com/kuskhan/jetendard)
- [Hyprland official plugins](https://github.com/hyprwm/hyprland-plugins)
- [rclone Google Drive](https://rclone.org/drive/)
- [rclone Proton Drive](https://rclone.org/protondrive/)
- [Proton Mail Bridge PKGBUILD instructions](https://proton.me/support/install-bridge-linux-pkgbuild-file)
- [Cloudflare One Linux client](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/)
- [RHWP Desktop](https://github.com/runableapp/rhwp-desktop)
- [rhwp](https://github.com/edwardkim/rhwp)
- [PhotoGIMP](https://github.com/Diolinux/PhotoGIMP)
