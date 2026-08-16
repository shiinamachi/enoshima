#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title GPU 확인
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/devices/video-display.svg
# @vicinae.description GPU 사용량 모니터
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- ghostty --title="GPU usage" -e nvtop
