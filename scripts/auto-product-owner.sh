#!/usr/bin/env bash
# Automated mode: reads reviewer findings and converts Critical/High items into tasks.
# Triggered by launchd every 30 min, and immediately after each reviewer run.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK=".ai/state/locks/product-owner.lock"
LOG=".ai/logs/product-owner-scheduler.log"
AGENT_LOG=".ai/logs/product-owner-agent.log"
PENDING=".ai/state/review-actions-pending.json"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Prevent overlapping runs
if [ -f "$LOCK" ]; then
  echo "[$TS] product-owner lock held — skipping" >> "$LOG"
  exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "[$TS] product-owner loop starting" >> "$LOG"

# Check for unactioned reviewer findings
HAS_PENDING=$(python3 - <<PY
import json, os
if not os.path.exists("${PENDING}"):
    print("no")
else:
    with open("${PENDING}") as f:
        items = json.load(f)
    print("yes" if any(not item.get("actioned") for item in items) else "no")
PY
)

if [ "$HAS_PENDING" != "yes" ]; then
  echo "[$TS] No unactioned reviewer findings. Skipping." >> "$LOG"
  exit 0
fi

PROMPT=$(cat <<PROMPTEOF
You are the product-owner agent. Do not rely on chat history.

Read in order:
1. AGENTS.md
2. CLAUDE.md
3. .ai/context/product.md
4. .ai/context/architecture.md
5. .ai/state/queue.json
6. .ai/state/review-actions-pending.json — process all entries where actioned is false
7. The handoff file referenced in each pending entry

Your job:
- Convert Critical and High severity findings into .ai/tasks/<id>.md files and queue.json entries.
- Skip findings already covered by existing todo/in_progress/done tasks (check by title similarity).
- Use the next available task ID (max existing ID + 1).
- Set actioned: true on each processed entry in review-actions-pending.json.
- After updating queue.json, do not kickstart implementers — that happens automatically on next loop.

Task file format: follow .ai/tasks/TEMPLATE.md exactly.
Queue entry: follow existing queue.json schema exactly.
PROMPTEOF
)

echo "[$TS] Running product-owner agent." >> "$LOG"
echo "$PROMPT" | claude --print --dangerously-skip-permissions >> "$AGENT_LOG" 2>&1 || \
  echo "$PROMPT" | codex --quiet >> "$AGENT_LOG" 2>&1

echo "[$TS] Product-owner complete." >> "$LOG"
