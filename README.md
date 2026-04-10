# Agentic Workflow — Template Repo

A ready-to-fork template for running Claude Code and Codex CLI as coordinated agents on the same codebase. Each agent picks up scoped tasks from a shared queue, works in an isolated git worktree, writes structured handoffs, and updates shared state — all without relying on chat memory.

Work continues across usage limits, interrupted sessions, and CLI restarts. You never have to re-explain context. You check files, not chat history.

Full reference: [docs/claude-codex-agent-workflow-guide.md](docs/claude-codex-agent-workflow-guide.md)

---

## The mental model

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
│     product-owner · backend-engineer · fullstack-engineer
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

## Repo structure

```
agentic-workflow-poc/
├── README.md
├── CLAUDE.md                    ← agent behaviour rules (read by Claude Code)
├── AGENTS.md                    ← agent behaviour rules (read by Codex + Claude)
├── .ai/
│   ├── state/
│   │   ├── queue.json           ← THE source of truth (starts as empty array)
│   │   └── locks/               ← stale lock detection (gitignored)
│   ├── tasks/
│   │   └── TEMPLATE.md          ← task file template
│   ├── handoffs/
│   │   ├── TEMPLATE-impl.md     ← implementation handoff template
│   │   └── TEMPLATE-validate.md ← validation handoff template
│   ├── context/
│   │   ├── product.md           ← what you're building (fill this in)
│   │   ├── architecture.md      ← tech stack decisions (fill this in)
│   │   └── test-strategy.md     ← what passing looks like per task type
│   ├── prompts/                 ← reusable prompt snippets
│   └── logs/                    ← agent run logs (gitignored)
├── scripts/
│   ├── claim-task.sh            ← atomically claims next eligible task
│   ├── release-stale-locks.sh   ← resets tasks stuck in claimed/in_progress > 4h
│   ├── create-worktree.sh       ← creates isolated git worktree per task
│   ├── fix-task.sh              ← resolves a blocked task with one command
│   ├── run-backend-loop.sh      ← manual mode: print Codex prompt for backend task
│   ├── auto-backend.sh          ← automated mode: run Codex non-interactively
│   └── show-queue.sh            ← pretty-print queue status table
├── launchd/
│   ├── com.myproject.backend.plist    ← run auto-backend.sh every 20 min
│   ├── com.myproject.validator.plist  ← run auto-validator.sh every 25 min
│   └── com.myproject.dashboard.plist  ← keep dashboard_server.py always alive
├── docs/
│   └── claude-codex-agent-workflow-guide.md  ← full reference guide
└── .gitignore
```

---

## Quick start

### Prerequisites

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
python3 --version   # 3.9+
git --version       # 2.5+ for worktree support
brew install jq     # optional, for manual queue inspection
```

### Bootstrap

```bash
# 1. Fork or clone this repo
git clone https://github.com/your-org/agentic-workflow-poc.git my-project
cd my-project

# 2. Make scripts executable
chmod +x scripts/*.sh

# 3. Fill in your project context
#    Edit .ai/context/product.md      — what you're building
#    Edit .ai/context/architecture.md — your tech stack
#    Edit CLAUDE.md and AGENTS.md     — adjust tech stack section if needed

# 4. Run the product-owner to generate Sprint 1 tasks
#    Open Claude Code in this directory and run:
#    "Use the product-owner agent. Read .ai/context/product.md,
#     architecture.md, and test-strategy.md. Break Sprint 1 into
#     implementation tasks. Create task files in .ai/tasks/ and
#     update queue.json. Follow the format in .ai/tasks/TEMPLATE.md."

# 5. Review the queue
./scripts/show-queue.sh
jq '.' .ai/state/queue.json   # full detail

# 6a. Automated mode (recommended) — set up launchd
#     Edit launchd/*.plist to replace /Users/yourname/my-project with your actual path
#     Then load:
for plist in launchd/com.myproject.*.plist; do
  cp "$plist" ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/"$(basename $plist)"
done

# 6b. Manual mode (fallback) — run loop scripts and paste prompts
./scripts/run-backend-loop.sh
# → cd into the printed worktree, then: codex (paste the printed prompt)
```

### Day-to-day commands

```bash
# Check queue status
./scripts/show-queue.sh

# Force immediate run (automated mode)
launchctl kickstart -k gui/$(id -u)/com.myproject.backend
launchctl kickstart -k gui/$(id -u)/com.myproject.validator

# Handle a blocked task
./scripts/fix-task.sh task-014

# Release stale locks manually
./scripts/release-stale-locks.sh

# Watch logs
tail -f .ai/logs/backend-scheduler.log
tail -f .ai/logs/backend-agent.log

# See all worktrees
git worktree list

# Merge a completed task branch
git checkout main
git merge --no-ff agent/task-004 -m "feat: auth API (task-004)"
git worktree remove worktrees/task-004
git branch -d agent/task-004
```

---

## Key files cheat sheet

| What you want to know | Where to look |
|-----------------------|---------------|
| What is the next task? | `queue.json` — first `todo` with deps satisfied |
| What happened in a task? | `.ai/handoffs/task-xxx-impl.md` |
| Did it pass validation? | `.ai/handoffs/task-xxx-validate.md` |
| What should a task do? | `.ai/tasks/task-xxx.md` |
| Who owns a task right now? | `queue.json` → `owner` field |
| Why is a task blocked? | `queue.json` → `resume_from` + handoff `## blockers` |
| Overall status | `./scripts/show-queue.sh` |

---

## Operational rules

1. The repo is the source of truth. Not chat. Not memory. Not your head. The files.
2. One task per agent run. Agents that claim multiple tasks create partial work and unpredictable state.
3. Every run writes a handoff. An agent that implements without a handoff leaves no trail.
4. `queue.json` is updated before the session ends. Status must reflect reality at all times.
5. No skipping validation. A task in `implemented` is not `done`. The validator runs separately.
6. Never ask an agent "where were you?" — check `.ai/handoffs/` and `queue.json` instead.
7. Stale locks recover automatically. The next loop run releases them and the task is reclaimed.

---

See [docs/claude-codex-agent-workflow-guide.md](docs/claude-codex-agent-workflow-guide.md) for the complete reference including queue schema, status lifecycle, worktree patterns, launchd setup, dashboard API, and advanced patterns.
