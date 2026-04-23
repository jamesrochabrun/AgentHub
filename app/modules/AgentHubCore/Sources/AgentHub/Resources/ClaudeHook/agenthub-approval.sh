#!/bin/bash
# AgentHub Claude Code approval hook
#
# Invoked by Claude Code on PreToolUse (and optionally PostToolUse).
# Reads a single JSON object from stdin, checks whether AgentHub is actively
# monitoring this session (claim file), and if so appends a JSON line to the
# session's approval queue. Otherwise exits silently.
#
# Design invariants:
#   1. Exit 0 on every error path. Never block Claude Code, never print to the
#      user's terminal.
#   2. Do not mutate state outside AgentHub's Application Support directory.
#   3. Produce no output on stdout or stderr under any condition.
#
# Contract with AgentHub:
#   Claims dir:   ~/Library/Application Support/AgentHub/claims/{sessionId}
#   Approvals:    ~/Library/Application Support/AgentHub/approvals/{sessionId}.jsonl

set +e
exec 2>/dev/null

APP_SUPPORT="${HOME}/Library/Application Support/AgentHub"
CLAIMS_DIR="${APP_SUPPORT}/claims"
APPROVALS_DIR="${APP_SUPPORT}/approvals"

INPUT="$(cat 2>/dev/null || true)"
[ -z "${INPUT}" ] && exit 0

# Parse the hook JSON and the claim gate in one Python invocation.
# On any error: exit 0 silently. On success: print nothing — the script has
# already appended to the sidecar.
printf '%s' "${INPUT}" | python3 -c '
import json, os, sys, datetime
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

sid = data.get("session_id") or ""
event = data.get("hook_event_name") or ""
tool = data.get("tool_name") or ""
tool_input = data.get("tool_input") or {}
tool_use_id = data.get("tool_use_id") or ""

if not sid:
    sys.exit(0)

home = os.path.expanduser("~")
app_support = os.path.join(home, "Library", "Application Support", "AgentHub")
claim_path = os.path.join(app_support, "claims", sid)
approvals_dir = os.path.join(app_support, "approvals")

# Gate: no claim means AgentHub is not tracking this session; exit silently.
if not os.path.exists(claim_path):
    sys.exit(0)

if event == "PreToolUse":
    kind = "pending"
elif event == "PostToolUse":
    kind = "resolved"
else:
    sys.exit(0)

try:
    os.makedirs(approvals_dir, exist_ok=True)
except Exception:
    sys.exit(0)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
line = {
    "event": kind,
    "toolName": tool,
    "toolUseId": tool_use_id,
    "timestamp": ts,
    "input": tool_input,
}
out_path = os.path.join(approvals_dir, sid + ".jsonl")
try:
    with open(out_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(line, separators=(",", ":")) + "\n")
except Exception:
    pass
sys.exit(0)
' 2>/dev/null

exit 0
