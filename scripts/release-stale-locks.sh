#!/usr/bin/env bash
# Releases tasks that have been claimed or in_progress for more than 4 hours.
# Resets them to todo so they can be reclaimed.
set -euo pipefail
QUEUE=".ai/state/queue.json"

python3 - <<PY
import json
from datetime import datetime, timezone, timedelta

with open("${QUEUE}") as f:
    tasks = json.load(f)

now = datetime.now(timezone.utc)
for task in tasks:
    if task.get("status") in ["claimed", "in_progress"]:
        updated = task.get("last_updated")
        if updated:
            dt = datetime.fromisoformat(updated)
            if now - dt > timedelta(hours=4):
                task["status"] = "todo"
                task["owner"] = None
                task["resume_from"] = "stale lock released"
                task["last_updated"] = now.isoformat()
                task.setdefault("owner_history", []).append({
                    "event": "stale_lock_released",
                    "at": task["last_updated"]
                })

with open("${QUEUE}", "w") as f:
    json.dump(tasks, f, indent=2)
PY
