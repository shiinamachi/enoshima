#!/usr/bin/env bash
# @vicinae.schemaVersion 1
# @vicinae.title Sysprof 캡처
# @vicinae.mode silent
# @vicinae.packageName Performance
# @vicinae.icon /usr/share/icons/Papirus/64x64/apps/applications-engineering.svg
# @vicinae.description 성능 프로파일링 캡처
# @vicinae.exec ["/bin/bash"]

exec uwsm app -t service -- sysprof
