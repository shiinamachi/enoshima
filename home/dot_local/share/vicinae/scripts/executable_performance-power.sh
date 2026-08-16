#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title 전력 분석
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/apps/gnome-power-statistics.svg
# @vicinae.description powertop 측정 · 자동 튜닝 없음
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- ghostty --title="Power analysis" -e sudo powertop
