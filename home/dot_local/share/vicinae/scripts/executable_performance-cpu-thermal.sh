#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title CPU·열 상태
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/apps/thermal-monitor.svg
# @vicinae.description s-tui 대시보드 · turbostat은 진단 문서 참조
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- ghostty --title="CPU and thermal status" -e s-tui
