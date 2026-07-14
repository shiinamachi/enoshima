#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
zshrc="$repo_root/home/dot_zshrc"
fastfetch_config="$repo_root/home/dot_config/fastfetch/config.jsonc"
starship_config="$repo_root/home/dot_config/starship.toml"
plugin_root=${ZSH_PLUGIN_ROOT:-/usr/share/zsh/plugins}
startup_budget_ms=150

native_shell_packages=(
  bat
  eza
  fastfetch
  fd
  fzf
  starship
  zoxide
  zsh
  zsh-autosuggestions
  zsh-completions
  zsh-syntax-highlighting
)
for package in "${native_shell_packages[@]}"; do
  grep -Fxq "$package" "$repo_root/packages/native.txt"
done
for package in fzf-tab oh-my-zsh-git; do
  grep -Fxq "$package" "$repo_root/packages/aur.txt"
done
grep -Fq 'target_user_shell: /bin/zsh' \
  "$repo_root/ansible/inventory/group_vars/all.yml"

grep -Fq 'export ZSH=/usr/share/oh-my-zsh' "$zshrc"
# Literal managed source text; no expansion is intended here.
# shellcheck disable=SC2016
grep -Fq 'export ZSH_CUSTOM="${ZSH_CUSTOM:-${XDG_CONFIG_HOME:-$HOME/.config}/oh-my-zsh}"' "$zshrc"
grep -Fq "zstyle ':omz:update' mode disabled" "$zshrc"
grep -Fq "zstyle ':completion:*' menu no" "$zshrc"
grep -Fq "zstyle ':fzf-tab:*' continuous-trigger '/'" "$zshrc"
grep -Fq 'ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=120' "$zshrc"
grep -Fq "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)" "$zshrc"
grep -Fq 'FASTFETCH_SHOWN' "$zshrc"

