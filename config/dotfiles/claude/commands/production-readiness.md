# Production Readiness — Engineering Discipline for AI-Assisted Development

Apply engineering discipline proactively to counter the technical debt that accumulates when AI-assisted development prioritizes speed over fundamentals. Treat AI as a brilliant junior developer — fast but requiring guidance on architecture, security, and maintainability.

## Core Principle

**The senior engineer is still the human.** AI gives what is asked for. Proper error handling, environment separation, and security practices must be explicitly requested and verified.

## When to Apply

This operates in two modes:

### Proactive Mode (During Development)

When implementing features or starting projects, apply these practices inline:

1. **Before writing code** — Consider architecture. Break components early rather than refactoring god objects later.
2. **While writing code** — Validate inputs server-side, wrap external services in service layers, handle unhappy paths.
3. **Before committing** — Scan for hardcoded secrets, verify environment separation, confirm error handling exists.

### Audit Mode (Review & Pre-Deployment)

When reviewing existing code or preparing for deployment, perform a systematic audit using the detailed checklist below.

## The 11 Practice Areas

### 1. Secrets & Environment Separation
Keep secrets out of source code. Use environment variables or a secrets manager. Maintain separate credentials per environment (dev, staging, prod). Never reuse the same API token across environments.

### 2. Observability
Integrate crash reporting from day one. Use structured logging that persists beyond the terminal. Add a `/health` endpoint that verifies dependency connectivity, not just returns 200.

### 3. Service Layer Architecture
Wrap external API calls in dedicated service classes. Add timeouts, retry with backoff, and circuit breakers. Apply rate limiting on authentication and write endpoints. Design for provider swappability.

### 4. Input Validation & Security
Validate all input server-side — never trust the client. Use parameterized queries. Escape HTML output. Set CORS to specific origins, not `*`. Validate file uploads by content, not just extension.

### 5. Architecture & Database Design
Enforce separation of concerns early. Manage schema changes through versioned migrations, not ad-hoc modifications. Add indexes for query patterns. Break components at ~300 lines.

### 6. Environment & Deployment
Maintain a staging environment that mirrors production. Externalize configuration. Deploy through CI/CD pipelines, never from laptops. Test backup restores — not during emergencies.

### 7. Documentation
Document setup, run, test, and deploy procedures. Test setup docs on a clean environment. Document every environment variable. Record architecture decisions.

### 8. CI/CD Pipeline
Automate tests on every push. Enforce linting. Scan dependencies for vulnerabilities. Build artifacts in the pipeline. Protect the main branch.

### 9. Technical Debt Management
Fix it now or create a tracked ticket with a deadline. "Later" never comes. Use proper feature flag systems, not commented-out code. Remove dead code and unused dependencies.

### 10. Error Handling & Unhappy Paths
AI-generated code handles the sunny day scenario beautifully. Intentionally test: network failures, unexpected API responses, malformed input, background job failures. Write tests for error cases, not just success.

### 11. Time Handling
Store all timestamps in UTC. Convert to local time only at the display layer. Use timezone-aware types. Test scheduled operations across DST boundaries. Serialize with ISO 8601.

## Quick Development Checklist

For each code change, verify:
- [ ] No hardcoded secrets introduced
- [ ] External calls wrapped with timeout and error handling
- [ ] Input validated server-side
- [ ] Error scenarios handled (not just happy path)
- [ ] Timestamps in UTC
- [ ] Architecture clean (no god objects growing)

## New Project Foundations

When starting a new project, establish before writing features:

1. Set up environment variable management and `.env.example`
2. Add crash reporting / error tracking SDK
3. Create CI pipeline (lint + test + build minimum)
4. Set up structured logging
5. Add health check endpoint
6. Document setup in README
7. Configure branch protection

## Key Anti-Patterns to Flag

| Pattern | Problem | Fix |
|---------|---------|-----|
| `CORS: *` in production config | Security bypass | Set specific allowed origins |
| `console.log` as only logging | No persistence or structure | Add structured logging service |
| TODO/FIXME without ticket number | Untracked debt | Create tracked issue or fix now |
| Same API key in dev and prod | Blast radius on compromise | Separate credentials per env |
| No `.env` in `.gitignore` | Secrets at risk of commit | Add immediately, rotate if leaked |
| Schema changes without migrations | Unreproducible state | Use migration framework |
| Tests only cover happy path | Fragile in production | Add error scenario tests |
| Deploy from local machine | Unreproducible, risky | Set up CI/CD pipeline |

## Detailed Audit Checklist

Use the sections below for comprehensive pre-deployment review. Each area includes what to verify, common AI-generated pitfalls, and remediation steps.

### Secrets & Environment Separation

**Verify:** No hardcoded secrets in source. `.env` gitignored with `.env.example`. Separate credentials per environment. Secrets from env vars or secrets manager. No secrets in CI/CD logs.

**AI pitfalls:** Placeholder keys left in code (`sk-test-xxx`). Same token across environments. Secrets as CLI arguments. `.env` committed before gitignore.

