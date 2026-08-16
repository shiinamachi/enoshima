#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
validator=$repo_root/.agents/skills/enoshima-concept-art/scripts/validate-concept-manifest
capture=$repo_root/scripts/ui-capture/capture-surface
score=$repo_root/scripts/ui-capture/score-surface
analyze=$repo_root/scripts/ui-capture/analyze-surface
release_gate=$repo_root/scripts/check-ui-visual-evidence
grep -Fq '"-blur"' "$analyze" || {
  printf 'Visual analyzer omits semantic normalization.\n' >&2
  exit 1
}
grep -Fq -- '--validate-existing' "$release_gate" || {
  printf 'Visual release gate omits aggregate VM provenance validation.\n' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/docs/concepts" "$work/docs/assets" \
  "$work/home/dot_config/quickshell/cyberdock" \
  "$work/home/dot_config/hypr" "$work/sources" "$work/tests"
printf 'import QtQuick\nRectangle { width: 100; height: 100; color: "transparent" }\n' \
  >"$work/home/dot_config/quickshell/cyberdock/Test.qml"
printf 'return true\n' >"$work/home/dot_config/hypr/external.lua"
printf '# External physical procedure\n' >"$work/docs/external-procedure.md"
cat >"$work/tests/verification-map.yaml" <<'EOF'
schema: 1
rules:
  - id: external-physical
    paths: [home/dot_config/hypr/external.lua]
    physical_gates: [external-physical]
EOF
printf '%s\n' \
  'surface_id: test-surface' \
  'states: [default]' \
  'acceptance: [The fixture renders.]' >"$work/docs/concepts/test-surface.yaml"

python3 - "$work/docs/assets/concept.png" "$work/sources" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

def png(path, width, height, color=b'\x05\x06\x23', patterned=False):
    rows = []
    for y in range(height):
        if patterned:
            row = b''.join(
                bytes(((10 + x * 2) % 256, (20 + y * 2) % 256, 80))
                for x in range(width)
            )
        else:
            row = color * width
        rows.append(b'\0' + row)
    raw = b''.join(rows)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

concept = Path(sys.argv[1])
sources = Path(sys.argv[2])
png(concept, 100, 100)
png(sources / '1.png', 100, 100)
png(sources / '1.25.png', 100, 100)
png(sources / '2.png', 100, 100)
png(sources / 'aux.png', 100, 100, b'\x0a\x0c\x3e', patterned=True)
PY

concept_sha=$(sha256sum "$work/docs/assets/concept.png" | awk '{print $1}')
cat >"$work/docs/ui-surfaces.yaml" <<EOF
schema: 2
surfaces:
  test-surface:
    implementation: [home/dot_config/quickshell/cyberdock/Test.qml]
    token_mode: consumer
    concept:
      status: approved
      asset: docs/assets/concept.png
      spec: docs/concepts/test-surface.yaml
      sha256: $concept_sha
    evidence:
      schema: 2
      status: pending
      required_states: [default]
      required_locales: [en_US.UTF-8, ko_KR.UTF-8]
      required_scales: [1.0, 1.25, 2.0]
      required_auxiliary_outputs:
        default: [HEADLESS-AUX]
      implementation_digest: null
      captures: []
      review: null
external_surfaces:
  external-physical:
    implementation: [home/dot_config/hypr/external.lua]
    render_owner: upstream
    tools: [upstream-capture]
    verification:
      mode: t5-physical
      gate: external-physical
      procedure: docs/external-procedure.md
      required_displays: [internal, external]
    rationale: Upstream owns all rendered pixels and the complete interaction lifecycle.
exemptions: {}
EOF

python3 "$validator" "$work/docs/ui-surfaces.yaml" >/dev/null

for case in missing-gate missing-procedure colliding-id attached-evidence; do
  bad_manifest=$work/docs/external-$case.yaml
  case $case in
    missing-gate)
      yq 'del(.external_surfaces["external-physical"].verification.gate)' \
        "$work/docs/ui-surfaces.yaml" >"$bad_manifest"
      expected='verification.gate'
      ;;
    missing-procedure)
      yq '.external_surfaces["external-physical"].verification.procedure = "docs/missing.md"' \
        "$work/docs/ui-surfaces.yaml" >"$bad_manifest"
      expected='procedure: file does not exist'
      ;;
    colliding-id)
      yq '.external_surfaces["test-surface"] = .external_surfaces["external-physical"] | del(.external_surfaces["external-physical"])' \
        "$work/docs/ui-surfaces.yaml" >"$bad_manifest"
      expected='id collides with a concept/evidence surface'
      ;;
    attached-evidence)
      yq '.external_surfaces["external-physical"].evidence = {}' \
        "$work/docs/ui-surfaces.yaml" >"$bad_manifest"
      expected='must not claim repository-owned concept or evidence'
      ;;
  esac
  if python3 "$validator" "$bad_manifest" >"$work/external-$case.out" 2>&1; then
    printf 'Invalid external surface contract was accepted: %s\n' "$case" >&2
    exit 1
  fi
  grep -Fq "$expected" "$work/external-$case.out"
