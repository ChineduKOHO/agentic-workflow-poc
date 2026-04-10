#!/usr/bin/env bash
# Usage: ./scripts/fix-task.sh <blocked-task-id>
# Resolves a blocked task by creating a typed fix task pre-filled from the handoff.
# Wires the dependency and resets the blocked task to todo.
set -euo pipefail
cd "$(dirname "$0")/.."

BLOCKED_ID="${1:-}"
QUEUE=".ai/state/queue.json"

if [ -z "$BLOCKED_ID" ]; then
  echo "Usage: ./scripts/fix-task.sh <task-id>"
  exit 1
fi

# Verify task is blocked
STATUS=$(python3 -c "
import json
with open('${QUEUE}') as f:
    tasks = json.load(f)
match = next((t for t in tasks if t['id'] == '${BLOCKED_ID}'), None)
print(match.get('status','NOT_FOUND') if match else 'NOT_FOUND')
")

if [ "$STATUS" != "blocked" ]; then
  echo "Error: ${BLOCKED_ID} has status '${STATUS}', not 'blocked'."
  exit 1
fi

# Extract blocker text from handoff
HANDOFF=".ai/handoffs/${BLOCKED_ID}-impl.md"
BLOCKER_TEXT="(read .ai/handoffs/${BLOCKED_ID}-impl.md for details)"
if [ -f "$HANDOFF" ]; then
  BLOCKER_TEXT=$(python3 -c "
import re
text = open('${HANDOFF}').read()
m = re.search(r'## blockers?\s*\n(.*?)(\n## |\Z)', text, re.DOTALL | re.IGNORECASE)
print(m.group(1).strip() if m else '(see handoff file)')
")
fi

# Get next fix task ID
FIX_ID=$(python3 -c "
import json, re
with open('${QUEUE}') as f:
    tasks = json.load(f)
nums = [int(re.search(r'\d+', t['id']).group()) for t in tasks if re.search(r'\d+', t['id'])]
print(f'task-{max(nums)+1:03d}')
")

# Get original task metadata
ORIG_INFO=$(python3 -c "
import json
with open('${QUEUE}') as f:
    tasks = json.load(f)
t = next(t for t in tasks if t['id'] == '${BLOCKED_ID}')
print(t.get('task_type','supporting'))
print(t.get('title','unknown'))
print(t.get('sprint', 1))
")
ORIG_TYPE=$(echo "$ORIG_INFO" | sed -n '1p')
ORIG_TITLE=$(echo "$ORIG_INFO" | sed -n '2p')
ORIG_SPRINT=$(echo "$ORIG_INFO" | sed -n '3p')

# Write fix task file
cat > ".ai/tasks/${FIX_ID}.md" <<TASKEOF
# ${FIX_ID}

## title
Fix blocker for ${BLOCKED_ID}: ${ORIG_TITLE}

## task_type
${ORIG_TYPE}

## sprint
${ORIG_SPRINT}

## objective
Resolve the blocker that caused ${BLOCKED_ID} to stall.
Read .ai/handoffs/${BLOCKED_ID}-impl.md for full context.

Blocker reported:
${BLOCKER_TEXT}

## acceptance_criteria
- the blocker described above is resolved
- ${BLOCKED_ID} can be claimed and completed after this task is done

## validation_commands
- go build ./...

## dependencies
- (none — this fix is a prerequisite)
TASKEOF

# Update queue: add fix task, reset blocked task
python3 - <<PY
import json
from datetime import datetime, timezone

now = datetime.now(timezone.utc).isoformat()
with open("${QUEUE}") as f:
    tasks = json.load(f)

max_p = max(t.get("priority", 0) for t in tasks)
tasks.append({
    "id": "${FIX_ID}", "title": "Fix blocker for ${BLOCKED_ID}: ${ORIG_TITLE}",
    "task_type": "${ORIG_TYPE}", "sprint": int("${ORIG_SPRINT}"),
    "status": "todo", "owner": None, "priority": max_p + 1,
    "depends_on": [], "task_file": ".ai/tasks/${FIX_ID}.md",
    "acceptance": ["Blocker resolved", "${BLOCKED_ID} can proceed"],
    "validation_commands": ["go build ./..."],
    "last_updated": now, "resume_from": "fix for blocked task ${BLOCKED_ID}"
})

for t in tasks:
    if t["id"] == "${BLOCKED_ID}":
        t["status"] = "todo"; t["owner"] = None
        t["resume_from"] = "fix task created: ${FIX_ID}"
        t["last_updated"] = now
        deps = t.setdefault("depends_on", [])
        if "${FIX_ID}" not in deps:
            deps.append("${FIX_ID}")
        t.setdefault("owner_history", []).append(
            {"event": "unblocked", "fix_task": "${FIX_ID}", "at": now})
        break

with open("${QUEUE}", "w") as f:
    json.dump(tasks, f, indent=2)
PY

echo "Fix task ${FIX_ID} created. ${BLOCKED_ID} reset to todo (depends on ${FIX_ID})."
