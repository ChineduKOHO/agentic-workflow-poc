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
