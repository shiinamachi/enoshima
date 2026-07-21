#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
importer=$repo_root/scripts/ui-capture/import-vm-run
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -p \
  "$work/repo/docs/assets" \
  "$work/repo/docs/concepts" \
  "$work/repo/home/dot_config/quickshell/cyberdock" \
  "$work/run-fixture/artifacts/ui-review" \
  "$work/run-fixture/artifacts/screenshots"

printf 'import QtQuick\nRectangle { width: 100; height: 100 }\n' \
  >"$work/repo/home/dot_config/quickshell/cyberdock/Test.qml"
printf 'surface_id: test-surface\nstates: [default]\nacceptance: [Visible.]\n' \
  >"$work/repo/docs/concepts/test-surface.yaml"

python3 - "$work/repo/docs/assets/concept.png" \
  "$work/run-fixture/artifacts/screenshots/capture.png" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

def png(path: Path) -> None:
    width = height = 100
    raw = b''.join(b'\0' + b'\x05\x06\x23' * width for _ in range(height))
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

for value in sys.argv[1:]:
    png(Path(value))
PY

concept_sha=$(sha256sum "$work/repo/docs/assets/concept.png" | awk '{print $1}')
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
      implementation_digest: null
      captures: []
      review: null
exemptions: {}
EOF

git -C "$work/repo" init -q
git -C "$work/repo" config user.name Test
git -C "$work/repo" config user.email test@example.invalid
git -C "$work/repo" add .
git -C "$work/repo" commit -qm fixture
commit=$(git -C "$work/repo" rev-parse HEAD)
image=$work/run-fixture/artifacts/screenshots/capture.png
image_sha=$(sha256sum "$image" | awk '{print $1}')

captures=0
for locale in en_US.UTF-8 ko_KR.UTF-8; do
  locale_slug=${locale,,}
  locale_slug=${locale_slug//./-}
  locale_slug=${locale_slug//_/-}
  for scale in 1 1.25 2; do
    stem="test-surface--default--$locale_slug--${scale}x"
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
        run_id:"run-fixture",source_commit:$commit,worktree_hash:"sha256:fixture",
        implementation_digest:$implementation,concept_sha256:$concept,
        text_overflow_count:0,fixture:{used:true,reason:"test"}}' \
      >"$work/run-fixture/artifacts/ui-review/$stem.json"
    captures=$((captures + 1))
  done
done

jq -n --argjson count "$captures" \
  '{schema:1,expected:$count,actual:$count,surfaces:["test-surface"],
    locales:["en_US.UTF-8","ko_KR.UTF-8"],scales:[1,1.25,2],
    text_overflow_failures:[]}' \
  >"$work/run-fixture/artifacts/ui-review/summary.json"
printf '<testsuite tests="1" failures="0"/>\n' >"$work/run-fixture/artifacts/junit.xml"

jq -n \
  --arg commit "$commit" \
  --arg artifacts "$work/run-fixture/artifacts" \
  '{run_id:"run-fixture",suite:"ui-review",status:"completed",
    source:{source_commit:$commit,dirty:false,worktree_hash:"sha256:fixture",
      untracked_files:[]},artifact_dir:$artifacts,
    steps:[{action:"run_ui_review",status:"passed"},
      {action:"collect_artifacts",status:"passed"}]}' \
  >"$work/run-fixture/run.json"

output=$(python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture")
jq -e '.captures == 6 and .surfaces == 1' <<<"$output" >/dev/null
test "$(find "$work/repo/docs/evidence/test-surface" -name '*.json' | wc -l)" -eq 6
test "$(find "$work/repo/docs/evidence/test-surface" -name '*.webp' | wc -l)" -eq 6
jq -e '.actual_captures == 6' "$work/repo/docs/evidence/vm-run.json" >/dev/null

if python3 "$importer" --repo-root "$work/repo" --run-dir "$work/run-fixture" \
  >/dev/null 2>&1; then
  printf 'Importer unexpectedly replaced canonical evidence.\n' >&2
  exit 1
fi

printf 'VM UI evidence importer tests passed.\n'
