#!/usr/bin/env bash
# Automated mode: runs the reviewer-architectural agent when enough done tasks accumulate.
# Triggered by launchd every 60 min. Writes findings to .ai/handoffs/ and kickstarts product-owner.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK=".ai/state/locks/reviewer.lock"
LOG=".ai/logs/reviewer-scheduler.log"
AGENT_LOG=".ai/logs/reviewer-agent.log"
STATE=".ai/state/arch-review-state.json"
PENDING=".ai/state/review-actions-pending.json"
THRESHOLD=5   # min new done tasks since last review
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
STAMP=$(date -u +"%Y%m%dT%H%M")

# Prevent overlapping runs
if [ -f "$LOCK" ]; then
  echo "[$TS] reviewer lock held — skipping" >> "$LOG"
  exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "[$TS] reviewer loop starting" >> "$LOG"

# Check if enough new done tasks have accumulated since last review
SHOULD_RUN=$(python3 - <<PY
import json
with open(".ai/state/queue.json") as f:
    tasks = json.load(f)
done_now = sum(1 for t in tasks if t.get("status") == "done")

with open("${STATE}") as f:
    state = json.load(f)
done_at_last = state.get("done_count_at_last_review", 0)

print("yes" if (done_now - done_at_last) >= ${THRESHOLD} else "no")
PY
)

if [ "$SHOULD_RUN" != "yes" ]; then
  echo "[$TS] Not enough new done tasks since last review. Skipping." >> "$LOG"
  exit 0
fi

HANDOFF=".ai/handoffs/arch-review-${STAMP}.md"

PROMPT=$(cat <<PROMPTEOF
You are the reviewer-architectural agent. Do not rely on chat history.

Read in order:
1. AGENTS.md
2. CLAUDE.md
3. .ai/context/architecture.md
4. .ai/context/lessons-learned.md (if it exists)
5. .ai/state/queue.json — review all done tasks since last review
6. The most recent .ai/handoffs/*.md files for those tasks

Your job:
- Analyse the live codebase for architectural drift, design debt, and security issues.
- Identify Critical and High severity findings only.
- Write a structured findings handoff to ${HANDOFF}.
- Do NOT modify queue.json or create task files — findings go to the handoff only.
- Write .ai/state/review-actions-pending.json with findings for the product-owner.

Handoff format:
## summary
[2-4 sentences]

## findings
- severity: [Critical|High|Medium]
  area: [file or module]
  issue: [description]
  recommendation: [specific action]

## actioned
false
PROMPTEOF
)

echo "[$TS] Running reviewer agent. Handoff: $HANDOFF" >> "$LOG"
echo "$PROMPT" | claude --print --dangerously-skip-permissions >> "$AGENT_LOG" 2>&1 || \
  echo "$PROMPT" | codex --quiet >> "$AGENT_LOG" 2>&1

# Update state
python3 - <<PY
import json
from datetime import datetime, timezone

with open(".ai/state/queue.json") as f:
    tasks = json.load(f)
done_now = sum(1 for t in tasks if t.get("status") == "done")

with open("${STATE}") as f:
    state = json.load(f)
state["done_count_at_last_review"] = done_now
state["last_handoff"] = "${HANDOFF}"
state["last_run"] = datetime.now(timezone.utc).isoformat()

with open("${STATE}", "w") as f:
    json.dump(state, f, indent=2)
PY

echo "[$TS] Reviewer complete. Kickstarting product-owner." >> "$LOG"

# Kickstart product-owner immediately
launchctl kickstart -k "gui/$(id -u)/com.myproject.product-owner" 2>/dev/null || true
