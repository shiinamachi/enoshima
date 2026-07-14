# Desktop expansion design

## Status

Approved and implemented in the repository, with the Cyberpunk Library visual
refinement completed on 2026-07-14. Declarative package, service, desktop, and
validation state is complete. This host opts into the managed SDDM theme, which
is installed by the complete bootstrap rather than by a preview-time partial
upgrade. Account enrollment and the visual/interactive acceptance items remain
explicit manual gates documented in `DESKTOP-EXPANSION-OPERATIONS.md`; their
mutable results are intentionally not committed.

## Goals

1. Turn the current Hyprland session into a coherent cyberpunk desktop based
   on the user-supplied wallpaper.
2. Add a macOS-like dock and usable close, minimize, and fullscreen controls
   while preserving application-native titlebars.
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

The original user-provided source remains recoverable without generative
modification at:

`home/dot_local/share/backgrounds/cyberpunk-city.png`

Two display-native JPEGs are deterministically derived from that source. The
16:9 asset preserves the full composition, while the 16:10 asset uses a
left-anchored horizontal crop so the library facade and character remain intact:

- `cyberpunk-library-16x9.jpg`: 3840x2160, SHA-256
  `5b96bdca2bfc912164e2dec3ec5aec6f360e3c7ba6dabc7136afe39b618ce1cc`
- `cyberpunk-library-16x10.jpg`: 2880x1800, SHA-256
  `784c66002966e57a2ab0e5ae2413c3faee7b93a8c656d203899d41b25faffafb`

The visual palette is sampled conceptually from the asset:

| Role | Color |
| --- | --- |
| Ink | `#050623` |
| Deep | `#0a0c3e` |
| Surface | `#161151` |
| Surface high | `#1a1472` |
| Neon cyan | `#62d8ff` |
| Electric blue | `#6d8cff` |
| Neon violet | `#9a5cff` |
| Neon magenta | `#e56bff` |
| Pink | `#ff72bd` |
| Primary text | `#f2ecff` |
| Muted text | `#c9bfe8` |
| Warning | `#ffb86b` |
| Critical | `#ff5d8f` |
| Success | `#77e0c6` |

The following surfaces share these tokens instead of defining unrelated
themes: Hyprland borders, Hyprpaper, Hyprlock, SDDM, Waybar, the Quickshell
Cyberdock/CyberLauncher/CyberOSD shell, SwayNC, GTK 3/4 application surfaces,
Fcitx5 Classic UI, tooltips, and session controls.

### Wallpaper and lock/login screens

- Hyprpaper routes the 2880x1800 composition explicitly to `eDP-1` and uses the
  3840x2160 composition as the fallback for external and newly attached
  outputs. Both use `cover` behavior.
- Hyprlock mirrors that routing, applies brightness `0.62` with one restrained
  blur pass, and places the time, date, password/fingerprint status, and input
  field in a 600x360 lower-left authentication card. Success, failure, and
  lock-key states use distinct success, critical, and warning colors.
- SDDM receives a matching theme only after the session theme is validated.
  The theme must not alter the existing PAM and fingerprint authentication
  policy, and SDDM must retain a known-good fallback theme.
- Hyprland uses 7/14 pixel gaps, 12 pixel rounding, a calm cyan-violet active
  border, and an Intel iGPU-conscious blur ceiling of size 7 and two passes.
- Waybar remains at the top with the five purpose-led `DEV`, `WEB`, `DOCS`,
  `REMOTE`, and `MISC` workspaces; unused reserve workspaces are neither
  persistent nor displayed. It uses a 48 pixel surface, 14 pixel edge margins,
  a quiet centered date/time, and only notification, audio, network, Bluetooth,
  battery, and system-drawer entries on the right. Tray, backlight, power
  profile, WWAN, and the full date live in the drawer. Persistent chrome is
  opaque enough to remain readable without compositor blur.

### Shell and application surfaces

- Cyberdock renders on every monitor and remains visible during ordinary work,
  reserving a 74 pixel bottom work area so tiled clients never sit beneath it.
  It hides only for a true fullscreen client or while CyberLauncher is open;
  fullscreen keeps a 6 pixel reveal target and a visible resting indicator.
  The 58 pixel surface retains minimized-workspace recovery, a multi-window
  chooser, context menus, core pins, and dynamically discovered running apps.
- The repository-owned CyberLauncher replaces stock Hyprlauncher. `Super+Space`
  opens a fullscreen dim layer with a centered two-column surface: at most seven
  searchable desktop entries on the left, selected-app details and a real Open
  action on the right, and up to four quick apps. Search has immediate keyboard
  focus; Up/Down, Enter, and Escape work without a pointer; launches pass
  through `uwsm app`. The stock package is declared absent and convergence
  disables its stale user unit.
