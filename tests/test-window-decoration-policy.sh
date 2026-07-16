#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

fail() {
  printf 'Window decoration policy test failed: %s\n' "$*" >&2
  exit 1
}

waybar_config=home/dot_config/waybar/config.jsonc
waybar_style=home/dot_config/waybar/style.css
window_action=home/dot_local/bin/executable_desktop-window-action
event_bridge=home/dot_local/bin/executable_cyberdock-event-bridge
event_service=home/dot_config/systemd/user/cyberdock-event-bridge.service
decoration_policy=docs/WINDOW-DECORATIONS.md

printf '%s\n' '==> Waybar remains a global status surface'
jq -e '
  ."modules-left" == ["ext/workspaces"] and
  (has("hyprland/window") | not) and
  (has("custom/window-minimize") | not) and
  (has("custom/window-maximize") | not) and
  (has("custom/window-close") | not) and
  (."modules-right" | index("custom/window-minimize") == null) and
  (."modules-right" | index("custom/window-maximize") == null) and
  (."modules-right" | index("custom/window-close") == null)
' "$waybar_config" >/dev/null || fail 'Waybar owns application window UI'

for retired_selector in \
  '#window' \
  '#custom-window-minimize' \
  '#custom-window-maximize' \
  '#custom-window-close'; do
  if grep -Fq -- "$retired_selector" "$waybar_style"; then
    fail "Waybar CSS retains retired selector: $retired_selector"
  fi
done

printf '%s\n' '==> active-window tracking side channel remains retired'
if grep -Fq -- '--tracked' "$window_action"; then
  fail 'desktop-window-action exposes the retired --tracked mode'
fi
if grep -Eq 'active-window-address|activewindowv2' "$event_bridge"; then
  fail 'cyberdock-event-bridge tracks an active window for Waybar'
fi
for service_contract in \
  'Description=Synchronize native Hyprland minimize events with Cyberdock' \
  'Restart=always' \
  'RestartSec=1' \
  'StandardOutput=journal' \
  'StandardError=journal'; do
  grep -Fxq -- "$service_contract" "$event_service" ||
    fail "event bridge service is missing: $service_contract"
done

printf '%s\n' '==> native application decorations remain the default'
for flag_file in \
  home/dot_config/chrome-flags.conf \
  home/dot_config/notion-flags.conf; do
  grep -Fq -- '--ozone-platform=wayland' "$flag_file" ||
    fail "$flag_file does not select native Wayland"
  grep -Fq -- 'WaylandWindowDecorations' "$flag_file" ||
    fail "$flag_file does not enable Wayland window decorations"
done
grep -Fq 'window-decoration = auto' home/dot_config/ghostty/config.ghostty ||
  fail 'Ghostty does not retain automatic native decoration'
grep -Fq 'hyprpm disable hyprbars' bootstrap.sh ||
  fail 'bootstrap no longer disables hyprbars'
grep -Fq 'hyprpm disable hyprbars' home/run_after_30-enable-custom-user-services.sh.tmpl ||
  fail 'user service convergence no longer disables stale hyprbars state'

printf '%s\n' '==> application matrix records ownership without a fallback conflict'
/usr/bin/python - "$decoration_policy" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
section = text.split("## 관리 대상 매트릭스", 1)[1].split("## 수동 검증 절차", 1)[0]
rows = []
for raw_line in section.splitlines():
    if not raw_line.startswith("| ") or raw_line.startswith("| ---"):
        continue
    cells = [cell.strip() for cell in raw_line.strip().strip("|").split("|")]
    if cells[0] == "Application":
        continue
    if len(cells) != 7:
        raise SystemExit(f"invalid decoration matrix row: {raw_line}")
    rows.append(cells)

required = {
    "Google Chrome",
    "Notion",
    "Ghostty",
    "Thunar",
    "Zed",
    "ONLYOFFICE",
    "KakaoTalk",
}
applications = {row[0] for row in rows}
missing = sorted(required - applications)
if missing:
    raise SystemExit("missing required decoration rows: " + ", ".join(missing))

for application, _class, _backend, owner, _config, fallback, status in rows:
    if "hyprbars" not in fallback.lower():
        if fallback != "없음":
            raise SystemExit(f"{application}: unknown fallback contract: {fallback}")
        continue
    if owner not in {"없음", "미제공"}:
        raise SystemExit(f"{application}: native owner and hyprbars are both assigned")
    reason = fallback.partition(":")[2].strip()
    if not reason:
        raise SystemExit(f"{application}: hyprbars fallback has no reason")
    if not re.search(r"\b20\d{2}-\d{2}-\d{2}\b", status):
        raise SystemExit(f"{application}: hyprbars fallback has no validation date")

if "현재 `hyprbars` fallback: 없음." not in text:
    raise SystemExit("the empty hyprbars fallback register is not explicit")
PY

printf 'Window decoration policy tests passed.\n'
