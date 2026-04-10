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
5. read .ai/context/lessons-learned.md if it exists
6. read the latest handoff if it exists (to resume)
7. implement only the assigned task
8. run required validation commands
9. write handoff to .ai/handoffs/
10. update queue.json

## done rules
A task is NOT done until:
- code is implemented and compiles
- required checks pass
- validation handoff exists
- queue.json status is "done"

## output contract
Every handoff must include:
- summary, files_changed, commands_run, results, blockers, next_step

## execution mode
- default mode is automated via launchd; do not assume manual loop terminals are required
- background implementer loops run every 20 minutes
- validator loop runs every 25 minutes
- dashboard is always-on at http://127.0.0.1:8788
- to force immediate execution: launchctl kickstart -k gui/$(id -u)/com.myproject.<service>
- do not claim tasks manually if automation is running unless explicitly requested
