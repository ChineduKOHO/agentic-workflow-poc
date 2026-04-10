# Claude + Codex Agent Collaboration Workflow
## A complete setup guide for persistent, resumable multi-agent development

---

## What this is

This is a workflow for running two agent runners (for example Claude Code and Codex CLI) as coordinated agents on the same codebase. Each agent picks up scoped tasks from a shared queue, implements or validates them in isolated git worktrees, writes structured handoffs, and updates shared state — all without relying on chat memory.

The result: work continues across usage limits, interrupted sessions, and CLI restarts. You never have to re-explain context. You check files, not chat history.

---

## Documentation maintenance policy

Use this guide as the reusable baseline for any repository. Keep it project-agnostic.

- Put project-specific operational details in that project repo docs (for example a local `docs/agent-workflow-operations.md` runbook).
- Update this guide only for cross-project improvements to workflow design, reliability, queue semantics, or automation architecture.
- Avoid hardcoding project names, paths, or launchd labels; prefer placeholders like `my-project`, `/path/to/project`, and `com.<project>.*`.
- If a deployment teaches a reusable lesson, capture the pattern here and keep case-study details minimal.

---

## The mental model

Think of it as a factory floor with four layers:

```
┌──────────────────────────────────────────────────┐
│  1. INSTRUCTIONS LAYER                           │
│     CLAUDE.md  ·  AGENTS.md                      │
│     (how agents behave)                          │
├──────────────────────────────────────────────────┤
│  2. STATE LAYER                                  │
│     .ai/state/queue.json                         │
│     .ai/tasks/*.md                               │
│     .ai/handoffs/*.md                            │
│     (what is happening and what happened)        │
├──────────────────────────────────────────────────┤
│  3. AGENT LAYER                                  │
│     product-owner · backend-engineer · fullstack-engineer│
│     ui-ux-designer · validator · state-manager   │
│     (who does what)                              │
├──────────────────────────────────────────────────┤
│  4. EXECUTION LAYER                              │
│     scripts/*.sh  ·  claude  ·  codex            │
│     git worktree                                 │
│     (how work gets triggered)                    │
└──────────────────────────────────────────────────┘
```

Agents never coordinate through conversation. They coordinate through files. The queue is the single source of truth.

---

## Reliability updates from a real deployment (April 3, 2026)

These workflow safeguards were implemented in a production repository and are generally reusable:

- `scripts/create-worktree.sh` auto-recreates stale task worktrees when required paths are missing (for example `backend/` or `.ai/tasks/<task-id>.md`), preventing repeated false blockers from old branches.
- `scripts/create-worktree.sh` symlinks `.ai/state` and `.ai/handoffs` into every task worktree so all agents write to the canonical `queue.json`. If a symlink is replaced by a real directory (from an old checkout), queue writes stay inside the worktree and are invisible to the main loop.
- Queue-mutating scripts now use per-process temp files and `os.replace(...)` for queue writes, reducing `queue.json` corruption from concurrent automation loops.
- Dependency cycle repair is automated (`scripts/repair-dependency-cycles.sh` + launchd service) so circular `depends_on` edges do not deadlock claiming.
- `scripts/sanitize-queue-self-containment.sh` runs inside every implementer and validator automation loop before a task is claimed. It repairs fix-task dependency edges and removes self-referential entries. Logs: `.ai/logs/queue-sanitizer.log`.
- All implementer loops (`auto-backend.sh`, `auto-supporting.sh`, `auto-ui.sh`) self-kickstart after a successful task run, so the next eligible task is claimed immediately without waiting for the next scheduled interval.
- `com.<project>.post-reset-nudge` can fire daily (for example 05:02 local time) to kickstart validator, technical-writer, and supporting services after overnight usage resets (`scripts/auto-post-reset.sh`).

Operational implication:
- If a task is blocked due to missing files in an old worktree, requeue to `todo` and let automation reclaim it; worktree recreation is now automatic.
- If logs show queue parse errors, treat them as automation defects and patch scripts, not task logic.
- Blocker fix-task loops are guarded: blocked fix tasks are requeued/reused, and existing active fix tasks are reused (no more "fix of fix of fix" chains).
- Docker container name conflicts can fail migration validation even when migration SQL is correct. Check `docker ps` before attributing failures to migration logic. **Systemic fix (task-126, April 4 2026):** when only the database is needed for migrations, start only the named service: `docker compose --profile test up postgres_test -d`. This avoids binding redis-test ports entirely and prevents cross-worktree port collisions.
- iOS xcodebuild validation commands must use `cd ios &&` prefix and `generic/platform=iOS Simulator` destination string. Both the queue entry and the `.ai/tasks/` file must contain the exact string.

### Additional reliability hardening (April 3, 2026, later)

- `create-worktree.sh` now also symlinks `.ai/tasks`, `.env`, `.env.example`, `docker-compose.yml`, and `backend/migrations` into each worktree. This prevents stale-branch snapshots from missing newly generated tasks or migration SQL.
- Compose ports are now env-driven (`POSTGRES_PORT`, `POSTGRES_TEST_PORT`, `REDIS_PORT`) and loop runners compute per-task high ports. This avoids collisions with host services and parallel worktrees.
- Loop runners now export a consistent `DB_URL` using `127.0.0.1` + the selected task port, reducing localhost/port ambiguity during migration validation.
- Implementer loops now have runner fallback behavior: try Codex first, then Claude if Codex hits quota, with a hard timeout on Claude subprocess execution.
- `sanitize-queue-self-containment.sh` now normalizes migrate validation commands to use retry wrappers, which mitigates transient Postgres startup races that were causing repeated false failures.
- Manual validator fallback was used to transition blocked lane tasks (`task-119`, `task-116`, `task-003`) when both CLI runners were quota-limited; this kept the queue moving without waiting for quota reset.
- Quota-interrupted implementer runs now checkpoint into `.ai/state/progress/<task-id>.json`, append a partial `quota_checkpoint` to the implementation handoff, and requeue with `resume_from: quota_interrupted` plus `retry_after` so resume starts from last known step instead of restarting from scratch.

---

## Generic architectural patterns for production deployments

The following patterns have been validated in production and are reusable across projects:

### Pattern 1: Four-Stage Orchestration Conductor

For complex workflows, a centralized orchestration script (e.g., `scripts/orchestration-conductor.sh`) runs periodically (every 2-5 minutes) and executes four stages in order:

1. **Dependency Cycle Repair** — Scan queue for circular `depends_on` edges and remove them (prevents deadlock).
2. **Unblocker** — For each `blocked` task, auto-create a fix task with dependency rewiring.
3. **Critical Lane** — Priority reordering, stale-task watchdogs, quota exhaustion detection, health checks.
4. **Final Repair** — Run dependency-cycle repair again to catch edges created by unblocker.

**Benefit:** Prevents manual intervention for most classes of blockers (circular deps, stale tasks, quota exhaustion).

**Implementation notes:**
- Guard the conductor with a single file-system lock (mkdir for atomic creation). Set a TTL on the lock (e.g., 3600s / 60 min) so long-running stages don't block the next cycle.
- Use temp file + `os.replace()` for atomic queue writes during each stage.
- Log each stage start/end + key actions to `.ai/logs/orchestration-conductor.log`.

### Pattern 2: Escalation & Automatic Investigation Tasks

When a task stays in `in_progress` beyond a threshold (e.g., 30 minutes without progress), auto-create an investigation task:

