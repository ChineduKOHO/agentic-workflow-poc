#!/usr/bin/env bash
# Usage: ./scripts/claim-task.sh <agent-name> <task-type>
# Example: ./scripts/claim-task.sh backend-engineer backend
# Atomically claims the next eligible task. Prints the task ID on stdout.
set -euo pipefail

AGENT_NAME="${1:-unknown}"
TASK_TYPE="${2:-any}"
QUEUE=".ai/state/queue.json"

python3 - <<PY
import json
from datetime import datetime, timezone

with open("${QUEUE}") as f:
    tasks = json.load(f)

done_ids = {t["id"] for t in tasks if t.get("status") == "done"}

def deps_satisfied(task):
    return all(dep in done_ids for dep in task.get("depends_on", []))

def eligible(task):
    return (
        task.get("status") in ["todo", "failed_validation"]
        and not task.get("owner")
        and deps_satisfied(task)
        and ("${TASK_TYPE}" == "any" or task.get("task_type") == "${TASK_TYPE}")
    )

for task in sorted(tasks, key=lambda x: x.get("priority", 999)):
    if eligible(task):
        task["status"] = "claimed"
        task["owner"] = "${AGENT_NAME}"
        task["last_updated"] = datetime.now(timezone.utc).isoformat()
        task.setdefault("owner_history", []).append({
            "event": "claimed",
            "agent": "${AGENT_NAME}",
            "at": task["last_updated"]
        })
        print(task["id"])
        with open("${QUEUE}", "w") as f:
            json.dump(tasks, f, indent=2)
        raise SystemExit(0)

raise SystemExit(1)
PY
