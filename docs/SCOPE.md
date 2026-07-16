# Capture scope

## Included

- Explicit native pacman packages and selected optional dependencies
- AUR package bases plus an exact foreign-package observation
- Exact installed package/version lock
- Enabled system and user systemd units
- Hostname, locale, timezone, user groups and subordinate IDs
- pacman, mkinitcpio, systemd zram, kernel command line and UKI presets
- LUKS initramfs mapping metadata and Btrfs/ESP hardware facts
- Hyprland, Hypridle, Hyprlock, Hyprpaper, Waybar and Fcitx5 settings
- greetd, fallback SDDM, and sudo service-specific fingerprint PAM policy
- TLP profile policy, s2idle selection and NetworkManager WWAN fallback logic
- User-scoped Flathub/Bottles installation and KakaoTalk launch helpers
- Pinned local PKGBUILDs for the Lenovo Gen 13 SAR omission and Wine tray bridge
- XDG default applications and user-directory settings
- Git identity
- Global mise runtime definitions and their one-shot installation workflow
- Dconf GNOME interface cursor settings

## Excluded

- `/etc/shadow`, `/etc/gshadow`, private keys and password hashes
- Secure Boot private keys and TPM-sealed key material
- `/etc/NetworkManager/system-connections` and Wi-Fi credentials
- SSH host keys and user private keys
- Browser profiles, cookies, extensions, history and logins
- KakaoTalk bottles, Wine prefixes, KakaoTalk login state and downloaded installer
- Flatpak application data and proprietary application update payloads
- Codex/ChatGPT application profiles, sessions and authentication
- GNOME Keyring contents and Secret Service credentials
- Shell/editor histories, caches and recently used files
- Documents, source repositories, downloads, media and project data
- Podman images/containers and other reproducible runtime artifacts
- Generated certificate stores, fontconfig links and package defaults
- Pacman keyring and mirror availability as desired state

Unused Hyprland Lua drafts are retained in observed state but excluded from
chezmoi desired state.

## Root-readable files not captured

- `/etc/crypttab`: the active initramfs mapping is represented instead by the
  readable `/etc/crypttab.initramfs` entry.
- `/etc/snapper/configs/root`: Ansible creates the distribution default when it
  is absent, but does not claim to reproduce unreadable tuning.