1. Detect stalled tasks: `status == "in_progress" AND (now - started_at) > threshold AND owner in [implementer-core, implementer-edge]`.
2. Check deduplication: Verify no active investigation task already exists for this task.
3. Check throttle: Verify no completed investigation for this task was done within the last 1 hour.
4. Create investigation task: Title `"Investigate stuck <task-id> for SSE review"`, type `supporting`, priority `999`.
5. Kick the review agent/validator immediately.

**Benefit:** Surfaces stuck work without manual polling. Prevents escalation spam with deduplication + throttle.

**Implementation notes:**
- Store last successful investigation timestamp in the task's `last_updated` field.
- Investigation task should capture the checkpoint file ref (`.ai/state/progress/<task-id>.json`) so the reviewer has context.
- Investigation handoff must document root cause + recommended fix or resume approach.

### Pattern 3: Three-Layer Quota Defense

When API limits are approached, implement three defensive layers:

**Layer 1 — Quota Exhaustion Detection:**
- Central script (e.g., `scripts/check-quota.sh`) runs periodically (every 2 min) with a 5-min cache TTL.
- On 429 / rate-limit: Create flag file `.ai/state/.quota-exhausted`.
- On success: Remove flag file.
- All implementer loops read this flag before claiming new tasks; if present, skip claiming.

**Layer 2 — Model Hints (Cost Optimization):**
- Add optional `model_hint: "haiku"` field to queue tasks (for work suitable for cheaper/faster models).
- Implementer scripts check hint and route accordingly:
  ```bash
  if [ "$model_hint" = "haiku" ]; then
    # Use cheaper model
  else
    # Use default (faster/more capable) model
  fi
  ```
- Suitable work: config/env setup, documentation audits, simple refactoring, test setup.

**Layer 3 — Progress Checkpoints & Graceful Release:**
- Before quota exhaustion: Agents checkpoint work to `.ai/state/progress/<task-id>.json` (store stage, timestamp, modified files).
- On quota exhaustion: Implementer script auto-calls quota handler:
  - Write `.ai/handoffs/<task-id>-quota-interrupted.md` (partial work log).
  - Update queue: `status: "todo"`, `resume_from: "quota_interrupted"`, `resume_context_ref: ".ai/state/progress/<task-id>.json"`, `retry_after: <future timestamp>`.
  - Task enters resumable state instead of stuck in `in_progress`.
- On resume: Next agent loads checkpoint and continues from last milestone (no restart).

**Benefit:** Zero tasks stuck due to quota exhaustion; graceful backpressure instead of wasted runs.

### Pattern 4: Lock TTL Architecture (Multi-Level)

Implement three-level TTL strategy for stale-lock recovery:

1. **Task-Level TTL** (longest): Max execution time per task, e.g., 90 minutes (5400s). Handled by `release-stale-locks.sh` in each implementer loop; runs before claiming.
2. **Early Cleanup** (aggressive): 30 minutes (1800s) — detected early in loop to free up a task stuck mid-stream without waiting the full 90m.
3. **Service-Level TTL** (shortest): Per-service limit, e.g., orchestration conductor at 3600s (60 min), validator at 25 min, implementers at 20 min.

Store all TTL values in a central config file (e.g., `scripts/lock-ttl-config.sh`); source it from all scripts for consistency.

**Benefit:** Prevents deadlock from hung processes; allows tuning without scatter across multiple scripts.

### Pattern 5: Lane Separation (Four Parallel Tracks)

Organize agents into four non-overlapping lanes to prevent duplicate work and enable hierarchical governance:

| Lane | Purpose | Agents | Sample Services |
|------|---------|--------|-----------------|
| **Implementation** | Write code/docs/tests | backend-engineer, fullstack-engineer, ui-ux-designer | `com.<project>.backend`, `com.<project>.supporting` |
| **Review** | Validate + architectural oversight | senior-software-engineer, software-architect | `com.<project>.reviewer`, `com.<project>.validator` |
| **Planning** | Prioritize + create tasks | product-owner, product-manager, chief-product-officer | `com.<project>.product-owner`, `com.<project>.planner` |
| **Orchestration** | Repair, escalate, manage queues | state-manager, unblocker, conductor | `com.<project>.orchestration-conductor`, `com.<project>.unblocker` |

No task is claimed by two lanes simultaneously. No agent in one lane creates/edits tasks in another lane without routing through a formal handoff (queue update + notification).

**Benefit:** Prevents conflicting edits to queue/tasks; makes service dependencies explicit and auditable.

### Pattern 6: Resume & Checkpoint Semantics

Extend the queue schema with resumable-work fields:

```json
{
  "id": "task-123",
  "status": "in_progress",
  "resume_from": "quota_interrupted",        // Why it's being resumed
  "resume_context_ref": ".ai/state/progress/task-123.json",  // Checkpoint path
  "retry_after": "2026-04-07T14:30:00Z",    // Earliest retry timestamp
  "started_at": "2026-04-07T13:00:00Z",
  ...
}
```

**Semantics:**
- `resume_from` values: `"quota_interrupted"`, `"stale_lock_released"`, `"escalation_resolved"`, `"blocked_dependency_resolved"`, `null` (fresh claim).
- `resume_context_ref` points to a JSON checkpoint file with: `{"stage": "validation", "files_modified": [...], "at": "2026-04-07T13:45:00Z"}`.
- `retry_after` prevents retry storms; implementer skips the task if `now < retry_after`.

**Benefit:** Resumable work is explicitly labeled; agents can load context and continue instead of restarting.

### Pattern 7: Live Dashboard for Queue Operations

Provide an HTTP API + browser dashboard for live queue inspection and manipulation:

**Endpoints:**
- `GET /api/health` — Service health check.
- `GET /api/board` — Return current queue state (read from `.ai/state/queue.json`) formatted for Kanban display (columns: Todo, Claimed, In Progress, Implemented, Validating, Done, Blocked).
- `POST /api/requeue?task_id=task-123` — Set task status back to `todo`, clear owner, publish to UI (useful for manual retry after fixes).
- `POST /api/create-fix-task?task_id=task-123` — Auto-create fix-task file + queue entry (useful when task is blocked).
- `POST /api/kickstart-agent?name=<service>` — Manually trigger a launchd service immediately (e.g., `name=backend` triggers `com.<project>.backend`). Validates agent name against allowlist and returns 400 `{"error":"unknown_agent"}` if unrecognized (useful for forced retry or urgent validation run).

**UI:**
- Kanban board with columns for each status.
- Cards show task ID, title, owner, priority, dependencies.
- Card enrichment from `.ai/tasks/*.md` (objective, acceptance) and `.ai/handoffs/*.md` (last action).
- Auto-refresh every 5 seconds.
- Action buttons: Requeue, Create Fix Task.

**Benefit:** Operators can spot blockers / stalled work without running commands; manual interventions are auditable (appear as queue edits).

### Pattern 8: Scheduled Automation Services

Use a system scheduler (cron, launchd, systemd timer) to run agent loops as daemons at fixed intervals:

```
com.<project>.backend         → run-backend-loop.sh          (every 20 min)
com.<project>.supporting      → run-supporting-loop.sh       (every 20 min)
com.<project>.ui              → run-ui-loop.sh               (every 20 min)
com.<project>.validator       → run-validator-loop.sh        (every 25 min)
com.<project>.orchestration-conductor → orchestration-conductor.sh (every 2 min)
com.<project>.unblocker       → auto-unblocker.sh            (every 10 min)
com.<project>.health-monitor  → health-check.sh              (every 5 min)
com.<project>.git-push        → auto-git-push.sh             (every 30 min)
com.<project>.memory-curator  → memory-curator.sh            (every 120 min)
com.<project>.technical-writer → update-docs.sh              (every 10 min)
```

