# This must remain the final Oh My Zsh plugin so every earlier ZLE widget is
# visible to the highlighter. ZSH_PLUGIN_ROOT supports isolated tests only.
syntax_highlighting_plugin=${ZSH_PLUGIN_ROOT:-/usr/share/zsh/plugins}/zsh-syntax-highlighting/zsh-syntax-highlighting.plugin.zsh
if [[ -r $syntax_highlighting_plugin ]]; then
  source "$syntax_highlighting_plugin"
else
  print -u2 'zsh-syntax-highlighting is unavailable; run the repository bootstrap.'
fi
unset syntax_highlighting_plugin
