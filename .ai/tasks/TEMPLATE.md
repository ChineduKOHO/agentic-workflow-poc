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
