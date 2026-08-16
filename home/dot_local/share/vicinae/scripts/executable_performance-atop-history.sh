#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title atop 기록
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/apps/utilities-terminal.svg
# @vicinae.description 시스템 리소스 기록
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- ghostty --title="Atop history" -e sudo atop -r