**Benefits:**
- Work resumes automatically after quota resets (no manual intervention).
- Failed tasks are retried without human ping.
- Queue health is continuously monitored (cycles repair, escalations, TTLs).
- Docs/memory stay in sync with code (no stale handoffs).

**Implementation notes:**
- Each service should acquire a lock before running; respect the lock TTL.
- Each service should log to `.ai/logs/<service-name>.log`.
- Each service should be idempotent (safe to run multiple times without duplicate side effects).
- Use `launchctl kickstart -k <service>` for immediate trigger (testing / manual resume).

---

## Prerequisites

You need the following installed:

```bash
# Claude Code CLI
npm install -g @anthropic-ai/claude-code

# Codex CLI
npm install -g @openai/codex

# Python 3 (for queue management scripts)
python3 --version

# Git 2.5+ (for worktree support)
git --version

# jq (optional, for pretty-printing queue)
brew install jq
```

Verify both CLIs work:

```bash
claude --version
codex --version
```

---

## Part 1 — Repo structure

Create your project repo. The workflow infrastructure lives alongside your actual code.

```
my-project/
├── src/                    ← your actual codebase
├── .ai/
│   ├── state/
│   │   ├── queue.json      ← THE source of truth
│   │   ├── runs.json       ← run history
│   │   └── locks/          ← stale lock detection
│   ├── tasks/
│   │   ├── TEMPLATE.md
│   │   └── task-001.md     ← one file per task
│   ├── handoffs/
│   │   ├── TEMPLATE-impl.md
│   │   └── task-001-impl.md
│   ├── context/
│   │   ├── product.md      ← what you're building
│   │   ├── architecture.md ← tech stack decisions
│   │   └── test-strategy.md
│   ├── prompts/            ← reusable prompt snippets
│   └── logs/               ← agent run logs
├── scripts/
│   ├── claim-task.sh
│   ├── complete-task.sh
│   ├── release-stale-locks.sh
│   ├── create-worktree.sh
│   ├── run-backend-loop.sh
│   ├── run-ui-loop.sh
│   ├── run-supporting-loop.sh
│   ├── run-validator-loop.sh
│   ├── run-all-loops.sh
│   └── show-queue.sh
├── worktrees/              ← git worktrees (gitignored)
├── AGENTS.md               ← read by both Claude and Codex
├── CLAUDE.md               ← read by Claude Code
└── .gitignore
```

Initialize it:

```bash
mkdir my-project && cd my-project
git init && git checkout -b main
mkdir -p .ai/{state/locks,tasks,handoffs,context,prompts,logs}
mkdir -p scripts worktrees
```

---

## Part 2 — The instruction files

These two files are how you program agent behavior. Write them once. Agents re-read them at the start of every session.

### CLAUDE.md

Claude Code reads this automatically from the repo root. Tell it:
- what the repo is for
- the rule that all state lives in files, not chat
- the agent roles
- the tech stack

```markdown
# CLAUDE.md

## purpose
This repository uses persistent workflow state for agent execution.

## rules
- do not rely on chat history for task progress
- use .ai/state/queue.json as the source of truth
- use .ai/tasks/ for scoped task definitions
- use .ai/handoffs/ for implementation and validation handoffs
- do not implement more than one task per run unless explicitly instructed

## agent operating model
- product-owner creates tasks and acceptance criteria
- backend-engineer handles backend and core logic
- fullstack-engineer handles tests, config, docs, integration glue
- ui-ux-designer handles UI task types
- validator validates only against task criteria
- state-manager updates queue and recovery state

## tech stack
- Backend: Go (Echo), PostgreSQL, Redis
- iOS: Swift 6, SwiftUI, SwiftData
- Infra: Docker Compose
```

### AGENTS.md

Codex reads `AGENTS.md` natively — this is its equivalent of `CLAUDE.md`. Write it so both tools can follow it.

```markdown
# AGENTS.md

## operating rules
- never start work without reading .ai/state/queue.json
- never work on a task claimed by another agent
- always write a handoff file after implementation or validation
- always update queue.json before exiting
- do not touch unrelated files
- do not invent acceptance criteria

## task routing
- backend    → backend-engineer   (API, DB, business logic)
- ui         → ui-ux-designer     (screens, components)
- supporting → fullstack-engineer (tests, config, Docker, CI)

## workflow
1. read .ai/state/queue.json
2. select highest-priority available task with all dependencies done
3. use the assigned worktree or create one
4. read the task file
5. read the latest handoff if it exists (to resume)
6. implement only the assigned task
7. run required validation commands
8. write handoff to .ai/handoffs/
9. update queue.json

## done rules
A task is NOT done until:
- code is implemented and compiles
- required checks pass
- validation handoff exists
- queue.json status is "done"

## output contract
Every handoff must include:
- summary, files_changed, commands_run, results, blockers, next_step
```

---

## Part 3 — The context files

These live in `.ai/context/` and give every agent enough grounding to make good decisions without you explaining things each time.

### product.md

Describe what you're building in plain language. Include the user, the modules, the release plan, and the key constraints.

```markdown
# product.md

## What it is
MyApp is a [one-line description].

## Primary user
[Who uses this and why.]

## Modules
1. Auth — sign up, sign in, sessions
2. Dashboard — daily summary view
3. ...

## Release plan
- v1.0: Core modules (sprints 1–5)
- v1.1: Power features (sprints 6–8)

## Key constraints
- Must work offline (local-first sync)
- iOS 17+ only
- GDPR compliant
```

### architecture.md

Document every tech decision that agents need to follow. Include the stack, key data models, API conventions, and anything sprint-1-specific.

```markdown
# architecture.md

## Stack
- iOS: Swift 6, SwiftUI, SwiftData
- Backend: Go 1.22+, Echo v4, pgx/v5
- DB: PostgreSQL 16, Redis 7
- Auth: JWT RS256

## API conventions
- Base: https://api.example.com/v1
- Envelope: { data, error, meta }
- Auth: Authorization: Bearer <jwt>
- Errors: snake_case codes

## Key models
[List your core DB tables and their important fields]

## Sprint 1 — what must exist first
1. Docker Compose up: postgres + redis
2. Go module init, Echo skeleton, health check
3. DB migration 001: users table
4. Auth endpoints
5. iOS networking layer
```

### test-strategy.md

Define what passing looks like for each task type, so the validator knows what to check.

```markdown
# test-strategy.md

## Backend tasks
- go build ./...
- go test ./...
- go vet ./...

## iOS tasks
- xcodebuild build -scheme MyApp -destination 'platform=iOS Simulator,name=iPhone 16'

## Supporting tasks (Docker, migrations)
- docker compose up -d
- docker compose exec backend go build ./...

## Coverage targets
- Backend unit: ≥ 70% per package
- Integration: all happy paths + all documented error codes

## Error handling contract
All errors: { "error": { "code": "snake_case", "message": "...", "field": "..." } }
```

---

## Part 4 — Task files

Each task is a markdown file in `.ai/tasks/`. One file = one agent session of work.

### The template

