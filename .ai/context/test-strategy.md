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
- Backend unit: >= 70% per package
- Integration: all happy paths + all documented error codes

## Error handling contract
All errors: { "error": { "code": "snake_case", "message": "...", "field": "..." } }
