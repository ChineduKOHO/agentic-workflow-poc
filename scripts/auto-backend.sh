#!/usr/bin/env bash
# Automated mode: claims next backend task and runs codex non-interactively.
# Invoked by launchd on a schedule (every 20 min).
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK=".ai/state/locks/backend.lock"
LOG=".ai/logs/backend-scheduler.log"
AGENT_LOG=".ai/logs/backend-agent.log"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Prevent overlapping runs
if [ -f "$LOCK" ]; then
  echo "[$TS] backend lock held — skipping" >> "$LOG"
  exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

echo "[$TS] backend loop starting" >> "$LOG"

./scripts/release-stale-locks.sh || true
TASK_ID=$(./scripts/claim-task.sh backend-engineer backend 2>/dev/null || true)

if [ -z "${TASK_ID:-}" ]; then
  echo "[$TS] No eligible backend tasks. Exiting." >> "$LOG"
  exit 0
fi

WT=$(./scripts/create-worktree.sh "$TASK_ID")
echo "[$TS] Claimed $TASK_ID. Worktree: $WT. Running codex..." >> "$LOG"

# Build the prompt
PROMPT=$(cat <<PROMPTEOF
Resume from persistent state only. Do not rely on chat history.
Read AGENTS.md, CLAUDE.md, .ai/context/product.md, .ai/context/architecture.md,
.ai/context/lessons-learned.md (if it exists),
.ai/state/queue.json (task ${TASK_ID}), .ai/tasks/${TASK_ID}.md,
and .ai/handoffs/${TASK_ID}-impl.md if it exists.
Implement only task ${TASK_ID}. Run all validation_commands.
Write .ai/handoffs/${TASK_ID}-impl.md. Update queue.json to implemented or blocked.
PROMPTEOF
)

# Run codex non-interactively in the worktree
cd "$WT"
echo "$PROMPT" | codex --quiet >> "$AGENT_LOG" 2>&1

echo "[$TS] $TASK_ID complete" >> "$LOG"

# Self-kickstart: immediately attempt next task after a successful run
cd "$(dirname "$0")/.."
exec ./scripts/auto-backend.sh
