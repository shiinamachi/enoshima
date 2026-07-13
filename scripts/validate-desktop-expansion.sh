#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

echo "==> Running repository validation"
./scripts/validate.sh

echo "==> Running desktop expansion regression tests"
for test_script in \
  tests/test-cyberdock-state.sh \
  tests/test-hyprbars-green.sh \
  tests/test-desktop-scaling-status.sh \
  tests/test-graphics-workflow.sh \
  tests/test-kakaotalk-connectivity.sh; do
  "$repo_root/$test_script"
done

echo "==> Checking desktop expansion shell sources"
mapfile -t expansion_shell_sources < <(
  printf '%s\n' \
    home/dot_local/bin/executable_cloudflare-one-setup \
    home/dot_local/bin/executable_cloudflare-one-status \
    home/dot_local/bin/executable_cyberdock-activate \
    home/dot_local/bin/executable_cyberdock-minimize \
    home/dot_local/bin/executable_cyberdock-recover \
    home/dot_local/bin/executable_cyberdock-state \
    home/dot_local/bin/executable_desktop-scaling-status \
    home/dot_local/bin/executable_discord-wayland \
    home/dot_local/bin/executable_graphics-workflow-check \
    home/dot_local/bin/executable_hyprbars-green \
    home/dot_local/bin/executable_hyprbars-setup \
    home/dot_local/bin/executable_kakaotalk-connectivity-check \
    home/dot_local/bin/executable_kakaotalk-setup \
    home/dot_local/bin/executable_protonmail-bridge-setup \
    home/dot_local/bin/executable_protonmail-bridge-status \
    home/dot_local/bin/executable_rclone-cloud-mount \
    home/dot_local/bin/executable_rclone-cloud-password \
    home/dot_local/bin/executable_rclone-cloud-setup \
    home/dot_local/bin/executable_rhwp-enable-defaults \
    home/dot_local/bin/executable_slack-wayland \
    home/dot_local/bin/executable_thunderbird-wayland \
    home/run_after_30-enable-custom-user-services.sh.tmpl \
    home/run_onchange_after_40-add-cloud-bookmarks.sh.tmpl \
    packages/local/rhwp-desktop/rhwp-desktop.sh \
    scripts/postflight-desktop-expansion.sh \
    scripts/validate-desktop-expansion.sh
)

for source_file in "${expansion_shell_sources[@]}"; do
  bash -n "$source_file"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${expansion_shell_sources[@]}"
fi

echo "==> Checking QML, desktop entries, and user units"
if command -v qmllint >/dev/null 2>&1; then
  qmllint home/dot_config/quickshell/cyberdock/shell.qml
fi
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate \
    home/dot_config/autostart/discord.desktop \
    home/dot_config/autostart/slack.desktop \
    home/dot_local/share/applications/discord.desktop \
    home/dot_local/share/applications/org.mozilla.Thunderbird.desktop \
    home/dot_local/share/applications/slack.desktop \
    packages/local/rhwp-desktop/rhwp-desktop.desktop
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  unit_dir=$(mktemp -d)
  cleanup_units() {
    rm -rf -- "$unit_dir"
  }
  trap cleanup_units EXIT

  for unit in \
    home/dot_config/systemd/user/cyberdock.service \
    home/dot_config/systemd/user/hyprbars-check.service \
    home/dot_config/systemd/user/protonmail-bridge.service \
    home/dot_config/systemd/user/rclone-google-drive.service \
    home/dot_config/systemd/user/rclone-proton-drive.service; do
    # Verify unit structure without requiring the chezmoi targets or optional
    # account applications to already be installed on the validation host.
    sed -E \
      's#^(Exec(Start|Stop)(Pre|Post)?=).*#\1/usr/bin/true#' \
      "$unit" >"$unit_dir/$(basename -- "$unit")"
  done
  systemd-analyze --user verify "$unit_dir"/*.service
  cleanup_units
  trap - EXIT
fi

echo "==> Checking package and security invariants"
for package in \
  fuse3 gimp libsecret quickshell rclone thunderbird \
  ttf-caladea ttf-carlito ttf-liberation wev; do
  grep -Fxq -- "$package" packages/native.txt
done
for package in cloudflare-warp-bin onlyoffice-bin photogimp; do
  grep -Fxq -- "$package" packages/aur.txt
done
for package in protonmail-bridge rhwp-desktop ttf-jetendard; do
  test -f "packages/local/$package/PKGBUILD"
done

wallpaper_sha=34053ea6a5b8a0b747261755a964917ffa14900ac85637bda346df5cb2bf64e6
printf '%s  %s\n' \
  "$wallpaper_sha" \
  home/dot_local/share/backgrounds/cyberpunk-city.png | sha256sum --check --status

grep -Fq 'sha256:94295aa3fe74ee505d115936edd5b8df7e5293a205e244be4301a31725bfdeb7' \
  docs/DESKTOP-EXPANSION.md
grep -Fq "'94295aa3fe74ee505d115936edd5b8df7e5293a205e244be4301a31725bfdeb7'" \
  packages/local/rhwp-desktop/PKGBUILD
grep -Fq 'chmod 4755 ' packages/local/rhwp-desktop/PKGBUILD
grep -Fq 'opt/rhwp-desktop/chrome-sandbox' \
  packages/local/rhwp-desktop/PKGBUILD
if awk '!/^[[:space:]]*#/' packages/local/rhwp-desktop/rhwp-desktop.sh |
  grep -Fq -- '--no-sandbox'; then
  echo "RHWP launcher contains an unsafe sandbox bypass." >&2
  exit 1
fi

for required_flag in \
  '--vfs-cache-mode full' \
  '--vfs-cache-max-size 50Gi' \
  '--vfs-write-back 15m' \
  '--vfs-cache-min-free-space 5Gi' \
  '--protondrive-enable-caching=false'; do
  grep -Fq -- "$required_flag" home/dot_local/bin/executable_rclone-cloud-mount
done
if grep -Fq -- '--allow-other' home/dot_local/bin/executable_rclone-cloud-mount; then
  echo "rclone mount unexpectedly enables cross-user access." >&2
  exit 1
fi

if rg -n \
  '(1\.1\.1\.1|1\.0\.0\.1|2606:4700:4700|2606:4700:4700::1111)' \
  ansible/roles/desktop_expansion/tasks/cloudflare.yml \
  home/dot_local/bin/executable_cloudflare-one-{setup,status}; then
  echo "Cloudflare integration hard-codes a DNS address." >&2
  exit 1
fi

if git ls-files | rg -q \
  '(^|/)(rclone\.conf|prefs\.js|key4\.db|logins\.json|drive_c|Cookies)(/|$)'; then
  echo "A mutable account/profile artifact is tracked by Git." >&2
  exit 1
fi

grep -Fq 'cyberdock.service' home/run_after_30-enable-custom-user-services.sh.tmpl
grep -Fq 'hyprbars-check.service' home/run_after_30-enable-custom-user-services.sh.tmpl
grep -Fq 'thunderbird-wayland' home/dot_config/quickshell/cyberdock/shell.qml
grep -Fq 'photogimp' home/dot_config/quickshell/cyberdock/shell.qml
grep -Fq 'onlyoffice-desktopeditors.desktop' home/dot_config/mimeapps.list

git diff --check
echo "Desktop expansion validation completed successfully."