expected_plugins=(
  git
  fzf
  fzf-tab
  zoxide
  eza
  direnv
  mise
  sudo
  colored-man-pages
  extract
  history-substring-search
  aliases
  starship
  zsh-autosuggestions
  zsh-syntax-highlighting
)
mapfile -t actual_plugins < <(
  awk '
    /^plugins=\(/ { in_plugins = 1; next }
    in_plugins && /^\)/ { exit }
    in_plugins {
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]#].*$/, "")
      if (length > 0) print
    }
  ' "$zshrc"
)
[[ ${actual_plugins[*]} == "${expected_plugins[*]}" ]]
[[ ${actual_plugins[${#actual_plugins[@]} - 1]} == zsh-syntax-highlighting ]]
# Literal managed Zsh source text; no Bash expansion is intended here.
# shellcheck disable=SC2016
grep -Fq 'plugins=(${plugins:#fzf-tab})' "$zshrc"
# shellcheck disable=SC2016
grep -Fq 'plugins=(${plugins:#zoxide})' "$zshrc"
# shellcheck disable=SC2016
grep -Fq 'plugins=(${plugins:#eza})' "$zshrc"
# shellcheck disable=SC2016
grep -Fq 'plugins=(${plugins:#starship})' "$zshrc"
# shellcheck disable=SC2016
grep -Fq 'plugins=(${plugins:#zsh-autosuggestions})' "$zshrc"
# shellcheck disable=SC2016
grep -Fq 'plugins=(${plugins:#zsh-syntax-highlighting})' "$zshrc"
if printf '%s\n' "${actual_plugins[@]}" | grep -Fxq zsh-completions; then
  echo 'zsh-completions must use the packaged site-functions directory' >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*(autoload[^#]*compinit|compinit)([[:space:]]|$)' "$zshrc"; then
  echo 'Oh My Zsh must remain the only compinit owner' >&2
  exit 1
fi

declare -A wrapper_sources=(
  ["fzf-tab"]='fzf-tab/fzf-tab.plugin.zsh'
  ["zsh-autosuggestions"]='zsh-autosuggestions/zsh-autosuggestions.plugin.zsh'
  ["zsh-syntax-highlighting"]='zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh'
)
for plugin in "${!wrapper_sources[@]}"; do
  wrapper="$repo_root/home/dot_config/oh-my-zsh/plugins/$plugin/$plugin.plugin.zsh"
  test -f "$wrapper"
  # Literal managed source text; no expansion is intended here.
  # shellcheck disable=SC2016
  grep -Fq '${ZSH_PLUGIN_ROOT:-/usr/share/zsh/plugins}' "$wrapper"
  grep -Fq "${wrapper_sources[$plugin]}" "$wrapper"
done

grep -Fq 'palette = "cyberpunk_library"' "$starship_config"
grep -Fq 'scan_timeout = 10' "$starship_config"
grep -Fq 'command_timeout = 300' "$starship_config"
grep -Fq 'follow_symlinks = false' "$starship_config"
grep -Fq '[╭─](bold focus)' "$starship_config"
# Literal Starship format variable; no shell expansion is intended here.
# shellcheck disable=SC2016
grep -Fq '[╰─](bold focus)$character' "$starship_config"
grep -Fq '[mise]' "$starship_config"
grep -Fq 'font-family = JetBrainsMono Nerd Font Mono' \
  "$repo_root/home/dot_config/ghostty/config.ghostty"

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
  for zsh_file in \
    "$repo_root/home/dot_zprofile" \
    "$zshrc" \
    "$repo_root"/home/dot_config/oh-my-zsh/plugins/*/*.plugin.zsh; do
    zsh -n "$zsh_file"
  done
fi
if command -v fastfetch >/dev/null 2>&1; then
  fastfetch --config "$fastfetch_config" --pipe >/dev/null
fi
if command -v starship >/dev/null 2>&1; then
  STARSHIP_CONFIG="$starship_config" TERM=xterm-256color \
    starship prompt >/dev/null
fi

plugin_runtime_ready=true
for command_name in bat eza fd fzf mise starship zoxide; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    plugin_runtime_ready=false
  fi
done
for plugin_source in "${wrapper_sources[@]}"; do
  if [[ ! -r $plugin_root/$plugin_source ]]; then
    plugin_runtime_ready=false
  fi
done

test_zdotdir=$(mktemp -d)
trap 'rm -rf -- "$test_zdotdir"' EXIT
ln -s -- "$zshrc" "$test_zdotdir/.zshrc"

run_interactive_plugin_check() {
  # The single-quoted script must be evaluated by the child Zsh, not Bash.
  # shellcheck disable=SC2016
  env \
    FASTFETCH_SUPPRESS=1 \
    STARSHIP_CONFIG="$starship_config" \
    TERM=xterm-256color \
    XDG_CACHE_HOME="$test_zdotdir/cache" \
    XDG_STATE_HOME="$test_zdotdir/state" \
    ZDOTDIR="$test_zdotdir" \
    ZSH_CUSTOM="$repo_root/home/dot_config/oh-my-zsh" \
    ZSH_PLUGIN_ROOT="$plugin_root" \
    zsh -ic '
      [[ ${plugins[-1]} == zsh-syntax-highlighting ]] || exit 10
      (( $+functions[fzf-tab-complete] )) || exit 11
      (( $+functions[_zsh_autosuggest_start] )) || exit 12
      (( $+functions[_zsh_highlight] )) || exit 13
      (( $+functions[history-substring-search-up] )) || exit 14
      (( $+functions[__zoxide_z] )) || exit 15
      (( $+functions[als] )) || exit 16
      (( $+functions[mise] )) || exit 17
      [[ $STARSHIP_SHELL == zsh ]] || exit 18
      [[ $(bindkey "^I") == *fzf-tab-complete* ]] || exit 19
      [[ ${aliases[ls]} == eza* ]] || exit 20
    ' </dev/null >/dev/null 2>&1
}

run_startup_benchmark() {
  local end_ns elapsed_ms median_ms start_ns
  local -a samples sorted_samples

  # Warm completion and prompt caches before sampling. The opt-in measurement
  # avoids making heterogeneous CI hosts responsible for a wall-clock SLA.
  run_interactive_plugin_check
  for _ in {1..11}; do
    start_ns=$(date +%s%N)
    run_interactive_plugin_check
    end_ns=$(date +%s%N)
    elapsed_ms=$(((end_ns - start_ns + 500000) / 1000000))
    samples+=("$elapsed_ms")
  done
  mapfile -t sorted_samples < <(printf '%s\n' "${samples[@]}" | sort -n)
  median_ms=${sorted_samples[${#sorted_samples[@]} / 2]}
  printf 'Zsh warm startup median: %dms (budget: %dms)\n' \
    "$median_ms" "$startup_budget_ms"
  ((median_ms <= startup_budget_ms))
}

if [[ $plugin_runtime_ready == true ]]; then
  run_interactive_plugin_check
else
  echo 'SKIP: managed Zsh plugin packages are not installed yet'
fi

if [[ ${RUN_ZSH_STARTUP_BENCHMARK:-0} == 1 ]]; then
  if [[ $plugin_runtime_ready != true ]]; then
    echo 'RUN_ZSH_STARTUP_BENCHMARK requires all managed shell packages' >&2
    exit 1
  fi
  run_startup_benchmark
fi

printf 'PASS: Zsh, Oh My Zsh, developer plugins, Starship, fastfetch, and mise integration\n'
