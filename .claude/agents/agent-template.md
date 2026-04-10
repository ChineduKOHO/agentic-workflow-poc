---
name: AGENT-TEMPLATE
model: sonnet
color: blue
memory: user
description: Template for creating new agents.
version: 1.1
last_updated: 2026-04-10
---

# Agent Template (Complete)

## Copy this structure for new agents.

### YAML Header
```
name: [your-agent-name]
model: sonnet
color: [green|cyan|blue|etc]
memory: user
description: [one sentence mission]
version: 1.0
last_updated: [YYYY-MM-DD]
```

### Agent Charter Section
```
Your job:
- [task 1]
- [task 2]
- [task 3]

Rules:
- [rule 1]
- [rule 2]

Scope:
- [work type 1]
- [work type 2]
```

### Output Contract
```
Every completed task must produce:
- [primary output, e.g. edited file, SQL query, document]
- [secondary output, e.g. handoff note, test result]

Never produce:
- [out-of-scope output 1]
- [out-of-scope output 2]
```

### Startup Protocol
```
Before beginning any task:
1. Load MEMORY.md and apply all durable patterns to this session.
2. Restate the task in one sentence to confirm understanding.
3. Identify scope boundaries — what is in and out of scope.
4. Flag any assumptions being made before proceeding.
5. If critical context is missing, surface it now rather than mid-task.
```

### Behavioral Principles
```
### When [task type]
1. [rule 1]
2. [rule 2]

### When [task type 2]
1. [rule 1]
```

### Output Quality Standards
```
- Every [artifact] must include [essential]
- Never [common mistake]
- Always [quality marker]
```

### Communication Style
```
- [style principle 1]
- [style principle 2]
```

### Pre-Work Checklist
```
Before [work], verify:
- [ ] [check 1]
- [ ] [check 2]
```

### Handoff Template
```
[STANDARD FORMAT]
```

### Persistent Agent Memory
```
Path: `/agent-memory/[name]/`
Save: [what to save]
Don't save: [temporary state]
```

### Work Log Format
```
[date]: [task] - [outcome] - [learning]
```

### Self-Improvement Loop
```
1. Quality standards met?
2. Reusable pattern?
3. Update memory?
```

### Stop Conditions and Escalation Protocol
```
Stop immediately when:
- [condition 1]
- [condition 2]

When stopping, always surface:
- One sentence describing the blocker.
- What is needed to unblock (specific, not vague).
- Whether partial output is safe to hand off or should be discarded.

Never silently halt. A stopped task with a clear blocker note is better than
a completed task built on wrong assumptions.
```
