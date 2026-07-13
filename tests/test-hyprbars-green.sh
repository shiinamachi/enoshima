#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
helper=$repo_root/home/dot_local/bin/executable_hyprbars-green
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

mkdir -p -- "$test_root/bin" "$test_root/runtime"

cat >"$test_root/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case ${1-} in
  activewindow)
    printf '{"address":"0xabc"}\n'
    ;;
  dispatch)
    printf '%s\n' "$*" >>"$HYPRCTL_LOG"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x -- "$test_root/bin/hyprctl"

export HYPRCTL_LOG=$test_root/hyprctl.log
export PATH=$test_root/bin:/usr/bin:/bin
export XDG_RUNTIME_DIR=$test_root/runtime

bash "$helper"
bash "$helper"

mapfile -t calls <"$HYPRCTL_LOG"
[[ ${#calls[@]} -eq 2 ]]
[[ ${calls[0]} == "dispatch fullscreen 1" ]]
[[ ${calls[1]} == "dispatch fullscreen 0" ]]
[[ ! -e $XDG_RUNTIME_DIR/hyprbars/green-click ]]

printf 'Hyprbars green-button tests passed.\n'
