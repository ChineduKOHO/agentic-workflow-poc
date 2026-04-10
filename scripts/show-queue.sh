#!/usr/bin/env bash
# Pretty-prints queue.json as a summary table.
# Usage: ./scripts/show-queue.sh
set -euo pipefail
cd "$(dirname "$0")/.."

QUEUE=".ai/state/queue.json"

if [ ! -f "$QUEUE" ]; then
  echo "Queue file not found: $QUEUE"
  exit 1
fi

python3 - <<'PY'
import json
from collections import Counter

with open(".ai/state/queue.json") as f:
    tasks = json.load(f)

if not tasks:
    print("Queue is empty.")
    exit(0)

# Status summary
counts = Counter(t.get("status", "unknown") for t in tasks)
print("\n=== QUEUE SUMMARY ===")
for status, count in sorted(counts.items()):
    print(f"  {status:<20} {count}")
print(f"  {'TOTAL':<20} {len(tasks)}")

# Full table
print("\n=== ALL TASKS ===")
header = f"{'ID':<12} {'TYPE':<12} {'STATUS':<20} {'OWNER':<22} {'PRI':<5} TITLE"
print(header)
print("-" * 90)
for t in sorted(tasks, key=lambda x: x.get("priority", 999)):
    tid    = t.get("id", "?")[:11]
    ttype  = t.get("task_type", "?")[:11]
    status = t.get("status", "?")[:19]
    owner  = (t.get("owner") or "-")[:21]
    pri    = str(t.get("priority", "?"))[:4]
    title  = t.get("title", "")[:50]
    print(f"{tid:<12} {ttype:<12} {status:<20} {owner:<22} {pri:<5} {title}")

# Blocked tasks
blocked = [t for t in tasks if t.get("status") == "blocked"]
if blocked:
    print("\n=== BLOCKED TASKS ===")
    for t in blocked:
        print(f"  {t['id']}: {t.get('title','?')}")
        print(f"    resume_from: {t.get('resume_from','?')}")
        print(f"    handoff: .ai/handoffs/{t['id']}-impl.md")
PY
