# Enoshima UI evidence capture

Capture each required state from the real internal and external Hyprland outputs. Do not use generated concept pixels or a mock render as implementation evidence.

```bash
grim -o eDP-1 /tmp/power-default.png
scripts/ui-capture/capture-surface \
  --surface power-menu --state default --locale en_US.UTF-8 \
  --scale 2.0 --logical-size 1440x900 --display internal \
  --text-overflow-count 0 --source /tmp/power-default.png
```

Repeat the complete `required_states × required_locales × required_scales`
matrix from `docs/ui-surfaces.yaml`. Manual captures produce sidecars directly;
the VM importer described below adds its emitted sidecars to the registry.

The VM path must come from a passing `ui-review` run whose source is a clean
commit; a dirty affected checkpoint is useful verification but cannot become
canonical evidence. A selector-driven run can be imported incrementally without
replacing approved surface directories:

```bash
scripts/ui-capture/import-vm-run \
  --run-dir ~/.local/state/enoshima-vm/runs/run-ID \
  --surface command-palette \
  --surface overview \
  --manual-overflow-report /path/to/manual-overflow.json
```

`--surface` is repeatable and each requested surface must have its complete
matrix in the VM run. Package-owned surfaces do not expose the Quickshell text
bounds probe, so inspect a contact sheet containing every state, locale, scale,
and auxiliary-output capture. Keep that contact sheet inside the selected run's
artifact directory and provide a report with this shape:

```json
{
  "schema": 1,
  "run_id": "run-ID",
  "surfaces": {
    "command-palette": {
      "verified": true,
      "reviewer": "Reviewer name",
      "text_overflow_count": 0,
      "review_artifact": "/absolute/run/artifacts/command-palette-contact-sheet.png",
      "reviewed_captures": [
        {
          "sidecar": "command-palette--default--en-us-utf-8--1x.json",
          "sidecar_sha256": "<sha256 of the VM sidecar>",
          "images": [
            {
              "output": "HEADLESS-UI",
              "image_sha256": "<sha256 of the source PNG>"
            }
          ]
        }
      ]
    }
  }
}
```

`reviewed_captures` must contain every source sidecar exactly once, in the
importer's matrix order, and every primary and auxiliary image listed by that
sidecar. The importer recomputes this list from the selected run and refuses a
subset, duplicate, reordered, or stale digest. It publishes the accepted list
as `manual-overflow-coverage.json`, and every imported manual-overflow
measurement is bound to that file and its capture/image counts.

The importer serializes concurrent imports, preserves existing approved
evidence, rolls back a partial publish, converts new primary and auxiliary PNGs
to digest-bound WebP files, and appends per-run provenance to the schema 2
`docs/evidence/vm-run.json` aggregate.

After import, map each real surface crop to its concept-board reference crop and
compute the automated scores:

```bash
scripts/ui-capture/analyze-surface --surface power-menu \
  --mapping docs/evidence/power-menu/mapping.json
```

The analyzer derives geometry, color, text-overflow, and perceptual scores from
digest-bound images. Reference and implementation crops are normalized to
512×512 and receive a fixed semantic blur before RMSE/SSIM comparison. This
keeps panel geometry, hierarchy, and dominant design tokens measurable without
penalizing expected differences in live application names, timestamps, or
glyph rasterization. Record only the remaining interaction-oriented manual
scores:

```bash
scripts/ui-capture/score-surface --surface power-menu --reviewer kentakang \
  --automated-report docs/evidence/power-menu/automated.json \
  --hierarchy 94 --interaction 92 --state-meaning 93 \
  --accessibility-localization 91
```

Set `evidence.status: approved` and its `review` path only after the weighted
score is at least 90, every category is at least 85, and all required captures
exist. Then run `scripts/check-ui-visual-evidence`. The release entrypoint
validates both the per-surface visual contract and `docs/evidence/vm-run.json`
run ownership, counts, ancestry, and sidecar provenance. Any implementation,
concept, evidence image, or aggregate provenance change invalidates the gate.
