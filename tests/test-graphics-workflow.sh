#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_graphics-workflow-check
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fake_bin=$test_root/bin
fake_share=$test_root/share
fake_home=$test_root/home
mkdir -p -- \
  "$fake_bin" \
  "$fake_share/applications" \
  "$fake_home/.config/GIMP" \
  "$fake_home/.config/PhotoGIMP"

cat >"$fake_bin/gimp" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/photogimp" <<'EOF'
#!/usr/bin/env bash
PGDIR="${XDG_CONFIG_HOME:-$HOME/.config}/PhotoGIMP"
export GIMP3_DIRECTORY="$PGDIR"
exec gimp "$@"
EOF
cat >"$fake_bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -Q ]]; then
  exit 0
fi
if [[ ${1:-} == -Qoq ]]; then
  case ${2##*/} in
    gimp) printf 'gimp\n' ;;
    photogimp) printf 'photogimp\n' ;;
    *) exit 1 ;;
  esac
fi
EOF
cat >"$fake_bin/fcitx5-remote" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '[{"class":"org.gimp.GIMP","initialClass":"org.gimp.GIMP","xwayland":%s}]\n' \
  "${FAKE_XWAYLAND:-false}"
EOF
cat >"$fake_bin/xdg-mime" <<'EOF'
#!/usr/bin/env bash
printf 'org.gimp.GIMP.desktop\n'
EOF
cat >"$fake_bin/uwsm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_UWSM_LOG:?}"
EOF
chmod +x "$fake_bin/gimp" "$fake_bin/photogimp" "$fake_bin/pacman" \
  "$fake_bin/fcitx5-remote" "$fake_bin/hyprctl" "$fake_bin/uwsm" \
  "$fake_bin/xdg-mime"

cat >"$fake_share/applications/photogimp.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PhotoGIMP
Exec=photogimp %U
TryExec=photogimp
EOF
cat >"$fake_share/applications/gimp.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=GIMP
Exec=gimp-3.2 %U
EOF
cat >"$fake_home/.config/PhotoGIMP/shortcutsrc" <<'EOF'
(action "tools-size-decrease" "bracketleft")
(action "tools-size-increase" "bracketright")
EOF

snapshot_before=$(
  find "$fake_home" -type f -printf '%P %s %T@\n' | sort
)

success_output=$test_root/success.out
env \
  PATH="$fake_bin:/usr/bin" \
  HOME="$fake_home" \
  XDG_CONFIG_HOME="$fake_home/.config" \
  XDG_DATA_HOME="$fake_home/.local/share" \
  XDG_DATA_DIRS="$fake_share" \
  WAYLAND_DISPLAY=wayland-test \
  bash "$helper" --status >"$success_output" 2>&1

grep -Fq 'raw GIMP and PhotoGIMP use distinct launchers' "$success_output"
grep -Fq 'PhotoGIMP profile contains bracket brush-size shortcuts' "$success_output"
grep -Fq 'all running GIMP clients are native Wayland (1)' "$success_output"

snapshot_after=$(
  find "$fake_home" -type f -printf '%P %s %T@\n' | sort
)
[[ $snapshot_before == "$snapshot_after" ]] || {
  printf 'Status mode changed user profile state.\n' >&2
  exit 1
}

xwayland_output=$test_root/xwayland.out
if env \
  PATH="$fake_bin:/usr/bin" \
  HOME="$fake_home" \
  XDG_CONFIG_HOME="$fake_home/.config" \
  XDG_DATA_HOME="$fake_home/.local/share" \
  XDG_DATA_DIRS="$fake_share" \
  WAYLAND_DISPLAY=wayland-test \
  FAKE_XWAYLAND=true \
  bash "$helper" --status >"$xwayland_output" 2>&1; then
  printf 'XWayland GIMP unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq '1 of 1 running GIMP clients use XWayland' "$xwayland_output"

rm -rf -- "$fake_home/.config/PhotoGIMP"
ln -s -- GIMP "$fake_home/.config/PhotoGIMP"
shared_profile_output=$test_root/shared-profile.out
if env \
  PATH="$fake_bin:/usr/bin" \
  HOME="$fake_home" \
  XDG_CONFIG_HOME="$fake_home/.config" \
  XDG_DATA_HOME="$fake_home/.local/share" \
  XDG_DATA_DIRS="$fake_share" \
  WAYLAND_DISPLAY=wayland-test \
  bash "$helper" --status >"$shared_profile_output" 2>&1; then
  printf 'Shared GIMP profile unexpectedly passed.\n' >&2
  exit 1
fi
grep -Fq 'PhotoGIMP and raw GIMP resolve to the same profile path' \
  "$shared_profile_output"

rm -- "$fake_home/.config/PhotoGIMP"
mkdir -- "$fake_home/.config/PhotoGIMP"
cat >"$fake_home/.config/PhotoGIMP/shortcutsrc" <<'EOF'
(action "tools-size-decrease" "bracketleft")
(action "tools-size-increase" "bracketright")
EOF

smoke_output=$test_root/smoke.out
uwsm_log=$test_root/uwsm.log
printf -v smoke_command \
  'env PATH=%q HOME=%q XDG_CONFIG_HOME=%q XDG_DATA_HOME=%q XDG_DATA_DIRS=%q WAYLAND_DISPLAY=%q FAKE_UWSM_LOG=%q bash %q --smoke' \
  "$fake_bin:/usr/bin" \
  "$fake_home" \
  "$fake_home/.config" \
  "$fake_home/.local/share" \
  "$fake_share" \
  wayland-test \
  "$uwsm_log" \
  "$helper"
{
  printf 'y\n'
  sleep 0.1
  printf 'y\n'
  sleep 0.1
  printf 'y\n'
} | script --quiet --return --command "$smoke_command" /dev/null \
  >"$smoke_output" 2>&1
for _ in {1..20}; do
  [[ -f $uwsm_log && $(wc -l <"$uwsm_log") -ge 2 ]] && break
  sleep 0.05
done
if ! grep -Fxq 'app -- photogimp --new-instance' "$uwsm_log" ||
  ! grep -Fxq 'app -- gimp --new-instance' "$uwsm_log" ||
  ! grep -Fq 'interactive PhotoGIMP acceptance was confirmed' "$smoke_output" ||
  ! grep -Fq 'interactive raw GIMP rollback was confirmed' "$smoke_output"; then
  printf 'Interactive graphics smoke flow did not complete.\n' >&2
  sed -n '1,260p' "$smoke_output" >&2
  sed -n '1,80p' "$uwsm_log" >&2
  exit 1
fi

printf 'Graphics workflow tests passed.\n'
