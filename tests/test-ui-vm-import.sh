#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
importer=$repo_root/scripts/ui-capture/import-vm-run
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -p \
  "$work/repo/docs/assets" \
  "$work/repo/docs/concepts" \
  "$work/repo/docs/evidence/existing-surface" \
  "$work/repo/home/dot_config/quickshell/cyberdock" \
  "$work/run-fixture/artifacts/ui-review" \
  "$work/run-fixture/artifacts/screenshots"

printf 'import QtQuick\nRectangle { width: 100; height: 100 }\n' \
  >"$work/repo/home/dot_config/quickshell/cyberdock/Test.qml"
printf 'surface_id: test-surface\nstates: [default]\nacceptance: [Visible.]\n' \
  >"$work/repo/docs/concepts/test-surface.yaml"

python3 - "$work/repo/docs/assets/concept.png" \
  "$work/run-fixture/artifacts/screenshots/capture.png" \
  "$work/run-fixture/artifacts/screenshots/auxiliary.png" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

def png(path: Path, color: bytes, *, patterned: bool = False) -> None:
    width = height = 100
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
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack('>I', len(data)) + kind + data + struct.pack(
            '>I', zlib.crc32(kind + data) & 0xffffffff
        )
    path.write_bytes(
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw))
        + chunk(b'IEND', b'')
    )

for value in sys.argv[1:3]:
    png(Path(value), b'\x05\x06\x23')
png(Path(sys.argv[3]), b'\x0a\x0c\x3e', patterned=True)
PY

concept_sha=$(sha256sum "$work/repo/docs/assets/concept.png" | awk '{print $1}')
concept_spec_sha=$(sha256sum "$work/repo/docs/concepts/test-surface.yaml" | awk '{print $1}')
implementation_digest=$(
  python3 - "$work/repo" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
value = 'home/dot_config/quickshell/cyberdock/Test.qml'
digest = hashlib.sha256()
digest.update(value.encode())
digest.update(b'\0')
digest.update((root / value).read_bytes())
digest.update(b'\0')
print(digest.hexdigest())
PY
)

cat >"$work/repo/docs/ui-surfaces.yaml" <<EOF
schema: 2
surfaces:
  existing-surface:
    implementation: [home/dot_config/quickshell/cyberdock/Test.qml]
    concept:
      status: approved
      asset: docs/assets/concept.png
      spec: docs/concepts/test-surface.yaml
      sha256: $concept_sha
    evidence:
      status: approved
      required_states: [default]
      required_locales: [en_US.UTF-8]
      required_scales: [1.0]
  test-surface:
    implementation: [home/dot_config/quickshell/cyberdock/Test.qml]
    concept:
      status: approved
      asset: docs/assets/concept.png
      spec: docs/concepts/test-surface.yaml
      sha256: $concept_sha
    evidence:
      status: pending
      required_states: [default]
      required_locales: [en_US.UTF-8, ko_KR.UTF-8]
      required_scales: [1.0, 1.25, 2.0]
      required_auxiliary_outputs:
        default: [HEADLESS-AUX]
      implementation_digest: null
      captures: []
      review: null
exemptions: {}
EOF

git -C "$work/repo" init -q
git -C "$work/repo" config user.name Test
git -C "$work/repo" config user.email test@example.invalid
git -C "$work/repo" add .
git -C "$work/repo" commit -qm fixture-source
existing_commit=$(git -C "$work/repo" rev-parse HEAD)

existing_stem=existing-surface--default--en-us-utf-8--1x
magick "$work/run-fixture/artifacts/screenshots/capture.png" -quality 92 \
  "$work/repo/docs/evidence/existing-surface/$existing_stem.webp"
existing_image_sha=$(
  sha256sum "$work/repo/docs/evidence/existing-surface/$existing_stem.webp" | awk '{print $1}'
)
jq -n \
  --arg implementation "$implementation_digest" \
  --arg concept "$concept_sha" \
  --arg concept_spec "$concept_spec_sha" \
  --arg image_sha "$existing_image_sha" \
  --arg source_commit "$existing_commit" \
  '{schema:1,surface_id:"existing-surface",state:"default",
    locale:"en_US.UTF-8",scale:1,
    image:"docs/evidence/existing-surface/existing-surface--default--en-us-utf-8--1x.webp",
    image_sha256:$image_sha,logical_size:[100,100],pixel_size:[100,100],
    run_id:"run-existing",
    source_commit:$source_commit,
    worktree_hash:"sha256:0000000000000000000000000000000000000000000000000000000000000000",
    implementation_digest:$implementation,concept_sha256:$concept,
    concept_spec_sha256:$concept_spec}' \
  >"$work/repo/docs/evidence/existing-surface/$existing_stem.json"
