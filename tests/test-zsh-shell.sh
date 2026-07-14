#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
zshrc="$repo_root/home/dot_zshrc"
fastfetch_config="$repo_root/home/dot_config/fastfetch/config.jsonc"

grep -Fxq 'fastfetch' "$repo_root/packages/native.txt"
grep -Fxq 'zsh' "$repo_root/packages/native.txt"
grep -Fxq 'oh-my-zsh-git' "$repo_root/packages/aur.txt"
grep -Fq 'target_user_shell: /bin/zsh' \
  "$repo_root/ansible/inventory/group_vars/all.yml"

grep -Fq 'export ZSH=/usr/share/oh-my-zsh' "$zshrc"
grep -Fq "zstyle ':omz:update' mode disabled" "$zshrc"
# This is a literal source-code invariant, not a command substitution here.
# shellcheck disable=SC2016
grep -Fq 'eval "$(/usr/bin/mise activate zsh)"' "$zshrc"
grep -Fq 'FASTFETCH_SHOWN' "$zshrc"

for environment_file in \
  "$repo_root/home/dot_zprofile" \
  "$repo_root/home/dot_config/uwsm/env"; do
  grep -Fq '.local/share/mise/shims' "$environment_file"
done

jq -e '
  .logo.type == "small" and
  .display.color.keys == "magenta" and
  ([.modules[] | objects | .type] |
    index("shell") != null and index("wm") != null and
    index("memory") != null and index("battery") != null)
' "$fastfetch_config" >/dev/null

if command -v zsh >/dev/null 2>&1; then
  for zsh_file in "$repo_root/home/dot_zprofile" "$zshrc"; do
    zsh -n "$zsh_file"
  done
fi
if command -v fastfetch >/dev/null 2>&1; then
  fastfetch --config "$fastfetch_config" --pipe >/dev/null
fi

printf 'PASS: Zsh, Oh My Zsh, fastfetch, and mise shell integration\n'
