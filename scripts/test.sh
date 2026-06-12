#!/usr/bin/env bash
#
# AgentHub test entry point — the single gate agents, humans, and CI all invoke.
#
# Usage:
#   scripts/test.sh             # packages (fast) then core (slow)  [default]
#   scripts/test.sh core        # AgentHubCore xcodebuild suite only
#   scripts/test.sh packages    # fast `swift test` packages only
#
# Notes:
#   - The AgentHubCore suite cannot run under `swift test`: it depends on
#     CodeEditSourceEditor -> CodeEditSymbols, whose xcassets are not declared
#     as an SPM resource (fine under Xcode's build system, fatal under the SPM
#     CLI). It is therefore driven via `xcodebuild` against the shared
#     `AgentHubCore-Tests` scheme.
#   - Ghostty is intentionally excluded from the fast subset: it depends on
#     AgentHubCore and hits the same CodeEditSymbols wall under `swift test`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES="$ROOT/app/modules"

# Packages that build & test cleanly under the SPM CLI (no heavy GUI deps).
SWIFT_TEST_PACKAGES=(
  AgentHubCLI
  AgentHubGitHub
  SimulatorPreview
  Storybook
)

FAILURES=()

run_packages() {
  for pkg in "${SWIFT_TEST_PACKAGES[@]}"; do
    echo ""
    echo "▶ swift test: $pkg"
    if ( cd "$MODULES/$pkg" && swift test ); then
      echo "✓ $pkg"
    else
      echo "✗ $pkg"
      FAILURES+=("swift test: $pkg")
    fi
  done
}

run_core() {
  echo ""
  echo "▶ xcodebuild test: AgentHubCore (scheme AgentHubCore-Tests)"
  # Optional .xcresult bundle (CI sets this to upload on failure).
  local result_bundle_args=()
  if [ -n "${AGENTHUB_TEST_RESULT_BUNDLE:-}" ]; then
    rm -rf "$AGENTHUB_TEST_RESULT_BUNDLE"
    result_bundle_args=(-resultBundlePath "$AGENTHUB_TEST_RESULT_BUNDLE")
  fi
  # Per-test timeouts keep a single hanging test from blocking the whole gate
  # forever (the suite has a few service tests that can block headlessly).
  if ( cd "$MODULES/AgentHubCore" && \
       xcodebuild test \
         -scheme AgentHubCore-Tests \
         -destination 'platform=macOS' \
         -test-timeouts-enabled YES \
         -default-test-execution-time-allowance 60 \
         -maximum-test-execution-time-allowance 120 \
         "${result_bundle_args[@]+"${result_bundle_args[@]}"}" \
         -skipPackagePluginValidation ); then
    echo "✓ AgentHubCore"
  else
    echo "✗ AgentHubCore"
    FAILURES+=("xcodebuild test: AgentHubCore")
  fi
}

case "${1:-all}" in
  core)     run_core ;;
  packages) run_packages ;;
  all)      run_packages; run_core ;;   # cheap failures surface first
  *)        echo "usage: scripts/test.sh [all|core|packages]" >&2; exit 2 ;;
esac

echo ""
if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ Failures:"
  for f in "${FAILURES[@]}"; do echo "   - $f"; done
  exit 1
fi
