#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title sysstat 기록
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/apps/utilities-terminal.svg
# @vicinae.description 시스템 활동 기록
# @vicinae.exec ["/bin/bash"]

history_file="/var/log/sa/sa$(date +%d)"
exec uwsm app -t service -- ghostty --title="Sysstat history" \
  -e sudo sar -A -f "$history_file"
