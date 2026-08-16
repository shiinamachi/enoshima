#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title Resources
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/apps/utilities-system-monitor.svg
# @vicinae.description 시스템 리소스 모니터
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- resources
