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
grep -Fq 'size = 600, 30%' "$config" ||
  fail 'authentication card does not have bounded mixed-unit geometry'
grep -Fq 'size = 532, 64' "$config" ||
  fail 'password control lost its accessible bounded size'

if grep -Eq '^[[:space:]]*position = -?[0-9]+, -?[0-9]+[[:space:]]*$' "$config"; then
  fail 'an absolute widget position remains in the lock layout'
fi

python - "$config" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
positions = re.findall(r"^\s*position\s*=\s*([^\n#]+)", text, flags=re.MULTILINE)
expected = {
    "5%, 7%",
    "7%, 34.5%",
    "6.7%, 26%",
    "7%, 21.5%",
    "7%, 14%",
    "7.2%, 9.5%",
}
if set(map(str.strip, positions)) != expected:
    raise SystemExit(f"unexpected percentage positions: {positions}")

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
    card_left = width * 0.05
    card_bottom = height * 0.07
    card_top = card_bottom + height * 0.30
    input_left = width * 0.07
    input_center = height * 0.14

    assert card_left >= 0
    assert card_left + 600 <= width
    assert card_top <= height
    assert input_left + 532 <= width
    assert input_center - 32 >= card_bottom
    assert input_center + 32 <= card_top

    for center in (height * 0.345, height * 0.26, height * 0.215, height * 0.095):
        assert card_bottom <= center <= card_top
PY

# Match hyprlock's literal runtime substitution tokens.
# shellcheck disable=SC2016
grep -Fq 'text = $FPRINTPROMPT' "$config" ||
  fail 'fingerprint feedback is not connected to hyprlock state'
# shellcheck disable=SC2016
grep -Fq 'fail_text = $FAIL' "$config" ||
  fail 'PAM failure feedback is not connected to hyprlock state'
grep -Fq 'Hyprlock uses mixed-DPI responsive geometry' \
  "$repo_root/scripts/postflight.sh" ||
  fail 'postflight does not inspect the deployed responsive lock layout'

printf 'Hyprlock responsive layout tests passed.\n'