jq -n \
  --arg implementation "$implementation_digest" \
  --arg concept "$concept_sha" \
  --arg concept_spec "$concept_spec_sha" \
  --arg source_commit "$existing_commit" \
  '{schema:1,run_id:"run-existing",
    source_commit:$source_commit,
    worktree_hash:"sha256:0000000000000000000000000000000000000000000000000000000000000000",
    expected_captures:1,actual_captures:1,
    junit_sha256:"0000000000000000000000000000000000000000000000000000000000000000",
    imported_at:"2026-01-01T00:00:00+00:00",
    surfaces:{"existing-surface":{implementation_digest:$implementation,
      concept_sha256:$concept,concept_spec_sha256:$concept_spec,
      captures:["docs/evidence/existing-surface/existing-surface--default--en-us-utf-8--1x.json"]}}}' \
  >"$work/repo/docs/evidence/vm-run.json"

git -C "$work/repo" add docs/evidence
git -C "$work/repo" commit -qm fixture-existing-evidence
commit=$(git -C "$work/repo" rev-parse HEAD)
image=$work/run-fixture/artifacts/screenshots/capture.png
image_sha=$(sha256sum "$image" | awk '{print $1}')

captures=0
for locale in en_US.UTF-8 ko_KR.UTF-8; do
  locale_slug=${locale,,}
  locale_slug=${locale_slug//./-}
  locale_slug=${locale_slug//_/-}
  for scale in 1 1.25 2; do
    scale_slug=${scale//./-}
    stem="test-surface--default--$locale_slug--${scale_slug}x"
    jq -n \
      --arg surface test-surface \
      --arg state default \
      --arg locale "$locale" \
      --argjson scale "$scale" \
      --arg image "$image" \
      --arg image_sha "$image_sha" \
      --arg commit "$commit" \
      --arg implementation "$implementation_digest" \
      --arg concept "$concept_sha" \
      '{schema:1,surface_id:$surface,state:$state,locale:$locale,scale:$scale,
        output:"HEADLESS-UI",logical_size:[100,100],pixel_size:[100,100],
        stability_changed_pixel_ratio:0,image:$image,image_sha256:$image_sha,
        run_id:"run-fixture",source_commit:$commit,
        worktree_hash:"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        implementation_digest:$implementation,concept_sha256:$concept,
        text_overflow_count:null,fixture:{used:true,reason:"test"}}' \
      >"$work/run-fixture/artifacts/ui-review/$stem.json"
    captures=$((captures + 1))
  done
done

aux_image=$work/run-fixture/artifacts/screenshots/auxiliary.png
aux_image_sha=$(sha256sum "$aux_image" | awk '{print $1}')
read -r aux_semantic_sha aux_unique_values aux_stddev < <(
  python3 - "$importer" "$aux_image" <<'PY'
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
for aux_sidecar in "$work/run-fixture/artifacts/ui-review"/*.json; do
  jq \
    --arg image "$aux_image" \
    --arg image_sha "$aux_image_sha" \
    --arg semantic_sha "$aux_semantic_sha" \
    --argjson unique_values "$aux_unique_values" \
    --argjson stddev "$aux_stddev" \
    '(.scale | if . == 1.25 then 2 else 1.25 end) as $aux_scale
      | .semantic_outputs={"HEADLESS-AUX":$semantic_sha}
      | .auxiliary_outputs=[{output:"HEADLESS-AUX",image:$image,
      image_sha256:$image_sha,pixel_size:[100,100],
      logical_size:[(100/$aux_scale),(100/$aux_scale)],scale:$aux_scale,
      expected_workspaces:[1,2,4],semantic_content:{sha256:$semantic_sha,
      unique_gray_values:$unique_values,normalized_standard_deviation:$stddev},
      stability_changed_pixel_ratio:0}]' \
    "$aux_sidecar" >"$aux_sidecar.tmp"
  mv -- "$aux_sidecar.tmp" "$aux_sidecar"
done

reviewed_records=$work/reviewed-captures.jsonl
: >"$reviewed_records"
for reviewed_sidecar in "$work/run-fixture/artifacts/ui-review"/test-surface--*.json; do
  reviewed_sidecar_sha=$(sha256sum "$reviewed_sidecar" | awk '{print $1}')
  jq -c \
    --arg sidecar "$(basename -- "$reviewed_sidecar")" \
    --arg sidecar_sha "$reviewed_sidecar_sha" \
    '{_state:.state,_locale:.locale,_scale:.scale,
      sidecar:$sidecar,sidecar_sha256:$sidecar_sha,
      images:([{output:(.output // "HEADLESS-UI"),image_sha256:.image_sha256}]
        + [.auxiliary_outputs[]?
          | {output:.output,image_sha256:.image_sha256}])}' \
    "$reviewed_sidecar" >>"$reviewed_records"
done
jq -s 'sort_by(._state, ._locale, ._scale)
  | map(del(._state, ._locale, ._scale))' \
  "$reviewed_records" >"$work/reviewed-captures.json"

jq -n --argjson count "$captures" \
  '{schema:1,matrix_mode:"affected-full",expected:$count,actual:$count,
    surfaces:["test-surface"],
    locales:["en_US.UTF-8","ko_KR.UTF-8"],scales:[1,1.25,2],
    text_overflow_failures:[],identical_state_failures:[],
    identical_pair_failures:[]}' \
  >"$work/run-fixture/artifacts/ui-review/summary.json"
printf '<testsuite tests="1" failures="0"/>\n' >"$work/run-fixture/artifacts/junit.xml"

jq -n \
  --arg commit "$commit" \
  --arg artifacts "$work/run-fixture/artifacts" \
  '{schema:1,run_id:"run-fixture",suite:"ui-review",status:"completed",
    result:"passed",
    source:{source_commit:$commit,dirty:false,
      worktree_hash:"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      untracked_files:[]},artifact_dir:$artifacts,
    steps:[{action:"run_ui_review",status:"passed"},
      {action:"collect_artifacts",status:"passed"}]}' \
  >"$work/run-fixture/run.json"

if python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
  --surface test-surface \
  >/dev/null 2>&1; then
  printf 'Importer accepted missing manual overflow evidence.\n' >&2
  exit 1
fi

cp "$image" "$work/run-fixture/artifacts/manual-overflow-review.png"
jq -n \
  --arg artifact "$work/run-fixture/artifacts/manual-overflow-review.png" \
  --slurpfile reviewed "$work/reviewed-captures.json" \
  '{schema:1,run_id:"run-fixture",surfaces:{"test-surface":{
    verified:true,reviewer:"Test reviewer",text_overflow_count:0,
    review_artifact:$artifact,reviewed_captures:$reviewed[0]}}}' \
  >"$work/manual-overflow.json"

expect_import_rejected() {
  local label=$1
  if python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
    --surface test-surface \
    --manual-overflow-report "$work/manual-overflow.json" \
    >/dev/null 2>&1; then
    printf 'Importer accepted %s.\n' "$label" >&2
    exit 1
  fi
  test ! -e "$work/repo/docs/evidence/test-surface"
}

cp -- "$work/manual-overflow.json" "$work/manual-overflow.valid.json"
jq '.surfaces["test-surface"].reviewed_captures |= .[1:]' \
  "$work/manual-overflow.valid.json" >"$work/manual-overflow.json"
expect_import_rejected 'manual evidence that omits a capture'
mv -- "$work/manual-overflow.valid.json" "$work/manual-overflow.json"

cp -- "$work/manual-overflow.json" "$work/manual-overflow.valid.json"
jq '.surfaces["test-surface"].text_overflow_count = 1' \
  "$work/manual-overflow.valid.json" >"$work/manual-overflow.json"
expect_import_rejected 'manual evidence with visible text overflow'
mv -- "$work/manual-overflow.valid.json" "$work/manual-overflow.json"

cp -- "$work/run-fixture/run.json" "$work/run.json.valid"
jq 'del(.schema)' "$work/run.json.valid" >"$work/run-fixture/run.json"
expect_import_rejected 'a versionless VM run record'
mv -- "$work/run.json.valid" "$work/run-fixture/run.json"

summary_path=$work/run-fixture/artifacts/ui-review/summary.json
cp -- "$summary_path" "$work/summary.json.valid"
jq 'del(.identical_pair_failures)' "$work/summary.json.valid" >"$summary_path"
expect_import_rejected 'a summary without the semantic-pair capability'
mv -- "$work/summary.json.valid" "$summary_path"

canonical_sidecar=$work/run-fixture/artifacts/ui-review/test-surface--default--en-us-utf-8--1x.json
forged_sidecar=$work/run-fixture/artifacts/ui-review/test-surface--forged-filename.json
mv -- "$canonical_sidecar" "$forged_sidecar"
expect_import_rejected 'a sidecar filename that can collide with canonical output'
mv -- "$forged_sidecar" "$canonical_sidecar"

mv -- "$work/repo/docs/evidence/vm-run.json" "$work/existing-vm-run.json"
mkdir "$work/repo/docs/evidence/vm-run.json"
if python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
  --surface test-surface \
  --manual-overflow-report "$work/manual-overflow.json" \
  >/dev/null 2>&1; then
  printf 'Importer accepted an unpublishable aggregate manifest.\n' >&2
  exit 1
fi
test ! -e "$work/repo/docs/evidence/test-surface"
rmdir -- "$work/repo/docs/evidence/vm-run.json"
mv -- "$work/existing-vm-run.json" "$work/repo/docs/evidence/vm-run.json"

set +e
python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
  --surface test-surface \
  --manual-overflow-report "$work/manual-overflow.json" \
  >"$work/import-1.out" 2>"$work/import-1.err" &
first_pid=$!
python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
  --surface test-surface \
  --manual-overflow-report "$work/manual-overflow.json" \
  >"$work/import-2.out" 2>"$work/import-2.err" &
second_pid=$!
wait "$first_pid"
first_status=$?
wait "$second_pid"
second_status=$?
set -e
if [[ $first_status -eq 0 && $second_status -ne 0 ]]; then
  output=$(<"$work/import-1.out")
elif [[ $first_status -ne 0 && $second_status -eq 0 ]]; then
  output=$(<"$work/import-2.out")
else
  printf 'Concurrent imports did not serialize to one success and one refusal.\n' >&2
  sed -n '1,40p' "$work/import-1.err" >&2
  sed -n '1,40p' "$work/import-2.err" >&2
  exit 1
fi
jq -e '.captures == 6 and .surfaces == 1' <<<"$output" >/dev/null
test "$(find "$work/repo/docs/evidence/test-surface" -name '*.json' | wc -l)" -eq 7
test "$(find "$work/repo/docs/evidence/test-surface" -name '*.webp' | wc -l)" -eq 13
jq -e '
  .schema == 2
  and .actual_captures == 7
  and .expected_captures == 7
  and .surface_count == 2
  and (has("run_id") | not)
  and (has("source_commit") | not)
  and (has("junit_sha256") | not)
  and (.surfaces | keys | sort) == ["existing-surface", "test-surface"]
  and (.runs | length) == 2
' "$work/repo/docs/evidence/vm-run.json" >/dev/null
test -f "$work/repo/docs/evidence/existing-surface/$existing_stem.json"
jq -e '
  .text_overflow_measurement.method == "manual-contact-sheet-review"
  and .text_overflow_measurement.review_artifact
    == "docs/evidence/test-surface/manual-overflow-review.webp"
  and (.text_overflow_measurement.review_artifact_sha256 | length) == 64
  and (.text_overflow_measurement.source_review_artifact_sha256 | length) == 64
  and .text_overflow_measurement.coverage
    == "docs/evidence/test-surface/manual-overflow-coverage.json"
  and (.text_overflow_measurement.coverage_sha256 | length) == 64
  and .text_overflow_measurement.reviewed_capture_count == 6
  and .text_overflow_measurement.reviewed_image_count == 12
' "$work/repo/docs/evidence/test-surface/test-surface--default--en-us-utf-8--1x.json" \
  >/dev/null
jq -e '
  .schema == 1
  and .surface_id == "test-surface"
  and .run_id == "run-fixture"
  and (.reviewed_captures | length) == 6
  and ([.reviewed_captures[].images | length] | add) == 12
' "$work/repo/docs/evidence/test-surface/manual-overflow-coverage.json" >/dev/null
jq -e '
  .auxiliary_outputs[0].output == "HEADLESS-AUX"
  and .auxiliary_outputs[0].image
    == "docs/evidence/test-surface/test-surface--default--en-us-utf-8--1x--aux-1-headless-aux.webp"
  and (.auxiliary_outputs[0].source_image_sha256 | length) == 64
  and .auxiliary_outputs[0].expected_workspaces == [1,2,4]
  and .auxiliary_outputs[0].scale != .scale
  and .auxiliary_outputs[0].semantic_content.unique_gray_values >= 8
  and .auxiliary_outputs[0].semantic_content.normalized_standard_deviation >= 0.01
' "$work/repo/docs/evidence/test-surface/test-surface--default--en-us-utf-8--1x.json" \
  >/dev/null
test -f "$work/repo/docs/evidence/test-surface/manual-overflow-review.webp"
if rg -q "$work" "$work/repo/docs/evidence"; then
  printf 'Importer leaked an absolute fixture path into canonical evidence.\n' >&2
  exit 1
fi

validate_previous_manifest() {
  python3 "$importer" --repo-root "$work/repo" --validate-existing >/dev/null
}

validate_previous_manifest
provenance_sidecar=$work/repo/docs/evidence/test-surface/test-surface--default--en-us-utf-8--1x.json
cp -- "$provenance_sidecar" "$work/provenance-sidecar.json"
jq '.run_id = "run-forged"' "$provenance_sidecar" >"$provenance_sidecar.tmp"
mv -- "$provenance_sidecar.tmp" "$provenance_sidecar"
if validate_previous_manifest >/dev/null 2>&1; then
  printf 'Existing manifest accepted forged sidecar run provenance.\n' >&2
  exit 1
fi
mv -- "$work/provenance-sidecar.json" "$provenance_sidecar"
validate_previous_manifest

cp -- "$provenance_sidecar" "$work/provenance-sidecar.json"
jq '.auxiliary_outputs[0].semantic_content.normalized_standard_deviation = 0' \
  "$provenance_sidecar" >"$provenance_sidecar.tmp"
mv -- "$provenance_sidecar.tmp" "$provenance_sidecar"
if validate_previous_manifest >/dev/null 2>&1; then
  printf 'Existing manifest accepted blank auxiliary semantic content.\n' >&2
  exit 1
fi
mv -- "$work/provenance-sidecar.json" "$provenance_sidecar"
validate_previous_manifest

canonical_aux_relative=$(jq -r '.auxiliary_outputs[0].image' "$provenance_sidecar")
canonical_aux=$work/repo/$canonical_aux_relative
cp -- "$canonical_aux" "$work/canonical-auxiliary.webp"
cp -- "$provenance_sidecar" "$work/provenance-sidecar.json"
magick -size 100x100 xc:'#0a0c3e' "$canonical_aux"
forged_aux_hash=$(sha256sum "$canonical_aux" | awk '{print $1}')
forged_semantic_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq \
  --arg image_sha "$forged_aux_hash" \
  --arg semantic_sha "$forged_semantic_sha" \
  '.auxiliary_outputs[0].image_sha256 = $image_sha
    | .auxiliary_outputs[0].semantic_content = {sha256:$semantic_sha,
      unique_gray_values:32,normalized_standard_deviation:0.1}
    | .semantic_outputs["HEADLESS-AUX"] = $semantic_sha' \
  "$provenance_sidecar" >"$provenance_sidecar.tmp"
mv -- "$provenance_sidecar.tmp" "$provenance_sidecar"
if validate_previous_manifest >/dev/null 2>&1; then
  printf 'Existing manifest accepted a uniform auxiliary image with forged metrics.\n' >&2
  exit 1
fi
mv -- "$work/canonical-auxiliary.webp" "$canonical_aux"
mv -- "$work/provenance-sidecar.json" "$provenance_sidecar"
validate_previous_manifest

cp -- "$work/repo/docs/evidence/vm-run.json" "$work/vm-run.valid.json"
jq '.runs[1].captures += 1' "$work/vm-run.valid.json" \
  >"$work/repo/docs/evidence/vm-run.json"
if validate_previous_manifest >/dev/null 2>&1; then
  printf 'Existing manifest accepted a forged aggregate capture count.\n' >&2
  exit 1
fi
mv -- "$work/vm-run.valid.json" "$work/repo/docs/evidence/vm-run.json"
validate_previous_manifest

if python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
  --surface test-surface \
  >/dev/null 2>&1; then
  printf 'Importer unexpectedly replaced canonical evidence.\n' >&2
  exit 1
fi

printf 'VM UI evidence importer tests passed.\n'
