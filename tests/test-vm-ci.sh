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
  if grep -Fq 'ENOSHIMA_VM_STATE_ROOT }}/**' "$workflow"; then
    fail "KVM workflow could upload disposable private keys: $workflow"
  fi
done

grep -Fq 'branches: [main]' "$trusted" ||
  fail 'trusted integration is not restricted to main pushes'
grep -Fq 'workflow_dispatch:' "$boot" ||
  fail 'boot-security workflow cannot be started manually'
grep -Fq 'schedule:' "$boot" ||
  fail 'boot-security workflow lacks its trusted scheduled lane'

printf 'VM CI trust-boundary tests passed.\n'
