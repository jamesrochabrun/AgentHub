#!/bin/sh
# Points this clone's hooks at the tracked scripts/git_hooks directory, so the
# leak guard is version-controlled and shared instead of living untracked in
# .git/hooks. Safe to re-run. Run once per clone (and per new worktree parent).
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

chmod +x scripts/git_hooks/commit-msg scripts/git_hooks/pre-commit scripts/git_hooks/leak_guard.py
git config core.hooksPath scripts/git_hooks

echo "hooks installed -> $(git config --get core.hooksPath)"
echo "verify: scripts/git_hooks/leak_guard.py --stdin <<< 'some text'"