```markdown
# task-001

## title
Go module init and Echo server skeleton

## task_type
supporting

## sprint
1

## objective
Initialise the Go module, set up Echo v4 with middleware,
and add a GET /health endpoint that returns 200 OK.

## likely_files
- backend/main.go
- backend/go.mod
- backend/go.sum

## constraints
- do not add any auth middleware yet (that is task-004)
- use Echo v4, not v3

## acceptance_criteria
- go build ./... succeeds with no errors
- GET /health returns { "status": "ok" }
- echo.Logger middleware is wired

## validation_commands
- go build ./...
- go vet ./...
- curl http://localhost:8080/health

## non_goals
- database connection (that is task-002)
- auth (that is task-004)

## dependencies
- (none — this is the first task)
```

### What makes a good task

| Good | Bad |
|------|-----|
| One clear implementation goal | "Implement the entire auth system" |
| Completable in one agent session | Touches 20+ files |
| Has specific acceptance criteria | "It should work" |
| Has runnable validation commands | No commands listed |
| Lists dependencies accurately | Missing dependency causes broken build |

### Task types

| Type | What it covers | Routed to |
|------|---------------|-----------|
| `backend` | API handlers, DB queries, business logic | backend-engineer |
| `ui` | SwiftUI/React screens, components, design | ui-ux-designer |
| `supporting` | Migrations, Docker, tests, config, CI | fullstack-engineer |

---

## Part 5 — The queue

`.ai/state/queue.json` is a flat JSON array. Every task has one entry.

```json
[
  {
    "id": "task-001",
    "title": "Go module init and Echo skeleton",
    "task_type": "supporting",
    "sprint": 1,
    "status": "todo",
    "owner": null,
    "owner_history": [],
    "priority": 1,
    "depends_on": [],
    "task_file": ".ai/tasks/task-001.md",
    "acceptance": [
      "go build ./... succeeds",
      "GET /health returns 200"
    ],
    "validation_commands": [
      "go build ./...",
      "go vet ./..."
    ],
    "last_updated": null,
    "resume_from": null,
    "resume_context_ref": null,
    "model_hint": null
  },
  {
    "id": "task-004",
    "title": "Auth API: register, login, SIWA",
    "task_type": "backend",
    "sprint": 1,
    "status": "todo",
    "owner": null,
    "priority": 4,
    "depends_on": ["task-001", "task-002", "task-003"],
    "task_file": ".ai/tasks/task-004.md",
    "acceptance": [
      "POST /v1/auth/register returns 201 with JWT",
      "POST /v1/auth/login returns 200 with JWT",
      "Invalid credentials return 401 with error code invalid_credentials"
    ],
    "validation_commands": [
      "go build ./...",
      "go test ./backend/auth/..."
    ],
    "last_updated": null,
    "resume_from": null,
    "resume_context_ref": null,
    "model_hint": null
  }
]
```

### Owner tracking

- `owner` = current assignee (who is working on it now)
- `owner_history` = append-only event history (`claimed`, `released`, `requeued`, status transitions) with timestamps
- Use `owner_history` to answer “who worked on this ticket before”

### Status lifecycle

```
todo
  ↓  (claim-task.sh runs)
claimed
  ↓  (agent starts work)
in_progress
  ↓  (agent finishes)
implemented
  ↓  (validator runs)
validating
  ↓  (all criteria pass)       ↓  (a criterion fails)
done                      failed_validation
                               ↓  (fix task created automatically by validator)
                              todo  (new fix task, original task re-queued with dep)
```

Special statuses:
- `blocked` — agent hit a blocker it cannot resolve; wrote the reason to the handoff; fix-task.sh resolves it (see Part 10)
- `failed_validation` — validator ran, a criterion failed; a fix task is created automatically and the original task re-queued with the fix task as a dependency

### Queue fields for resumable work & cost optimization

**Resume fields** (used when quota exhaustion or other interruption occurs):
- `resume_from` — Reason task is being resumed; value: `"quota_interrupted"` (Anthropic API rate limit hit) | `null` (new task)
- `resume_context_ref` — Path to checkpoint state (`.ai/state/progress/<task-id>.json`); agent loads and continues from last recorded milestone
- `retry_after` — Earliest retry timestamp (ISO 8601) after quota recovery or backoff

**Model routing** (for cost optimization during quota constraints):
- `model_hint` — Optional hint for model selection; values: `"haiku"` (simple config/docs/cleanup tasks suitable for 3x cheaper Haiku model) | `null` (default: Opus/Sonnet)

**Example task with quota recovery**:
```json
{
  "id": "task-053",
  "title": "Implement audit logging",
  "status": "todo",
  "resume_from": "quota_interrupted",
  "resume_context_ref": ".ai/state/progress/task-053.json",
  "retry_after": "2026-04-06T11:30:00Z",
  "model_hint": null
}
```

When `resume_from: "quota_interrupted"` is set:
1. Agent checks if checkpoint file exists at `resume_context_ref` path
2. Reads checkpoint JSON to determine last completed stage
3. Continues from that stage (not from beginning)
4. Clears `resume_from` and `resume_context_ref` once task completes

---

## Part 6 — The scripts

### claim-task.sh

Atomically claims the next eligible task for a given agent and task type. Writes `claimed` + owner to queue.json. Returns the task ID on stdout.

```bash
# Usage
./scripts/claim-task.sh <agent-name> <task-type>

# Example
./scripts/claim-task.sh backend-engineer backend
# → prints: task-004
```

Eligibility rules:
- status is `todo` or `failed_validation`
- no current owner
- all dependencies have status `done`
- task_type matches

```bash
#!/usr/bin/env bash
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
        print(task["id"])
        with open("${QUEUE}", "w") as f:
            json.dump(tasks, f, indent=2)
        raise SystemExit(0)

raise SystemExit(1)
PY
```

### release-stale-locks.sh

Releases tasks that have been `claimed` or `in_progress` for more than 4 hours (usage limit hit, crash, etc.) and resets them to `todo` so they can be reclaimed.

```bash
#!/usr/bin/env bash
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

with open("${QUEUE}", "w") as f:
    json.dump(tasks, f, indent=2)
PY
```

### create-worktree.sh

Creates an isolated git worktree for a task branch. Each task gets its own directory under `worktrees/`. The agent works there without touching `main`.

```bash
#!/usr/bin/env bash
set -euo pipefail

TASK_ID="$1"
BRANCH="agent/${TASK_ID}"
DIR="worktrees/${TASK_ID}"

if [ ! -d "$DIR" ]; then
  git worktree add -b "$BRANCH" "$DIR"
fi

echo "$DIR"
```

### fix-task.sh

Resolves a blocked task in one command. Reads the blocker text from the implementation handoff, creates a typed fix task pre-filled with that context, wires the dependency, and resets the blocked task to `todo`.

```bash
# Usage
./scripts/fix-task.sh <blocked-task-id>

# Example
./scripts/fix-task.sh task-014
# → creates task-101.md (fix task, pre-filled from handoff blockers section)
# → task-101 added to queue.json as todo
# → task-014 reset to todo, depends_on now includes task-101
# → next loop run claims task-101 and fixes the blocker
# → after task-101 is done, task-014 becomes eligible again
```

The script does **not** require you to write anything. It reads the handoff's `## blockers` section directly. If the blocker description in the handoff is clear, the fix task requires no editing. If the fix requires a judgment call (e.g. which API to swap to), open the generated fix task file and add a constraint before the next loop run.

