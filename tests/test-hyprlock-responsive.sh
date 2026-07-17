#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config=$repo_root/home/dot_config/hypr/hyprlock.conf

fail() {
  printf 'Hyprlock responsive layout test failed: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'fractional_scaling = 2' "$config" ||
  fail 'fractional scaling is not explicitly automatic'
grep -Fq 'size = 468, 560' "$config" ||
  fail 'authentication card does not match the bounded Outline Frame'
grep -Fq 'size = 420, 58' "$config" ||
  fail 'password control lost its accessible bounded size'

python - "$config" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
positions = re.findall(r"^\s*position\s*=\s*([^\n#]+)", text, flags=re.MULTILINE)
expected = {"0, 0", "0, 264", "0, 232", "0, 164", "0, 112", "0, 66", "0, 10", "0, -62", "0, -132"}
if set(map(str.strip, positions)) != expected:
    raise SystemExit(f"unexpected centered positions: {positions}")

# Logical output sizes cover balanced eDP, matched eDP, Dell, common external,
# and a conservative small fallback. Widgets must stay within the card and the
# card/input must stay within every output.
resolutions = [
    (1440, 900),
    (1280, 800),
    (2560, 1440),
    (1920, 1080),
    (1024, 768),
    (800, 600),
]
for width, height in resolutions:
    assert 468 <= width
    assert 560 <= height
    assert 420 <= width
    for center, half_height in ((264, 10), (232, 10), (164, 38), (112, 12), (66, 12), (10, 29), (-62, 26), (-132, 24)):
        assert center - half_height >= -280
        assert center + half_height <= 280
PY

# Match hyprlock's literal runtime substitution tokens.
# shellcheck disable=SC2016
grep -Fq 'text = ◎  $FPRINTMESSAGE' "$config" ||
  fail 'fingerprint feedback is not connected to hyprlock state'
# shellcheck disable=SC2016
grep -Fq 'fail_text = $FAIL' "$config" ||
  fail 'PAM failure feedback is not connected to hyprlock state'
grep -Fq 'Hyprlock uses mixed-DPI responsive geometry' \
  "$repo_root/scripts/postflight.sh" ||
  fail 'postflight does not inspect the deployed responsive lock layout'

printf 'Hyprlock responsive layout tests passed.\n'