- CyberOSD is part of the same Quickshell process and semantic palette. Audio
  and brightness helpers send a short-lived, non-focusable bottom-center
  percentage display through Quickshell IPC instead of starting another daemon.
- SwayNC remains aligned below the upper-right Waybar edge. The control center
  is 460x850 pixels, preserves notification grouping and images, and uses a
  functional 3-by-2 quick-settings grid: Wi-Fi, Bluetooth, and Night Light are
  stateful toggles; Power opens Hyprshutdown, Audio opens Hyprpwcenter, and
  Display opens nwg-displays. Volume, brightness, DND, and an auto-hiding MPRIS
  widget remain below the grid.
- Hyprpm manages only the official `hyprfocus` plugin. Its brief six-percent
  focus flash supplements the native focus border without moving window
  geometry. The configuration detects both the Hyprland 0.55 schema and the
  newer input-aware schema, where pointer focus remains unanimated;
  reduced-motion profiles neutralize or disable the plugin accordingly. The
  retired `hyprbars` state is removed because compositor-owned
  titlebars duplicate GTK, Qt, and Electron client-side decorations.
- Ghostty uses the shared 16-color ANSI palette, `minimum-contrast = 4.5`, 94%
  opacity, and balanced 12x10 padding. Compositor blur remains authoritative.
- Zed retains its built-in One Dark syntax and Command Palette behavior while
  overriding only the editor background and seven accents.
- GTK 3, GTK 4, and dconf converge on `adw-gtk3-dark`, Papirus-Dark,
  Pretendard, `prefer-dark`, and managed semantic CSS for the shared navy,
  cyan, violet, and critical roles. UWSM and Hyprland export the
  `capitaine-cursors` cursor; the portal preference keeps the Hyprland backend
  with the GTK file chooser; and Fcitx5 Classic UI uses Pretendard, the
  Material DeepPurple theme, and fractional scaling. Quickshell uses
  Papirus-Dark and the same semantic colors.

## Font architecture

Pretendard is the global proportional UI and `sans-serif` default. Jetendard
remains the `monospace` default for terminals and code editors, where fixed
glyph widths and Nerd Font symbols are required. Serif documents continue to
use the existing serif fallback.

A reproducible local package combines the two reviewed families:

1. pin a reviewed `kuskhan/jetendard` commit and every upstream font input;
2. build and test the complete 16-variant Jetendard TTF family;
3. validate and install the nine pinned Pretendard 1.3.9 static TTF variants;
4. install both families below `/usr/share/fonts/TTF` through pacman; and
5. refresh fontconfig through the normal package hook.

A managed fontconfig rule puts `Pretendard` first for `sans-serif` and
`Jetendard` first for `monospace`. GTK/dconf, Qt-facing UI, Waybar, Hyprlock,
Quickshell, Zed UI, and SDDM explicitly request Pretendard. Ghostty,
Zed buffers/terminal, and other code surfaces explicitly retain Jetendard.
Noto CJK and emoji remain fallbacks. Carlito, Caladea, and Liberation remain
installed for metric-compatible Microsoft Office document rendering.

Acceptance checks include `fc-match sans-serif`, `fc-match monospace`, Korean
glyph width in terminal/editor output, Nerd Font icons, emoji fallback, and an
office document with explicit Calibri/Cambria-compatible fonts.

## Dock and window-state architecture

### Quickshell dock

The selected implementation is a repository-owned Quickshell shell, not
`nwg-dock-hyprland`. Quickshell is available as an official Arch package and
allows minimized-state behavior to be integrated with Hyprland IPC.

One dock instance is rendered on every connected monitor. Each instance:

- is persistent during normal windowed use;
- reserves a 74 pixel work area so tiled windows do not overlap it;
- hides while a true fullscreen client is active or CyberLauncher is open;
- exposes a six-pixel bottom-edge recovery target and resting indicator while
  hidden for fullscreen;
- shows the same core pinned applications and all other running/minimized
  applications;
  and
- switches to the owning monitor/workspace when a window on another output is
  selected.

The deliberately short pinned set, in order, is:

1. Ghostty
2. Files (Thunar)
3. Zed
4. Google Chrome
5. Applications (CyberLauncher)

Communication, office, graphics, and Wine applications are intentionally not
pinned merely because they are managed by this repository. They appear
dynamically while running, which keeps the Dock close to the concept density.
The Windows VM pin from the preliminary proposal remains removed because VM
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

### Native window decorations

Applications own their titlebars. GTK clients use their normal client-side
decorations, supported Electron clients explicitly enable Wayland window
decorations, and Ghostty uses its automatic native GTK decoration mode. A
compositor cannot reliably infer whether every toolkit has a complete native
titlebar, so no common fallback bar is overlaid on all windows.

