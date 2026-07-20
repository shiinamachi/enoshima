#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
validator=$repo_root/.agents/skills/enoshima-concept-art/scripts/validate-concept-manifest
capture=$repo_root/scripts/ui-capture/capture-surface
score=$repo_root/scripts/ui-capture/score-surface
analyze=$repo_root/scripts/ui-capture/analyze-surface
grep -Fq '"-blur"' "$analyze" || {
  printf 'Visual analyzer omits semantic normalization.\n' >&2
  exit 1
}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

mkdir -p "$work/docs/concepts" "$work/docs/assets" \
  "$work/home/dot_config/quickshell/cyberdock" "$work/sources"
printf 'import QtQuick\nRectangle { width: 100; height: 100; color: "transparent" }\n' \
  >"$work/home/dot_config/quickshell/cyberdock/Test.qml"
printf '%s\n' \
  'surface_id: test-surface' \
  'states: [default]' \
  'acceptance: [The fixture renders.]' >"$work/docs/concepts/test-surface.yaml"

python3 - "$work/docs/assets/concept.png" "$work/sources" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

def png(path, width, height):
    raw = b''.join(b'\0' + b'\x05\x06\x23' * width for _ in range(height))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))

concept = Path(sys.argv[1])
sources = Path(sys.argv[2])
png(concept, 100, 100)
png(sources / '1.png', 100, 100)
png(sources / '1.25.png', 100, 100)
png(sources / '2.png', 100, 100)
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
      status: pending
      required_states: [default]
      required_locales: [en_US.UTF-8, ko_KR.UTF-8]
      required_scales: [1.0, 1.25, 2.0]
      implementation_digest: null
      captures: []
      review: null
exemptions: {}
EOF

python3 "$validator" "$work/docs/ui-surfaces.yaml" >/dev/null
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Pending evidence unexpectedly passed the release gate.\n' >&2
  exit 1
fi

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
      status: approved
      required_states: [default]
      required_locales: [en_US.UTF-8, ko_KR.UTF-8]
      required_scales: [1.0, 1.25, 2.0]
      implementation_digest: $implementation_digest
      captures:
EOF
  for sidecar in "${sidecars[@]}"; do printf '        - %s\n' "$sidecar"; done
  printf '      review: %s\n' "$review"
  printf 'exemptions: {}\n'
} >"$work/docs/ui-surfaces.yaml"

python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null
printf '// implementation drift\n' >>"$work/home/dot_config/quickshell/cyberdock/Test.qml"
if python3 "$validator" --require-evidence "$work/docs/ui-surfaces.yaml" >/dev/null 2>&1; then
  printf 'Stale evidence unexpectedly passed after implementation drift.\n' >&2
  exit 1
fi

printf 'UI visual evidence gate tests passed.\n'
