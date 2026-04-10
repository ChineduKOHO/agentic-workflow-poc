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
