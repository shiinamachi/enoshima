#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title I/O 확인
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/devices/drive-harddisk.svg
# @vicinae.description 디스크 I/O 모니터
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- ghostty --title="I/O pressure" -e sudo iotop --only --processes --accumulated