done

if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Pending evidence unexpectedly passed the release gate.\n' >&2
  exit 1
fi

mkdir -p "$work/symlink-source" "$work/external-evidence"
cp -- "$work/sources/1.png" "$work/symlink-source/source.png"
ln -s "$work/symlink-source" "$work/source-link"
if python3 "$capture" \
  --repo-root "$work" --surface test-surface --state default \
  --locale en_US.UTF-8 --scale 1 --logical-size 100x100 \
  --display internal --text-overflow-count 0 \
  --source "$work/source-link/source.png" >/dev/null 2>&1; then
  printf 'Capture accepted a screenshot through a symlink parent.\n' >&2
  exit 1
fi
mkdir -p "$work/docs/evidence"
ln -s "$work/external-evidence" "$work/docs/evidence/test-surface"
if python3 "$capture" \
  --repo-root "$work" --surface test-surface --state default \
  --locale en_US.UTF-8 --scale 1 --logical-size 100x100 \
  --display internal --text-overflow-count 0 \
  --source "$work/sources/1.png" >/dev/null 2>&1; then
  printf 'Capture accepted a symlinked evidence output directory.\n' >&2
  exit 1
fi
test -z "$(find "$work/external-evidence" -mindepth 1 -print -quit)"
rm -- "$work/docs/evidence/test-surface"

sidecars=()
for locale in en_US.UTF-8 ko_KR.UTF-8; do
  for scale in 1 1.25 2; do
    case $scale in
      1) logical=100x100 ;;
      1.25) logical=80x80 ;;
      2) logical=50x50 ;;
    esac
    sidecars+=("$(python3 "$capture" \
      --repo-root "$work" --surface test-surface --state default \
      --locale "$locale" --scale "$scale" --logical-size "$logical" \
      --display internal --text-overflow-count 0 \
      --source "$work/sources/$scale.png")")
  done
done
implementation_digest=$(jq -r '.implementation_digest' "$work/${sidecars[0]}")
auxiliary_image=docs/evidence/test-surface/auxiliary.webp
magick "$work/sources/aux.png" -quality 92 "$work/$auxiliary_image"
auxiliary_hash=$(sha256sum "$work/$auxiliary_image" | awk '{print $1}')
read -r auxiliary_semantic_sha auxiliary_unique_values auxiliary_stddev < <(
  python3 - "$validator" "$work/$auxiliary_image" <<'PY'
import runpy
import sys
from pathlib import Path

module = runpy.run_path(sys.argv[1])
metrics = module['semantic_metrics'](Path(sys.argv[2]), 'test-surface', 1.0)
print(
    metrics['sha256'],
    metrics['unique_gray_values'],
    metrics['normalized_standard_deviation'],
)
PY
)
for sidecar in "${sidecars[@]}"; do
  source_sidecar_sha=$(sha256sum "$work/$sidecar" | awk '{print $1}')
  jq \
    --arg image "$auxiliary_image" \
    --arg image_sha "$auxiliary_hash" \
    --arg source_sidecar_sha "$source_sidecar_sha" \
    --arg semantic_sha "$auxiliary_semantic_sha" \
    --argjson unique_values "$auxiliary_unique_values" \
    --argjson stddev "$auxiliary_stddev" \
    '(.scale | if . == 1.25 then 2 else 1.25 end) as $aux_scale
      | .source_sidecar_sha256=$source_sidecar_sha
      | .source_image_sha256=.image_sha256
      | .semantic_outputs={"HEADLESS-AUX":$semantic_sha}
      | .auxiliary_outputs=[{output:"HEADLESS-AUX",image:$image,
      image_sha256:$image_sha,source_image_sha256:$image_sha,pixel_size:[100,100],
      logical_size:[(100/$aux_scale),(100/$aux_scale)],scale:$aux_scale,
      expected_workspaces:[1,2,4],semantic_content:{sha256:$semantic_sha,
      unique_gray_values:$unique_values,normalized_standard_deviation:$stddev},
      stability_changed_pixel_ratio:0}]' \
    "$work/$sidecar" >"$work/$sidecar.tmp"
  mv -- "$work/$sidecar.tmp" "$work/$sidecar"
