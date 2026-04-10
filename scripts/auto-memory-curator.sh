#!/usr/bin/env bash
# Automated mode: updates lessons-learned.md and session memory when enough new handoffs accumulate.
# Triggered by launchd every 120 min.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK=".ai/state/locks/memory-curator.lock"
LOG=".ai/logs/memory-curator-scheduler.log"
AGENT_LOG=".ai/logs/memory-curator-agent.log"
STATE=".ai/state/memory-curator-state.json"
LESSONS=".ai/context/lessons-learned.md"
THRESHOLD=10  # min new handoffs since last run
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Prevent overlapping runs
if [ -f "$LOCK" ]; then
  echo "[$TS] memory-curator lock held — skipping" >> "$LOG"
  exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "[$TS] memory-curator loop starting" >> "$LOG"

# Check if enough new handoffs have accumulated
SHOULD_RUN=$(python3 - <<PY
import json, glob, os

handoffs_now = len(glob.glob(".ai/handoffs/*-impl.md")) + len(glob.glob(".ai/handoffs/*-validate.md"))

with open("${STATE}") as f:
    state = json.load(f)
count_at_last = state.get("handoff_count_at_last_run", 0)

print("yes" if (handoffs_now - count_at_last) >= ${THRESHOLD} else "no")
PY
)

if [ "$SHOULD_RUN" != "yes" ]; then
  echo "[$TS] Not enough new handoffs since last run. Skipping." >> "$LOG"
  exit 0
fi

PROMPT=$(cat <<PROMPTEOF
You are the memory-curator agent. Do not rely on chat history.

Read in order:
1. AGENTS.md
2. .ai/context/lessons-learned.md (current state)
3. All .ai/handoffs/*.md files written since the last memory-curator run
4. .ai/state/queue.json — look for patterns in blocked/failed_validation tasks

Your job — dual role:

1. Update .ai/context/lessons-learned.md:
   - Add new imperative, evidence-based pitfall bullets for patterns you observe.
   - Format: - [YYYY-MM-DD] PITFALL: <short imperative description>. Evidence: <handoff ref or command>.
   - Do not add prose, summaries, or generic advice — only specific, actionable pitfalls.
   - Do not remove existing entries unless they are demonstrably wrong.

2. Session memory (if project memory path exists at ~/.claude/projects/<project>/memory/):
   - Write or update memory files so future Claude Code sessions have accurate project context.
   - Focus on: architecture decisions, recurring patterns, ownership, known failure modes.

Do NOT modify queue.json, task files, or handoff files.
PROMPTEOF
)

echo "[$TS] Running memory-curator agent." >> "$LOG"
echo "$PROMPT" | claude --print --dangerously-skip-permissions >> "$AGENT_LOG" 2>&1 || \
  echo "$PROMPT" | codex --quiet >> "$AGENT_LOG" 2>&1

# Update state
python3 - <<PY
import json, glob
from datetime import datetime, timezone

handoffs_now = len(glob.glob(".ai/handoffs/*-impl.md")) + len(glob.glob(".ai/handoffs/*-validate.md"))

with open("${STATE}") as f:
    state = json.load(f)
state["handoff_count_at_last_run"] = handoffs_now
state["last_run"] = datetime.now(timezone.utc).isoformat()

with open("${STATE}", "w") as f:
    json.dump(state, f, indent=2)
PY

echo "[$TS] Memory-curator complete." >> "$LOG"