Window management remains available independently of decorations: `Super+C`
closes, `Super+N` minimizes through Cyberdock, and `Super+F` toggles true
fullscreen.

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

Right Alt handling is converged in both native Wayland and XWayland state:

- XKB option `korean:ralt_hangul` maps physical Right Alt directly to
  `Hangul`;
- the KakaoTalk launcher reapplies that option to XWayland's independent
  keymap immediately before Wine starts;
- Fcitx5 listens for `Hangul` and `Ctrl+Space`;
- Right Alt is no longer available as an Alt modifier; and
- F9 remains the Hanja key.

KakaoTalk receives an app-specific Wine XIM `InputStyle=root`. Fcitx therefore
renders the in-progress composition and commits completed Hangul to KakaoTalk,
avoiding its delayed handling of Wine's callback preedit without changing the
preedit behavior of native applications.

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
4. retain X11/Wine, 144 DPI, `XMODIFIERS=@im=fcitx`, and the KakaoTalk-only
   root XIM input style;
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
not use `--allow-other`. The units explicitly keep `PrivateTmp=false`: systemd's
private temporary-directory isolation also creates a private mount namespace,
which prevents a desktop-visible FUSE mount and makes `fusermount3` fail with
`Operation not permitted`. Proton Drive uses a five-minute service retry delay
to avoid amplifying the experimental backend's rate limits.

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

Install the official Arch `thunderbird` and `protonmail-bridge` packages. The
latter depends on the split `protonmail-bridge-core` daemon package, so the
managed background unit starts `/usr/bin/protonmail-bridge-core` while account
onboarding uses the GUI launcher. Do not install the AUR
`protonmail-bridge-free` variant: it carries third-party patches meant to
bypass plan checks, while this user has a paid Bridge-capable plan. GNOME
Keyring remains the Bridge Secret Service provider.

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

The managed PhotoGIMP application entry launches `photogimp`, not raw `gimp`,
and appears in the Dock while running. Acceptance covers the
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
application and its native Wayland flags; it appears dynamically in the Dock
while running. Do not create a vault, choose a sync provider, or commit
application state.

## Package ownership summary

| Owner | Additions |
| --- | --- |
| Official Arch manifests | Quickshell, `adw-gtk-theme`, `capitaine-cursors`, `fcitx5-material-color`, Hyprpwcenter, nwg-displays, GIMP, Thunderbird, Proton Mail Bridge, rclone, FUSE support, office-compatible fonts, required validation utilities |
| Reviewed AUR allowlist | `cloudflare-warp-bin`, `onlyoffice-bin`, `photogimp` |
| Pinned local packages | Pretendard/Jetendard desktop fonts and sandboxed RHWP Desktop |
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
2. `feat(fonts): package and apply desktop font roles`
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
| Theme | Ratio-specific managed wallpapers on both outputs; coherent bar, lock, CyberLauncher, CyberOSD, notifications, Dock, GTK 3/4 apps, Fcitx5, cursor, terminal, editor, native app titlebars, and login palette |
| Shell | CyberLauncher has immediate search focus, keyboard selection/cancel, real desktop-entry launch actions, and a maximum seven-result hierarchy; volume and brightness helpers display CyberOSD without taking focus |
| Dock | Persistent and non-overlapping on both outputs during windowed use; hidden for launcher/true fullscreen; six-pixel fullscreen recovery; approved click behavior; crash recovery for minimized clients |
| Quick settings | SwayNC shows six functional actions in two rows; toggle state tracks Wi-Fi, Bluetooth, and Night Light; Power, Audio, and Display open their managed tools |
| Window controls | Close, minimize, and true fullscreen work for tiled and floating clients without compositor-owned duplicate titlebars |
| Fonts | Pretendard wins global sans matching, Jetendard wins mono matching, and Korean, Nerd Font, emoji, and office fallbacks render correctly |
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
- [Pretendard](https://github.com/orioncactus/pretendard)
- [Hyprland official plugins](https://github.com/hyprwm/hyprland-plugins)
- [rclone Google Drive](https://rclone.org/drive/)
- [rclone Proton Drive](https://rclone.org/protondrive/)
- [Arch Linux Proton Mail Bridge](https://archlinux.org/packages/extra/x86_64/protonmail-bridge/)
- [Cloudflare One Linux client](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/)
- [RHWP Desktop](https://github.com/runableapp/rhwp-desktop)
- [rhwp](https://github.com/edwardkim/rhwp)
- [PhotoGIMP](https://github.com/Diolinux/PhotoGIMP)