**Fix:** Scan with `grep -rn "api_key\|secret\|token\|password" --include="*.{ts,js,py,go,swift,kt}" .` — rotate any credential ever committed. Use platform-native secret storage.

### Observability

**Verify:** Crash reporting integrated. Structured logging with severity levels. Logs persist to aggregation. Health endpoint checks dependencies. Business metrics tracked.

**AI pitfalls:** `console.log` as "logging". Error reporting on TODO list. Health returns 200 when deps are down.

**Fix:** Add error reporting SDK before first deploy. Health endpoint checks DB and critical deps. Structured logging from day one.

### Service Layer Architecture

**Verify:** External APIs wrapped in service classes. Retry with exponential backoff. Circuit breakers. Rate limiting on auth and writes. Caching layer. Timeouts on all external calls.

**AI pitfalls:** Direct HTTP calls scattered everywhere. No timeouts. Retry without backoff. No rate limiting. Cache invalidation ignored.

**Fix:** Service layer per dependency. Timeout + retry + circuit breaker per service. Rate limiting middleware on auth and mutations.

### Input Validation & Security

**Verify:** Server-side validation on all input. Parameterized SQL. Escaped HTML. File uploads validated by content. Auth tokens validated every request. CORS with specific origins.

**AI pitfalls:** Frontend-only validation. Happy-path focus. CORS `*`. No content-type verification on uploads.

**Fix:** Server-side validation middleware. ORM parameterized queries. Explicit CORS origins per environment.

### Architecture & Database Design

**Verify:** Separation of concerns. Schema changes via versioned migrations. Indexes on queried columns. Foreign key constraints.

**AI pitfalls:** God objects. Ad-hoc schema changes. Missing indexes. No data growth consideration. Circular dependencies.

**Fix:** Break components at ~300 lines. Use migration tools. Review query plans for N+1 and missing indexes.

### Environment & Deployment

**Verify:** Staging mirrors production. Config externalized. CI/CD deploys. Rollback documented and tested. Backups tested with restore. SSL/TLS everywhere.

**AI pitfalls:** Only dev and prod. Config in build artifacts. Laptop deploys. Untested backups.

**Fix:** Match staging to prod infrastructure. Externalize all config. CI/CD even if minimal. Quarterly restore tests.

### Documentation & Runbooks

**Verify:** README covers setup/run/test. Deploy process documented. API docs exist. ADRs recorded. Env vars documented.

**AI pitfalls:** Setup only works on author's machine. Outdated docs. Missing env var docs.

**Fix:** Test docs on clean machine. Generate API docs from annotations. Document every env var in `.env.example`.

### CI/CD Pipeline

**Verify:** Tests on every push/PR. Linting enforced. Security scanning. Pipeline builds artifacts. Branch protection on main.

**AI pitfalls:** No CI. Tests not wired to CI. Pipeline only on main. No vulnerability scanning.

**Fix:** Minimal CI: lint + test + build. Add Dependabot/Snyk. Branch protection on main.

### Technical Debt Management

**Verify:** No untracked "fix later" comments. Feature flags via proper system. Dead code removed. TODOs have ticket numbers.

**AI pitfalls:** Silent debt accumulation. Commented-out code as feature flags. Unused code left behind.

**Fix:** Every TODO becomes a tracked ticket. Config-driven feature flags. Regular cleanup sprints.

### Error Handling & Unhappy Paths

**Verify:** Network failures handled. Unexpected API shapes handled. User errors don't leak internals. Background jobs have failure handling. Graceful degradation.

**AI pitfalls:** Happy-path only. Catch-all swallows failures. Stack traces exposed. Silent background failures.

**Fix:** Tests for error scenarios. Typed error handling. Network simulation testing.

### Time Handling

**Verify:** UTC storage. Local conversion at display only. Timezone-aware types. DST in scheduled jobs. ISO 8601 serialization.

**AI pitfalls:** Mixed UTC/local. Language defaults to local time. Naive datetime comparisons. DST double-fire in cron.

**Fix:** UTC at storage and API layer. Timezone-aware types exclusively. Test across DST boundaries.

## Quick Scan Commands

Adjust paths to match the target project structure.

```bash
# Hardcoded secrets
grep -rn "api_key\|secret\|token\|password\|credential" --include="*.{ts,js,py,go,rb,swift,kt,java}" .

# Untracked TODOs
grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.{ts,js,py,go,rb,swift,kt,java}" . | grep -v "#[A-Z]*-[0-9]"

# Wildcard CORS
grep -rn "Access-Control-Allow-Origin.*\*\|cors.*origin.*\*\|AllowAllOrigins" --include="*.{ts,js,py,go,rb,swift,kt,java}" .

# Console.log count
grep -rn "console\.log\|print(" --include="*.{ts,js,py}" . | wc -l

# .env in gitignore
grep -q "\.env" .gitignore && echo "OK: .env in gitignore" || echo "WARNING: .env not in gitignore"
```