done
manual_overflow_image=docs/evidence/test-surface/manual-overflow-review.webp
magick "$work/sources/1.png" -quality 92 "$work/$manual_overflow_image"
manual_overflow_hash=$(sha256sum "$work/$manual_overflow_image" | awk '{print $1}')
manual_coverage=docs/evidence/test-surface/manual-overflow-coverage.json
manual_coverage_records=$work/manual-overflow-coverage.jsonl
: >"$manual_coverage_records"
for sidecar in "${sidecars[@]}"; do
  jq -c \
    '{_state:.state,_locale:.locale,_scale:.scale,
      sidecar:(.image | split("/")[-1] | sub("[.]png$"; ".json")),
      sidecar_sha256:.source_sidecar_sha256,
      images:([{output:(.output // "HEADLESS-UI"),
        image_sha256:.source_image_sha256}]
        + [.auxiliary_outputs[]
          | {output:.output,image_sha256:.source_image_sha256}])}' \
    "$work/$sidecar" >>"$manual_coverage_records"
done
jq -n \
  --slurpfile reviewed <(
    jq -s 'sort_by(._state, ._locale, ._scale)
      | map(del(._state, ._locale, ._scale))' "$manual_coverage_records"
  ) \
  '{schema:1,surface_id:"test-surface",run_id:"test-fixture",
    reviewed_captures:$reviewed[0]}' >"$work/$manual_coverage"
manual_coverage_hash=$(sha256sum "$work/$manual_coverage" | awk '{print $1}')
first_sidecar=$work/${sidecars[0]}
jq \
  --arg artifact "$manual_overflow_image" \
  --arg artifact_sha "$manual_overflow_hash" \
  --arg coverage "$manual_coverage" \
  --arg coverage_sha "$manual_coverage_hash" \
  '.text_overflow_measurement={method:"manual-contact-sheet-review",
    reviewer:"Test reviewer",review_artifact:$artifact,
    review_artifact_sha256:$artifact_sha,
    source_review_artifact_sha256:("1" * 64),report_sha256:("2" * 64),
    coverage:$coverage,coverage_sha256:$coverage_sha,
    reviewed_capture_count:6,reviewed_image_count:12}' \
  "$first_sidecar" >"$first_sidecar.tmp"
mv -- "$first_sidecar.tmp" "$first_sidecar"
{
  printf '{"schema":1,"surface_id":"test-surface","comparisons":['
  separator=
  for sidecar in "${sidecars[@]}"; do
    printf '%s' "$separator"
    jq -cn --arg sidecar "$sidecar" \
      '{sidecar:$sidecar,reference_crop:[0,0,100,100],implementation_crop:[0,0,100,100]}'
    separator=,
  done
  printf ']}\n'
} >"$work/mapping.json"
ln -s "$work/mapping.json" "$work/mapping-link.json"
if python3 "$analyze" --repo-root "$work" --surface test-surface \
  --mapping "$work/mapping-link.json" >/dev/null 2>&1; then
  printf 'Analyzer accepted a symlinked mapping.\n' >&2
  exit 1
fi
jq '.comparisons |= .[1:]' "$work/mapping.json" >"$work/mapping-subset.json"
if python3 "$analyze" --repo-root "$work" --surface test-surface \
  --mapping "$work/mapping-subset.json" >/dev/null 2>&1; then
  printf 'Analyzer accepted a mapping that omitted a capture.\n' >&2
  exit 1
fi
automated=$(python3 "$analyze" --repo-root "$work" --surface test-surface \
  --mapping "$work/mapping.json")
review=$(python3 "$score" --repo-root "$work" --surface test-surface \
  --reviewer test --automated-report "$work/$automated" \
  --hierarchy 90 --interaction 90 --state-meaning 90 \
  --accessibility-localization 90)

{
  cat <<EOF
schema: 2
surfaces:
  test-surface:
    implementation: [home/dot_config/quickshell/cyberdock/Test.qml]
    token_mode: consumer
    concept:
      status: approved
      asset: docs/assets/concept.png
      spec: docs/concepts/test-surface.yaml
      sha256: $concept_sha
    evidence:
      schema: 2
      status: approved
      required_states: [default]
      required_locales: [en_US.UTF-8, ko_KR.UTF-8]
      required_scales: [1.0, 1.25, 2.0]
      required_auxiliary_outputs:
        default: [HEADLESS-AUX]
      implementation_digest: $implementation_digest
      captures:
EOF
  for sidecar in "${sidecars[@]}"; do printf '        - %s\n' "$sidecar"; done
  printf '      review: %s\n' "$review"
  printf 'exemptions: {}\n'
} >"$work/docs/ui-surfaces.yaml"

python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null