```bash
#!/usr/bin/env bash
# Usage: ./scripts/fix-task.sh <blocked-task-id>
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
```

### run-backend-loop.sh

The main entry point for backend work. Releases stale locks, claims the next backend task, creates the worktree, and prints the exact prompt to paste into Codex.

```bash
#!/usr/bin/env bash
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
5. .ai/state/queue.json — find task ${TASK_ID}
6. .ai/tasks/${TASK_ID}.md
7. .ai/handoffs/${TASK_ID}-impl.md — if it exists, resume from it

This is a backend task assigned to backend-engineer.
Implement only task ${TASK_ID}.
Run all validation_commands from the task file.
Write a handoff to .ai/handoffs/${TASK_ID}-impl.md.
Update queue.json status to implemented (or blocked with reason).
PROMPT
```

The UI and supporting loops are identical in structure — only the agent name, task type, and stack instructions differ.

---

## Part 7 — Handoff files

Every agent session ends by writing a handoff. This is how work is resumed after a limit or crash without re-explaining anything.

### Implementation handoff (written by implementer)

```markdown
# task-004 implementation handoff

## summary
Implemented POST /v1/auth/register and POST /v1/auth/login. Both return
a signed JWT (RS256, 24h expiry). Sign in with Apple validates the identity
token against Apple's public JWK endpoint and creates/returns a user.

## files_changed
- backend/auth/handler.go (created)
- backend/auth/service.go (created)
- backend/auth/jwt.go (created)
- backend/main.go (registered auth routes)

## commands_run
- go build ./...       → OK
- go test ./backend/auth/... → 4 passed
- go vet ./...         → OK

## results
All 3 endpoints return correct responses.
JWT contains sub (user_id), hid (household_id), role, exp fields.

## blockers
None.

## next_step
task-005 (JWT middleware) depends on this. Can be started.
```

### Validation handoff (written by validator)

```markdown
# task-004 validation handoff

## task_status
done

## acceptance_review
- POST /v1/auth/register returns 201 with JWT: pass
- POST /v1/auth/login returns 200 with JWT: pass
- Invalid credentials return 401 with error code invalid_credentials: pass
- go test ./backend/auth/... all pass: pass

## commands_run
- go build ./...
- go test ./backend/auth/...
- curl -X POST http://localhost:8080/v1/auth/login -d '{"email":"x","password":"wrong"}'

## results
All 4 acceptance criteria pass. 4 tests, 0 failures.

## follow_up
None.
```

---

## Part 8 — Git worktrees

Each task gets its own branch and directory. This lets multiple tasks be implemented in parallel without conflicts.

```
my-project/
├── main branch           ← stable, merged code
├── worktrees/
│   ├── task-004/         ← agent/task-004 branch
│   ├── task-009/         ← agent/task-009 branch
│   └── task-011/         ← agent/task-011 branch
```

The agents work inside `worktrees/task-xxx/`. When a task is validated as `done`, you merge that branch back to `main`:

```bash
git checkout main
git merge --no-ff agent/task-004 -m "feat: auth API (task-004)"
git worktree remove worktrees/task-004
git branch -d agent/task-004
```

You can run multiple parallel worktrees simultaneously:

```bash
# Terminal 1 — backend task running in Codex
cd ~/my-project/worktrees/task-004 && codex

# Terminal 2 — UI task running in Claude Code
cd ~/my-project/worktrees/task-009 && claude

# Terminal 3 — supporting task running in Codex
cd ~/my-project/worktrees/task-011 && codex
```

They share `.ai/state/queue.json` (each claimed a different task, so no collision) and the `.ai/context/` files, but each has its own working tree for code changes.

---

## Part 9 — The product-owner

The product-owner is a Claude subagent that reads your context files and PRD, then generates all task files and populates queue.json. You run it once before starting Sprint 1, and again before each new sprint or major feature.

Run it from Claude Code with:

```
Use the product-owner agent. Read .ai/context/product.md, architecture.md, and test-strategy.md.
Break Sprint 1 into implementation tasks. Create task files in .ai/tasks/ and update queue.json.
Follow the task format in .ai/tasks/TEMPLATE.md. Each task must have:
- one clear objective
- specific acceptance_criteria
- runnable validation_commands
- correct task_type (backend, ui, or supporting)
- correct depends_on references
```

After the product-owner runs, review queue.json before starting execution:

```bash
# Pretty-print the queue
jq '.' .ai/state/queue.json

# Check task types are correct
jq -r '.[] | [.id, .task_type, .sprint, .title] | @tsv' .ai/state/queue.json

# Check for missing dependencies (any depends_on referencing non-existent IDs)
python3 -c "
import json
with open('.ai/state/queue.json') as f:
    tasks = json.load(f)
ids = {t['id'] for t in tasks}
for t in tasks:
    for dep in t.get('depends_on', []):
        if dep not in ids:
            print(f'{t[\"id\"]} has missing dep: {dep}')
"
```

---

## Part 10 — Day-to-day operation

### Automated mode (default)

Once launchd services are loaded (see Part 11), there is nothing to do to start a sprint. The services fire on schedule, claim tasks, run agents, and update the queue automatically.

Your only job is to watch the dashboard and handle blocked tasks:

```
http://127.0.0.1:8788
```

