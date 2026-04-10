#!/usr/bin/env bash
# Manual mode: claims next backend task, creates worktree, prints Codex prompt.
# Usage: ./scripts/run-backend-loop.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/release-stale-locks.sh || true
TASK_ID=$(./scripts/claim-task.sh backend-engineer backend 2>/dev/null || true)

if [ -z "${TASK_ID:-}" ]; then
  echo "No eligible backend tasks."
  exit 0
fi

WT=$(./scripts/create-worktree.sh "$TASK_ID")

echo ""
echo "========================================================"
echo "  BACKEND TASK: $TASK_ID"
echo "  WORKTREE:     $WT"
echo "========================================================"
echo ""
echo "cd $(pwd)/$WT, then open codex and paste this prompt:"
echo ""
cat <<PROMPT
Resume from persistent state only. Do not rely on chat history.

Read in order:
1. AGENTS.md
2. CLAUDE.md
3. .ai/context/product.md
4. .ai/context/architecture.md
5. .ai/context/lessons-learned.md (if it exists)
6. .ai/state/queue.json — find task ${TASK_ID}
7. .ai/tasks/${TASK_ID}.md
8. .ai/handoffs/${TASK_ID}-impl.md — if it exists, resume from it

This is a backend task assigned to backend-engineer.
Implement only task ${TASK_ID}.
Run all validation_commands from the task file.
Write a handoff to .ai/handoffs/${TASK_ID}-impl.md.
Update queue.json status to implemented (or blocked with reason).
PROMPT
