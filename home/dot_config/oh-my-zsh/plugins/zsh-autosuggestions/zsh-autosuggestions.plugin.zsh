# Connect the reviewed Arch package to Oh My Zsh without a mutable plugin
# manager. ZSH_PLUGIN_ROOT is used only by isolated repository tests.
autosuggestions_plugin=${ZSH_PLUGIN_ROOT:-/usr/share/zsh/plugins}/zsh-autosuggestions/zsh-autosuggestions.plugin.zsh
if [[ -r $autosuggestions_plugin ]]; then
  source "$autosuggestions_plugin"
else
  print -u2 'zsh-autosuggestions is unavailable; run the repository bootstrap.'
fi
unset autosuggestions_plugin