cp -- "$work/mapping.json" "$work/mapping.saved"
jq '.comparisons[0].reference_crop = [0,0,99,100]' \
  "$work/mapping.saved" >"$work/mapping.json"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Changed automated mapping unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv -- "$work/mapping.saved" "$work/mapping.json"

automated_path=$work/$automated
review_path=$work/$review
cp -- "$automated_path" "$work/automated.saved"
cp -- "$review_path" "$work/review.saved"
jq '.sources[0].sidecar_sha256 = ("0" * 64)' \
  "$work/automated.saved" >"$automated_path"
forged_automated_hash=$(sha256sum "$automated_path" | awk '{print $1}')
jq --arg hash "$forged_automated_hash" '.automated_report_sha256 = $hash' \
  "$work/review.saved" >"$review_path"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Forged automated source hash unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv -- "$work/automated.saved" "$automated_path"
mv -- "$work/review.saved" "$review_path"

cp -- "$work/$manual_coverage" "$work/manual-coverage.saved"
jq '.reviewed_captures |= .[1:]' \
  "$work/manual-coverage.saved" >"$work/$manual_coverage"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Incomplete manual coverage unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv -- "$work/manual-coverage.saved" "$work/$manual_coverage"

first_image=$(jq -r '.image' "$work/${sidecars[0]}")
cp "$work/$first_image" "$work/image.saved"
printf 'tampered' >>"$work/$first_image"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Tampered screenshot unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv "$work/image.saved" "$work/$first_image"

cp "$work/$auxiliary_image" "$work/auxiliary.saved"
printf 'tampered' >>"$work/$auxiliary_image"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Tampered auxiliary screenshot unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv "$work/auxiliary.saved" "$work/$auxiliary_image"

mkdir "$work/sidecars-saved"
for sidecar in "${sidecars[@]}"; do
  cp -- "$work/$sidecar" "$work/sidecars-saved/$(basename "$sidecar")"
done
cp "$work/$auxiliary_image" "$work/auxiliary.saved"
magick -size 100x100 xc:'#0a0c3e' "$work/$auxiliary_image"
forged_auxiliary_hash=$(sha256sum "$work/$auxiliary_image" | awk '{print $1}')
forged_semantic_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for sidecar in "${sidecars[@]}"; do
  jq \
    --arg image_sha "$forged_auxiliary_hash" \
    --arg semantic_sha "$forged_semantic_sha" \
    '.auxiliary_outputs[0].image_sha256 = $image_sha
      | .auxiliary_outputs[0].semantic_content = {sha256:$semantic_sha,
        unique_gray_values:32,normalized_standard_deviation:0.1}
      | .semantic_outputs["HEADLESS-AUX"] = $semantic_sha' \
    "$work/$sidecar" >"$work/$sidecar.tmp"
  mv -- "$work/$sidecar.tmp" "$work/$sidecar"
done
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Uniform auxiliary image with forged metrics passed the release gate.\n' >&2
  exit 1
fi
mv "$work/auxiliary.saved" "$work/$auxiliary_image"
for sidecar in "${sidecars[@]}"; do
  mv -- "$work/sidecars-saved/$(basename "$sidecar")" "$work/$sidecar"
done

cp "$work/$manual_overflow_image" "$work/manual-overflow.saved"
printf 'tampered' >>"$work/$manual_overflow_image"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Tampered manual overflow review unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv "$work/manual-overflow.saved" "$work/$manual_overflow_image"

cp "$first_sidecar" "$work/sidecar.saved"
jq '.text_overflow_count = 1' "$first_sidecar" >"$first_sidecar.tmp"
mv -- "$first_sidecar.tmp" "$first_sidecar"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Visible text overflow unexpectedly passed the release gate.\n' >&2
  exit 1
fi
cp -- "$work/sidecar.saved" "$first_sidecar"

jq 'del(.auxiliary_outputs)' "$first_sidecar" >"$first_sidecar.tmp"
mv -- "$first_sidecar.tmp" "$first_sidecar"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Missing required auxiliary screenshot unexpectedly passed the release gate.\n' >&2
  exit 1
fi
mv "$work/sidecar.saved" "$first_sidecar"

cp "$work/docs/concepts/test-surface.yaml" "$work/spec.saved"
printf 'notes: [Changed after review.]\n' >>"$work/docs/concepts/test-surface.yaml"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Changed concept specification unexpectedly reused stale evidence.\n' >&2
  exit 1
fi
mv "$work/spec.saved" "$work/docs/concepts/test-surface.yaml"

printf '// implementation drift\n' >>"$work/home/dot_config/quickshell/cyberdock/Test.qml"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Stale evidence unexpectedly passed after implementation drift.\n' >&2
  exit 1
fi

printf 'UI visual evidence gate tests passed.\n'
