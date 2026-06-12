---
description: Run the full AgentHub test suite (packages + AgentHubCore) and report results
---

Run the complete AgentHub test gate and report the outcome clearly.

Run: `./scripts/test.sh`

(Subsets, if the user passed an argument like `core` or `packages`: `./scripts/test.sh $ARGUMENTS`.)

This compiles and runs the fast `swift test` module packages, then the full `AgentHubCore`
xcodebuild suite (with per-test timeouts). It can take several minutes on a cold build — run it
in the background and wait for completion rather than blocking.

Report back:
- Overall pass/fail and the per-target results.
- Any failing tests by name, with the assertion that failed.
- Any tests **skipped** via `.disabled("headless-quarantine: …")` — these are known-broken and
  tracked in `TestQuarantine.md` / issue #380. Do **not** report skips as passes, and do **not**
  treat them as new failures.

Do not declare success unless `scripts/test.sh` exits 0.
