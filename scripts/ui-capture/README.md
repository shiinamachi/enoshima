# Enoshima UI evidence capture

Capture each required state from the real internal and external Hyprland outputs. Do not use generated concept pixels or a mock render as implementation evidence.

```bash
grim -o eDP-1 /tmp/power-default.png
scripts/ui-capture/capture-surface \
  --surface power-menu --state default --locale en_US.UTF-8 \
  --scale 2.0 --logical-size 1440x900 --display internal \
  --text-overflow-count 0 --source /tmp/power-default.png
```

Repeat the complete `required_states × required_locales × required_scales` matrix from `docs/ui-surfaces.yaml`. Add every emitted JSON sidecar path to the surface's `evidence.captures`, then map each real surface crop to its concept-board reference crop in a JSON file and compute the automated scores:

```bash
scripts/ui-capture/analyze-surface --surface power-menu \
  --mapping docs/evidence/power-menu/mapping.json
```

The analyzer derives geometry, color, text-overflow, and perceptual scores from digest-bound images. Record only the remaining interaction-oriented manual scores:

```bash
scripts/ui-capture/score-surface --surface power-menu --reviewer kentakang \
  --automated-report docs/evidence/power-menu/automated.json \
  --hierarchy 94 --interaction 92 --state-meaning 93 \
  --accessibility-localization 91
```

Set `evidence.status: approved` and its `review` path only after the weighted score is at least 90, every category is at least 85, and all required captures exist. Then run `scripts/check-ui-visual-evidence`. Any implementation or concept change invalidates the evidence digest.
