#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
profile=${1:-$(hostnamectl --static 2>/dev/null || hostname)}
output="$repo_root/state/$profile"
observed_config="$output/observed-system-config"
observed_user_drafts="$output/observed-user-drafts"

mkdir -p "$output" "$observed_config" "$observed_user_drafts"

date --iso-8601=seconds >"$output/captured-at.txt"
hostnamectl 2>&1 | sed -E '/Machine ID:|Boot ID:/d' >"$output/hostnamectl.txt" || true
uname -a >"$output/uname.txt"

pacman -Qqen | sort -u >"$output/native-explicit.txt"
pacman -Qqem | sort -u >"$output/foreign-explicit.txt"
pacman -Q | sort >"$output/packages.lock"
pacman -Qdtq 2>/dev/null | sort -u >"$output/orphans.txt" || true
comm -13 \
  <(pacman -Qqdt 2>/dev/null | sort) \
  <(pacman -Qqdtt 2>/dev/null | sort) \
  >"$output/optional-deps.txt" || true

systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null |
  awk '{print $1}' | sort -u >"$output/system-units-enabled.txt"
systemctl --user list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null |
  awk '{print $1}' | sort -u >"$output/user-units-enabled.txt"
systemctl --failed --no-legend --no-pager >"$output/system-units-failed.txt" 2>&1 || true
systemctl --user --failed --no-legend --no-pager >"$output/user-units-failed.txt" 2>&1 || true

env LC_ALL=C pacman -Qii 2>/dev/null |
  awk '/\[modified\]/ {print $(NF - 1)}' |
  sort -u >"$output/modified-package-configs.txt"

{
  echo "user=$(id -un)"
  echo "uid=$(id -u)"
  echo "groups=$(id -Gn)"
  echo "shell=$(getent passwd "$(id -un)" | cut -d: -f7)"
  echo "timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  echo "locale=$(localectl show -p Locale --value 2>/dev/null || true)"
  echo "keymap=$(localectl show -p Keymap --value 2>/dev/null || true)"
  echo "session_type=${XDG_SESSION_TYPE:-unknown}"
  echo "desktop=${XDG_CURRENT_DESKTOP:-unknown}"
} >"$output/system-summary.txt"

{
  echo "[findmnt]"
  findmnt --real -o TARGET,SOURCE,FSTYPE,OPTIONS
  echo
  echo "[lsblk]"
  lsblk -o NAME,TYPE,FSTYPE,FSVER,LABEL,UUID,PARTUUID,SIZE,MOUNTPOINTS,MODEL
} >"$output/filesystems.txt"

{
  echo "[lscpu]"
  lscpu
  echo
  echo "[lspci]"
  lspci -nnk
} >"$output/hardware.txt"

{
  echo "[bootctl]"
  bootctl status --no-pager 2>&1 || true
  echo
  echo "[sbctl]"
  sbctl status 2>&1 || true
  echo
  echo "[kernel command line]"
  cat /proc/cmdline
} >"$output/boot.txt"

{
  echo "[mise]"
  mise ls 2>/dev/null || true
  echo
  echo "[rustup toolchains]"
  rustup toolchain list 2>/dev/null || true
  echo
  echo "[rustup components]"
  rustup component list --installed 2>/dev/null || true
  echo
  echo "[cargo installs]"
  cargo install --list 2>/dev/null || true
  echo
  echo "[flatpak applications]"
  flatpak list --app --columns=application 2>/dev/null || true
  echo
  echo "[podman containers]"
  podman ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true
  echo
  echo "[podman images]"
  podman images --format '{{.Repository}}:{{.Tag}}\t{{.ID}}' 2>/dev/null || true
} >"$output/user-package-managers.txt"

if command -v dconf >/dev/null 2>&1; then
  dconf dump /org/gnome/desktop/interface/ >"$output/dconf-interface.ini" 2>/dev/null || true
fi

if command -v hyprctl >/dev/null 2>&1; then
  {
    echo "[system info]"
    hyprctl systeminfo 2>/dev/null | grep -E '^(Tag|Version|configProvider):' || true
    echo
    echo "[general:gaps_out]"
    hyprctl getoption general:gaps_out 2>/dev/null || true
    echo
    echo "[input:repeat_rate]"
    hyprctl getoption input:repeat_rate 2>/dev/null || true
    echo
    echo "[misc:disable_hyprland_logo]"
    hyprctl getoption misc:disable_hyprland_logo 2>/dev/null || true
  } >"$output/hyprland-active.txt"
fi

safe_system_files=(
  /etc/hostname
  /etc/hosts
  /etc/fstab
  /etc/locale.conf
  /etc/vconsole.conf
  /etc/locale.gen
  /etc/crypttab.initramfs
  /etc/kernel/cmdline
  /etc/mkinitcpio.conf
  /etc/mkinitcpio.d/linux.preset
  /etc/mkinitcpio.d/linux-lts.preset
  /etc/systemd/zram-generator.conf
  /etc/conf.d/snapper
  /etc/conf.d/pacman-contrib
  /etc/pacman.conf
  /etc/pacman.d/mirrorlist
  /etc/environment
  /etc/shells
  /etc/subuid
  /etc/subgid
)

: >"$output/system-config-metadata.txt"
for source_file in "${safe_system_files[@]}"; do
  if [[ -r $source_file && -f $source_file ]]; then
    destination="$observed_config$source_file"
    mkdir -p "$(dirname -- "$destination")"
    cp --dereference -- "$source_file" "$destination"
    stat -c '%a %U:%G %s %n' "$source_file" >>"$output/system-config-metadata.txt"
  fi
done

(
  cd "$observed_config"
  find . -type f -print0 |
    sort -z |
    xargs -0r sha256sum
) >"$output/system-config-checksums.txt"

# These files exist in the live home but are not loaded by the active
# Hyprland Lua provider. personal.lua also contains invalid standard Lua, so
# they are retained as evidence rather than desired chezmoi state.
for user_draft in \
  "$HOME/.config/hyprland.lua" \
  "$HOME/.config/hypr/personal.lua"; do
  if [[ -r $user_draft && -f $user_draft ]]; then
    destination="$observed_user_drafts${user_draft#"$HOME"}"
    mkdir -p "$(dirname -- "$destination")"
    cp --dereference -- "$user_draft" "$destination"
  fi
done

{
  for protected_file in /etc/crypttab /etc/snapper/configs/root; do
    if [[ -e $protected_file && ! -r $protected_file ]]; then
      echo "$protected_file: exists but was not readable without interactive sudo"
    fi
  done
} >"$output/unreadable-settings.txt"

echo "Captured observed state in $output"