**To start execution immediately** (don't wait for the next 20-minute interval):

```bash
launchctl kickstart -k gui/$(id -u)/com.myproject.backend
launchctl kickstart -k gui/$(id -u)/com.myproject.supporting
launchctl kickstart -k gui/$(id -u)/com.myproject.ui
```

**After limits reset**, the next scheduled service invocation picks up automatically. No action needed.

---

### Manual mode (fallback)

Use manual mode when launchd is not available, when you want to force a specific task, or when debugging.

```bash
cd ~/my-project

# 1. Review what's queued
./scripts/show-queue.sh

# 2. Run the backend loop — prints a Codex prompt
./scripts/run-backend-loop.sh
# → cd into the printed worktree, then: codex (paste the prompt)

# 3. Run the UI loop simultaneously in a second terminal
./scripts/run-ui-loop.sh
# → cd into that worktree, then: codex (paste the prompt)

# 4. Run the supporting loop in a third terminal
./scripts/run-supporting-loop.sh
# → cd into that worktree, then: codex (paste the prompt)

# 5. When tasks reach "implemented", run the validator
./scripts/run-validator-loop.sh
# → paste that prompt into a Claude Code session
```

After limits reset in manual mode — just rerun the relevant loop script. Stale locks are released automatically, the next eligible task is claimed, and the agent reads the handoff to resume exactly where the last session stopped.

---

### Checking status

```bash
# Terminal dashboard (queue summary)
./scripts/show-queue.sh

# Browser dashboard (kanban, always-on)
open http://127.0.0.1:8788

# Only unfinished tasks
jq '[.[] | select(.status != "done")]' .ai/state/queue.json

# Only blocked
jq '[.[] | select(.status == "blocked")]' .ai/state/queue.json

# Failed validation
jq '[.[] | select(.status == "failed_validation")]' .ai/state/queue.json

# By sprint
jq '[.[] | select(.sprint == 1)]' .ai/state/queue.json

# Summary table
jq -r '.[] | [.id, .task_type, .status, (.owner // "-"), .title] | @tsv' .ai/state/queue.json
```

### When a task is blocked

The agent writes `blocked` to queue.json and describes the exact blocker in the handoff file under `## blockers`. The workflow then stalls on that task until you intervene — but the intervention is a single command.

**Run `fix-task.sh`:**

```bash
./scripts/fix-task.sh task-xxx
```

What it does automatically:

1. Reads `.ai/handoffs/task-xxx-impl.md` and extracts the blocker text
2. Creates a new fix task file (`.ai/tasks/task-NNN.md`) pre-filled with the blocker as the objective
3. Adds the fix task to `queue.json` as `todo`
4. Wires the dependency: blocked task's `depends_on` now includes the fix task ID
5. Resets the blocked task from `blocked` → `todo` (it won't be claimable until the fix task reaches `done`)

The full lifecycle looks like this:

```
agent hits blocker
      ↓
writes .ai/handoffs/task-xxx-impl.md  (blockers section filled)
queue.json → status: "blocked"
      ↓
you run:  ./scripts/fix-task.sh task-xxx
      ↓
fix task task-NNN created (todo, no dependencies)
task-xxx reset to todo, depends_on: [..., "task-NNN"]
      ↓
next loop run claims task-NNN (the fix)
agent resolves it, marks done
      ↓
task-xxx is now eligible again (dependency satisfied)
next loop run re-claims and re-implements task-xxx
reads the original handoff to know where it left off
```

The fix task file is pre-filled with the blocker text from the handoff, so the fixing agent has full context. You do not need to write anything manually beyond running the one command. If the fix requires judgment (e.g. a third-party API is down and you need to pick an alternative), open the generated fix task file and add guidance before the next loop run claims it.

**Do you need to do anything before the fix runs?**

In most cases: no. Run `fix-task.sh`, let the loop claim and execute the fix task, then the original task re-queues automatically.

The one case where you should review first: if the blocker is ambiguous and the fixing agent might make a wrong architectural decision (e.g. "cannot find the Calendarific API key" — is it missing from config, or should the service be swapped?). In that case:

```bash
./scripts/fix-task.sh task-xxx         # creates the fix task
# then open the fix task file and add a constraint or direction before the loop runs
nano .ai/tasks/task-NNN.md             # edit the constraints or acceptance_criteria
./scripts/run-backend-loop.sh          # now run the loop
```

### When validation fails

The validator creates a fix task automatically in the same pattern. It appears in `queue.json` as a new `todo` task with the failed task in its `depends_on`. The failed task's status is set to `failed_validation`. The fix task gets picked up on the next loop run.

You do not need to run `fix-task.sh` for validation failures — the validator handles this itself as part of its output contract.

---

## Part 11 — Automated execution with launchd

This is the recommended production mode. Agents run on a schedule without manual intervention. Work continues automatically after usage limits reset. You watch a dashboard instead of managing terminals.

The manual 3-terminal model from Part 10 is a fallback for environments where a scheduler is not available, or when you need to force a specific task immediately.

---

### The two execution modes

| Mode | How it works | When to use |
|------|-------------|-------------|
| **Automated** (recommended) | launchd runs `auto-*.sh` scripts on a timer; agents execute non-interactively | Day-to-day development; fully hands-off after setup |
| **Manual / fallback** | You run `run-*.sh` scripts, copy the printed prompt, paste into Codex | CI environments without launchd; debugging a specific task; forcing immediate execution |

---

### How automated mode works

The loop scripts (`run-backend-loop.sh` etc.) print prompts for human pasting. Automated mode replaces that final step with a set of **auto wrapper scripts** that run the agent non-interactively:

```
scripts/
├── run-backend-loop.sh       ← prints prompt (manual mode)
├── auto-backend.sh           ← claims + runs codex non-interactively (automated mode)
├── run-supporting-loop.sh
├── auto-supporting.sh
├── run-ui-loop.sh
├── auto-ui.sh
├── run-validator-loop.sh
└── auto-validator.sh
```

Each `auto-*.sh` script does the following:

1. Acquires a per-loop lock in `.ai/state/locks/` to prevent overlapping runs
2. Runs stale-lock recovery (`release-stale-locks.sh`)
3. Claims the next eligible task for its type
4. Creates or reuses the task worktree
5. Runs the agent non-interactively:
   - implementers use `codex exec --dangerously-bypass-approvals-and-sandbox`
   - validator attempts `claude --print --dangerously-skip-permissions`, then falls back to `codex exec` when Claude is unavailable/quota-limited
6. Writes all output to `.ai/logs/`

If no eligible task exists, the script exits cleanly and logs a skip line. If a lock is already held, the next scheduled invocation skips without error.

---

### Setting up launchd (macOS)

Create one plist per agent type. The label, script path, and log paths are the only things that differ between them.

#### Implementer — backend (`com.myproject.backend.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.myproject.backend</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/yourname/my-project/scripts/auto-backend.sh</string>
  </array>
  <key>StartInterval</key>
  <integer>1200</integer>
  <key>StandardOutPath</key>
  <string>/Users/yourname/my-project/.ai/logs/launchd-backend.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/yourname/my-project/.ai/logs/launchd-backend.err.log</string>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

Repeat with the same structure for:
- `com.myproject.supporting` → `auto-supporting.sh`, interval `1200`
- `com.myproject.ui` → `auto-ui.sh`, interval `1200`
- `com.myproject.validator` → `auto-validator.sh`, interval `1500` (25 min — runs after implementers)

Save all four plists to `~/Library/LaunchAgents/`. Load them:

```bash
for plist in ~/Library/LaunchAgents/com.myproject.*.plist; do
  launchctl load "$plist"
done
```

#### Recommended intervals

| Service | Interval | Reason |
|---------|----------|--------|
| backend | 1200s (20 min) | One task per run; 20 min is enough per task |
| supporting | 1200s (20 min) | Same cadence as backend |
| ui | 1200s (20 min) | Same cadence |
| validator | 1500s (25 min) | Slightly offset so implementers finish first |

---

### The live Kanban dashboard

A persistent browser dashboard gives real-time visibility without running commands.

```
http://127.0.0.1:8788
```

Set it up as an always-on launchd service:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.myproject.dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/Users/yourname/my-project/scripts/dashboard_server.py</string>
  </array>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/yourname/my-project/.ai/logs/dashboard-server.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/yourname/my-project/.ai/logs/dashboard-server.err.log</string>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

Dashboard features:
- Reads `queue.json` and enriches each card from `.ai/tasks/*.md` and `.ai/handoffs/*`
- Auto-refreshes every 5 seconds
- Kanban columns: **Queued → In Progress → Implemented → Needs Attention → Done**
- Card actions: `Assign`, `Requeue`, `Create Fix Task`
- Shows current owner and full `owner_history` (every agent that has touched the task)

Dashboard API (local only):
- `GET /api/board` — full board state as JSON
- `POST /api/assign` `{ "task_id": "task-xxx", "owner": "fullstack-engineer" }` — set owner; moves `todo`/`failed_validation` to `claimed`
- `POST /api/requeue` `{ "task_id": "task-xxx" }` — reset to todo
- `POST /api/create-fix-task` `{ "task_id": "task-xxx", "reason": "..." }` — equivalent to `fix-task.sh`

---

### Controlling services day-to-day

```bash
# Force immediate execution (don't wait for the next interval)
launchctl kickstart -k gui/$(id -u)/com.myproject.backend
launchctl kickstart -k gui/$(id -u)/com.myproject.supporting
launchctl kickstart -k gui/$(id -u)/com.myproject.ui
launchctl kickstart -k gui/$(id -u)/com.myproject.validator

# Check if a service is running
launchctl list | grep com.myproject

# Stop a service temporarily
launchctl stop com.myproject.backend

# Unload a service permanently (survives reboot)
launchctl unload ~/Library/LaunchAgents/com.myproject.backend.plist

# Reload after editing a plist
launchctl unload ~/Library/LaunchAgents/com.myproject.backend.plist
launchctl load   ~/Library/LaunchAgents/com.myproject.backend.plist
```

---

### Watching logs

```bash
# Live tail — what's happening right now
tail -f .ai/logs/backend-scheduler.log
tail -f .ai/logs/supporting-scheduler.log
tail -f .ai/logs/validator-scheduler.log

# Agent output for a specific run
tail -f .ai/logs/backend-agent.log

# launchd stdout / stderr
tail -f .ai/logs/launchd-backend.out.log
tail -f .ai/logs/launchd-backend.err.log
```

A typical skip line (no eligible tasks) looks like:
```
[2026-04-02T14:20:01Z] No eligible backend tasks. Exiting.
```

A typical claim line looks like:
```
[2026-04-02T14:20:03Z] Claimed task-004. Worktree: worktrees/task-004. Running codex...
```

---

### cron (Linux / CI alternative)

If launchd is not available (Linux servers, CI runners):

```bash
crontab -e
# Add one line per agent type:
*/20 * * * * cd /path/to/my-project && ./scripts/auto-backend.sh >> .ai/logs/backend-scheduler.log 2>&1
*/20 * * * * cd /path/to/my-project && ./scripts/auto-supporting.sh >> .ai/logs/supporting-scheduler.log 2>&1
*/20 * * * * cd /path/to/my-project && ./scripts/auto-ui.sh >> .ai/logs/ui-scheduler.log 2>&1
*/25 * * * * cd /path/to/my-project && ./scripts/auto-validator.sh >> .ai/logs/validator-scheduler.log 2>&1
```

---

### Writing auto-*.sh scripts

The auto scripts are thin wrappers around the loop scripts. The only difference is the final step: instead of printing a prompt, they pipe it into the CLI non-interactively.

```bash
#!/usr/bin/env bash
# auto-backend.sh
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
```

Repeat the same pattern for `auto-supporting.sh` and `auto-ui.sh`, adjusting the agent name, task type, and prompt.  
For `auto-validator.sh`, keep a primary-runner-first strategy with a secondary fallback (for example Claude-first with Codex fallback).

---

### Adding AGENTS.md automation awareness

Add an `## execution mode` section to `AGENTS.md` so agents know whether they are running in automated or manual mode and behave accordingly:

```markdown
## execution mode
- default mode is automated via launchd; do not assume manual loop terminals are required
- background implementer loops run every 20 minutes
- validator loop runs every 25 minutes
- dashboard is always-on at http://127.0.0.1:8788
- to force immediate execution: launchctl kickstart -k gui/$(id -u)/com.myproject.<service>
- do not claim tasks manually if automation is running unless explicitly requested
```

### Technical writer automation (new)

To prevent workflow drift, add a dedicated documentation sync agent:

- Agent: `~/.claude/agents/technical-writer.md`
- Skill: `~/.claude/skills/technical-writer/SKILL.md`
- Loop script: `scripts/run-technical-writer-loop.sh` (manual fallback)
- Auto script: `scripts/auto-technical-writer.sh`
- LaunchAgent: `~/Library/LaunchAgents/com.<project>.technical-writer.plist`
- Sync state: `.ai/state/doc-sync.json`

Recommended cadence: every 10 minutes.

The technical-writer should update only affected docs after workflow/automation changes:

- `AGENTS.md`
- `CLAUDE.md`
- `~/Desktop/<your-folder>/claude-codex-agent-workflow-guide.md` (or wherever you keep this guide)
- Any local exported copy you maintain (for example `~/Downloads/resumable_agent_workflow_guide.md`)

---

## Part 12 — What "done" actually means

A task is done when ALL of these are true:

- [ ] Code changes are implemented in the worktree
- [ ] All `validation_commands` from the task file ran and passed
- [ ] `.ai/handoffs/task-xxx-impl.md` exists with all required fields
- [ ] `.ai/handoffs/task-xxx-validate.md` exists with `task_status: done`
- [ ] `queue.json` status is `done`

A sprint is done when ALL of these are true:

- [ ] All sprint tasks are `done`
- [ ] No tasks are `blocked` or `failed_validation`
- [ ] All task branches have been merged to `main`
- [ ] A new TestFlight/staging build has been created from `main`

Only then do you move to the next sprint.

---

## Part 13 — Operational rules

These are the non-negotiables that keep the system reliable:

1. **The repo is the source of truth.** Not chat. Not memory. Not your head. The files.

2. **One task per agent run.** Agents that claim multiple tasks create partial work and unpredictable state.

3. **Every run writes a handoff.** An agent that implements without a handoff leaves no trail for the next session.

4. **queue.json is updated before the session ends.** Status must reflect reality at all times.

5. **No skipping validation.** A task in `implemented` is not `done`. The validator runs separately.

6. **Never ask an agent "where were you?"** Check `.ai/handoffs/` and `queue.json` instead.

7. **Stale locks recover automatically.** If a session was interrupted, the next loop run will release the lock and the task can be reclaimed.

---

## Quick reference

### Useful commands

```bash
# Start a backend work session
./scripts/run-backend-loop.sh

# Start a UI work session
./scripts/run-ui-loop.sh

# Start a supporting work session
./scripts/run-supporting-loop.sh

# Run validation on all implemented tasks
./scripts/run-validator-loop.sh

# Run everything in sequence
./scripts/run-all-loops.sh

# Dashboard
./scripts/show-queue.sh

# Release stale locks manually
./scripts/release-stale-locks.sh

# Mark a task done manually (for edge cases)
./scripts/complete-task.sh task-004 done

# Handle a blocked task — creates a fix task automatically
./scripts/fix-task.sh task-004

# See all worktrees
git worktree list

# Merge a completed task branch
git checkout main
git merge --no-ff agent/task-004
git worktree remove worktrees/task-004
```

### File locations cheat sheet

| What you want to know | Where to look |
|-----------------------|---------------|
| What is the next task? | `queue.json` — first `todo` with deps satisfied |
| What happened in a task? | `.ai/handoffs/task-xxx-impl.md` |
| Did it pass validation? | `.ai/handoffs/task-xxx-validate.md` |
| What should a task do? | `.ai/tasks/task-xxx.md` |
| Who owns a task right now? | `queue.json` → `owner` field |
| Who has worked on a task over time? | `queue.json` → `owner_history` field |
| Why is a task blocked? | `queue.json` → `resume_from` + `.ai/handoffs/task-xxx-impl.md` `## blockers` |
| How do blocked tasks get fixed? | Automatic via `com.<project>.unblocker` (runs `./scripts/fix-task.sh task-xxx`) |
| What is the overall status? | `./scripts/show-queue.sh` |
| Where are periodic updates? | `.ai/logs/status-summary.log` + `.ai/state/latest-summary.txt` |

---

## Automation addendum (reference implementation)

Two additional launchd services are part of the operational baseline:

1. `com.<project>.unblocker`
- Script: `scripts/auto-unblocker.sh`
- Every 10 minutes
- Finds `blocked` tasks and auto-creates fix tasks with `fix-task.sh`, then re-queues blocked tasks with dependency wiring.

2. `com.<project>.status-summary`
- Script: `scripts/auto-status-summary.sh`
- Every 20 minutes
- Writes queue snapshots to `.ai/logs/status-summary.log` and `.ai/state/latest-summary.txt`
- Emits a macOS notification with queue counts.

This removes the need for manual nudging to recover blocked tasks and provides scheduled queue summaries.

3. `com.<project>.dependency-repair`
- Script: `scripts/repair-dependency-cycles.sh`
- Every 5 minutes
- Detects and repairs circular `depends_on` chains that cause deadlocks (for example: failed task <-> fix task).

4. Assignment execution guarantee
- `scripts/claim-task.sh` now adopts agent-owned `claimed` tasks before claiming new ones.
- Result: dashboard assignment leads to actual execution rather than parked `claimed` tickets.

5. `com.<project>.reviewer`
- Script: `scripts/auto-reviewer.sh`
- Every 60 minutes
- Triggers only when ≥5 new `done` tasks have accumulated since the last review (configurable).
- Runs the `reviewer-architectural` agent type via `claude --print` to analyse the live codebase for architectural drift, design debt, and security issues.
- Writes a dated findings handoff to `.ai/handoffs/arch-review-<YYYYMMDDTHHMM>.md`.
- Does NOT modify `queue.json` or create tasks — findings are handed to the product-owner.
- Writes `.ai/state/review-actions-pending.json` and immediately kickstarts the product-owner.
- Tracks state in `.ai/state/arch-review-state.json` (`done_count_at_last_review`, `last_handoff`).
- Logs: `.ai/logs/reviewer-scheduler.log`, `.ai/logs/reviewer-agent.log`

6. `com.<project>.product-owner`
- Script: `scripts/auto-product-owner.sh`
- Every 30 minutes (also kicked immediately after each reviewer run)
- Reads `.ai/state/review-actions-pending.json` for unactioned reviewer handoffs.
- Converts Critical/High findings into `.ai/tasks/<id>.md` files and `queue.json` entries.
- Skips findings already covered by existing `todo`/`in_progress`/`done` tasks.
- Sets `actioned: true` in the pending-actions file when done; kickstarts all implementer loops.
- Logs: `.ai/logs/product-owner-scheduler.log`, `.ai/logs/product-owner-agent.log`

7. `com.<project>.memory-curator`
- Script: `scripts/auto-memory-curator.sh`
- Every 120 minutes
- Triggers when ≥10 new handoffs or ≥5 interesting task state changes since last run.
- **Dual role:**
  1. Session memory: writes/updates `~/.claude/projects/<project>/memory/` so future Claude Code sessions carry accurate project context without re-deriving from scratch.
  2. Project lessons: maintains `.ai/context/lessons-learned.md` — a living, imperative pitfall guide that agents read at task start (evidence-based, not prose).
- Does NOT modify `queue.json` or task files.
- Tracks state in `.ai/state/memory-curator-state.json`.
- Logs: `.ai/logs/memory-curator-scheduler.log`, `.ai/logs/memory-curator-agent.log`

**Together, services 5–7 close the feedback loop:** the reviewer surfaces drift, the product-owner converts findings into actionable tasks, and the memory-curator ensures lessons propagate to every future session without manual note-taking.

8. `com.<project>.git-push`
- Script: `scripts/auto-git-push.sh`
- Every 30 minutes
- Stages and commits workflow infrastructure changes on `main` (scripts/, AGENTS.md, CLAUDE.md, .ai/state/, .ai/handoffs/, .ai/tasks/, .ai/context/, dashboard/, and product directories).
- Pushes `main` to origin after each commit.
- Skips if nothing changed, if not on `main` branch, or if merge conflicts are present.
- Does NOT merge worktree task branches into main — that is a separate merge-pipeline task.
- Logs: `.ai/logs/git-push-scheduler.log`, `.ai/logs/launchd-git-push.out.log`

**Parallel implementer instances:** Once you have more than a handful of concurrent tasks, add a second instance of any implementer service (e.g., `com.<project>.backend-2`, `com.<project>.ui-2`) pointing at the same script. Each instance competes for the same task type in the queue; the first to acquire the lock wins. This doubles throughput for that lane without any script changes.

**lessons-learned.md at task start:** Add step 5 to every agent's workflow: read `.ai/context/lessons-learned.md` (if it exists) before starting implementation. The memory-curator maintains this file. It contains imperative, evidence-based bullets agents can use to avoid repeating known failure patterns.

---

## Self-learning

This workflow can “self-learn” without relying on chat memory or hidden model state. The learning loop is file-based and auditable:

1. **Discover** — A reviewer agent periodically inspects the live repo and writes findings to a handoff (`.ai/handoffs/…`).
2. **Convert** — A product-owner agent turns high-signal findings into explicit tasks (`.ai/tasks/*.md` + `queue.json`).
3. **Execute** — Implementer/validator agents complete tasks in isolated worktrees and write structured handoffs.
4. **Persist** — A memory-curator agent writes durable guidance to:
   - `.ai/context/lessons-learned.md` (project lessons agents should read at task start)
   - `~/.claude/projects/<project>/memory/` (session memory for future agent runs, if you use Claude Code)

**What counts as “learning”:**
- New automation safeguards (locks, TTLs, atomic writes) and clearer queue semantics.
- Repeatable validation fixes (correct working directory, dependency prerequisites).
- Short, imperative pitfalls with evidence (link to a handoff or failing command).

**What does not count:**
- Embedding project-specific implementation logs in this guide. Keep those in the project repo runbook/changelog and link to them.

## Bootstrapping a new project

If you are setting up this workflow from scratch on a new codebase:

```bash
# 1. Create the repo
mkdir my-project && cd my-project && git init && git checkout -b main

# 2. Create the directory structure
mkdir -p .ai/{state/locks,tasks,handoffs,context,prompts,logs} scripts worktrees

# 3. Initialize state files
echo '[]' > .ai/state/queue.json
echo '[]' > .ai/state/runs.json
touch .ai/context/{product,architecture,test-strategy}.md

# 4. Write CLAUDE.md and AGENTS.md (adapt from examples above)

# 5. Write the context files (.ai/context/*.md) for your project

# 6. Copy all scripts from this guide and chmod +x scripts/*.sh
#    Required: claim-task.sh, complete-task.sh, release-stale-locks.sh,
#              create-worktree.sh, fix-task.sh, show-queue.sh,
#              run-backend-loop.sh, run-ui-loop.sh, run-supporting-loop.sh,
#              run-validator-loop.sh, run-all-loops.sh

# 7. Add worktrees/ to .gitignore

# 8. Make the initial commit
git add -A && git commit -m "chore: bootstrap workflow infrastructure"

# 9. Run the product-owner (in Claude Code) to generate tasks for Sprint 1
# 10. Review queue.json
# 11. Run the loop scripts to start execution
```

---

*This workflow was validated on a live multi-agent codebase using two complementary agent runners (for example Claude Code and Codex CLI). The same pattern applies to any project where you want persistent, resumable, multi-agent development without re-explaining context after every session.*

---

## Appendix — Keep case studies elsewhere

This guide should remain cross-project and reusable. If you want to record project-specific implementation updates, validation incidents, or release notes, put them in the project repo (for example `docs/agent-workflow-operations.md` or an internal changelog) and keep this file focused on patterns that generalize.
