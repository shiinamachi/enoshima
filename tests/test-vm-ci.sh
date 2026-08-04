#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
validate=$repo_root/.github/workflows/validate.yml
trusted=$repo_root/.github/workflows/vm-trusted.yml
boot=$repo_root/.github/workflows/vm-boot-security.yml

fail() {
  printf 'VM CI contract test failed: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'pull_request:' "$validate" ||
  fail 'static validation does not run for pull requests'
grep -Fq 'runs-on: ubuntu-latest' "$validate" ||
  fail 'pull-request validation is not GitHub-hosted'
grep -Fq 'runuser --user ci' "$validate" ||
  fail 'static validation would run makepkg as the root container user'

for workflow in "$trusted" "$boot"; do
  if grep -Eq '^[[:space:]]*pull_request(_target)?:' "$workflow"; then
    fail "trusted KVM workflow accepts pull-request code: $workflow"
  fi
  grep -Fq 'contents: read' "$workflow" ||
    fail "trusted KVM workflow lacks read-only repository permissions: $workflow"
  grep -Fq 'runs-on: [self-hosted, linux, x64, enoshima-kvm, trusted]' "$workflow" ||
    fail "trusted KVM runner labels are incomplete: $workflow"
  grep -Fq 'group: enoshima-kvm' "$workflow" ||
    fail "KVM jobs are not serialized: $workflow"
  grep -Fq 'if: always()' "$workflow" ||
    fail "KVM workflow lacks unconditional cleanup: $workflow"
  grep -Fq '/runs/*/artifacts/**' "$workflow" ||
    fail "KVM workflow does not upload the bounded artifact tree: $workflow"
  grep -Fq 'id: upload-evidence' "$workflow" ||
    fail "KVM workflow does not expose evidence upload outcome: $workflow"
  grep -Fq 'github.run_attempt' "$workflow" ||
    fail "KVM reruns do not use attempt-specific evidence identity: $workflow"
  grep -Fq "if: always() && steps.upload-evidence.outcome == 'success'" "$workflow" ||
    fail "KVM workflow deletes reports before confirming evidence upload: $workflow"
  if grep -Fq 'ENOSHIMA_VM_STATE_ROOT }}/**' "$workflow"; then
    fail "KVM workflow could upload disposable private keys: $workflow"
  fi
done

grep -Fq 'branches: [main]' "$trusted" ||
  fail 'trusted integration is not restricted to main pushes'
grep -Fq 'fetch-depth: 0' "$trusted" ||
  fail 'trusted integration cannot resolve a multi-commit push base'
grep -Fq 'timeout-minutes: 4320' "$trusted" ||
  fail 'trusted release job cannot cover canonical suite retries and cleanup'
grep -Fq 'default: checkpoint' "$trusted" ||
  fail 'trusted manual dispatch does not default to affected checkpoint verification'
for choice in checkpoint release smoke converge reboot desktop login ui-review full; do
  grep -Fq -- "- $choice" "$trusted" ||
    fail "trusted manual dispatch does not expose $choice"
done
grep -Fq "REQUESTED_SUITE: \${{ inputs.suite || 'checkpoint' }}" "$trusted" ||
  fail 'trusted main pushes do not select affected checkpoint verification'
grep -Fq "ENOSHIMA_PUSH_BASE: \${{ github.event.before }}" "$trusted" ||
  fail 'trusted main pushes do not retain the complete pre-push base'
grep -Fq 'checkpoint_base=origin/main' "$trusted" ||
  fail 'manual checkpoints do not compare the full branch with origin/main'
[[ $(grep -Fc "make vm-checkpoint BASE=\"\$checkpoint_base\"" "$trusted") -eq 1 ]] ||
  fail 'main pushes do not run exactly one affected checkpoint from the push base'
grep -Fq "release|full) make vm-release BASE=\"\$checkpoint_base\" ;;" "$trusted" ||
  fail 'trusted release choices do not use the single canonical release plan'
if grep -Eq 'make vm-(trusted|full)' "$trusted"; then
  fail 'trusted dispatcher bypasses the canonical checkpoint or release command'
fi
grep -Fq 'smoke|converge|reboot|desktop|login|ui-review' "$trusted" ||
  fail 'trusted dispatcher does not route individual diagnostic suites'
grep -Fq '/plans/*/plan.json' "$trusted" ||
  fail 'trusted workflow does not upload the authoritative verification report'
grep -Fq '/checks/**' "$trusted" ||
  fail 'trusted workflow does not retain focused-check logs referenced by the report'
grep -Fq 'workflow_dispatch:' "$boot" ||
  fail 'boot-security workflow cannot be started manually'
grep -Fq 'schedule:' "$boot" ||
  fail 'boot-security workflow lacks its trusted scheduled lane'
grep -Fq 'timeout-minutes: 720' "$boot" ||
  fail 'boot-security workflow cannot cover one fresh-overlay retry and cleanup'
grep -Fq '/checks/**' "$boot" ||
  fail 'boot-security workflow does not retain focused-check evidence'

printf 'VM CI trust-boundary tests passed.\n'
