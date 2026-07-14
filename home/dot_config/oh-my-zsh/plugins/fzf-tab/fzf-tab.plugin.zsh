# Connect the reviewed Arch package to Oh My Zsh without a mutable plugin
# manager. ZSH_PLUGIN_ROOT is used only by isolated repository tests.
fzf_tab_plugin=${ZSH_PLUGIN_ROOT:-/usr/share/zsh/plugins}/fzf-tab/fzf-tab.plugin.zsh
if [[ -r $fzf_tab_plugin ]]; then
  source "$fzf_tab_plugin"
else
  print -u2 'fzf-tab is unavailable; run the repository bootstrap.'
fi
unset fzf_tab_plugin
