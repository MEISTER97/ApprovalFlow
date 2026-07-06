# ApprovalFlow Specification and Gap Analysis - Part 2

Last reviewed: 2026-07-06

## Assignment Target

ApprovalFlow must be a local, free-to-run, microservice-based, AI-assisted invoice and expense approval platform. It must ingest invoices asynchronously, evaluate them against policy, auto-approve only safe low-risk items, escalate risky items to a human, run approved items through a consistent payment flow, and provide an auditable decision trail linked by correlation id.

Priority remains:

1. Must-Have and required development-process requirements.
2. Nice-to-Have requirements.
3. Bonus requirements.

## Current Project Snapshot

The current project has advanced substantially since the previous audit.

- `api-gateway`: FastAPI gateway, port `8080`, rate limiting, CORS, correlation-id middleware, `/healthz`, OpenTelemetry instrumentation, and Dapr service invocation forwarding to `workflow-service`.
- `workflow-service`: .NET 10 minimal API state machine. It handles intake, Dapr state, Dapr pub/sub subscriptions, escalation queue, human actions, budget reservation/release, payment success/failure finalization, dashboard metrics, audit endpoint, structured logs, and OpenTelemetry.
- `ai-service`: FastAPI evaluator with deterministic pre-LLM policy gates, mock/Gemini provider switch, Dapr secret fallback, RAG-style policy section retrieval, post-LLM safety guard, structured logs, health check, and OpenTelemetry.
- `payment-service`: FastAPI payment simulator with health check, structured logs, correlation id propagation, payment idempotency ledger, forced failure for `INV-1012`, and `payment_succeeded`/`payment_failed` events.
- `frontend`: Flutter UI for invoice submission, status polling, HITL approve/reject/send-back, audit metadata display, and controller metrics modal.
- `dapr-components`: Redis pub/sub, Redis state store, local file secret store, and resiliency policy.
- `docker-compose.yml`: Redis, Dapr placement, all services, Dapr sidecars, and Jaeger for tracing.
- `.github/workflows/ci.yml`: CI quality gate plus CD image publishing to GHCR after CI.
- `README.md`, `LICENSE`, `.env.example`, reset/test scripts, and architecture docs exist.

## Requirement Status Summary

| Area | Status | Notes |
| --- | --- | --- |
| Core microservices | Mostly done | Gateway, workflow, AI, payment, frontend, Redis, Dapr sidecars, and Jaeger are present. |
| Dapr | Mostly done | Async pub/sub, state, sync invocation, secrets component, and resiliency component exist. Need prove local secret file path and Dapr policy loading. |
| Gateway | Mostly done | Single app ingress on `8080` with rate limiting. Dapr placement and Jaeger ports are still exposed for infrastructure/debugging. |
| AI safety | Mostly done | Deterministic gates and post-LLM guard exist. Some rule IDs and policy edge checks should be aligned to assignment labels. |
| Payment saga | Mostly done | Reservation, failure compensation, and success finalization now exist. Concurrency safety still depends on Dapr state save behavior without explicit ETag/transaction handling. |
| Audit/logging | Mostly done | Audit endpoint and structured logs across services exist. Need verify every line/event carries correlation id in practice. |
| CI/CD | Mostly done | CI and GHCR publishing exist. Needs an actual green run. |
| Documentation | Partial | README exists but contains a surrounding code fence and some overclaims. ADRs and product dilemma doc are still missing. |
| Nice-to-have | Partial/stronger | N2, N3, N4, N5 are partially or mostly implemented. N1 is missing. |
| Bonus | Mostly missing | No MCP server or Kubernetes manifests. B1 is partial via fixture harness but no committed report artifact. |

## Functional Requirements

| ID | Requirement | Current status | Evidence and remaining gap |
| --- | --- | --- | --- |
| F1 | Submit invoice and get immediate tracking id | Mostly done | Gateway forwards to workflow; workflow returns `202 Accepted` with tracking id and correlation id. |
| F2 | Check status and plain-language reason | Mostly done | Gateway exposes invoice status. Workflow stores status, reason, actor, and payment outcome. |
| F3 | Duplicate not paid twice | Partial/mostly done | AI duplicate key and payment ledger exist. Need stronger proof for redelivered events and retry scenarios. |
| F4 | Escalation queue with recommendation/confidence/rules | Partial | Queue exists and returns pending states with violations/reason. Confidence is not stored as a first-class field. |
| F5 | Approve/reject/send back and resume | Mostly done | Workflow supports approve, reject, send-back/more-info. Approve resumes to budget reservation and payment. |
| F6 | Avoid rubber-stamping safe items | Mostly done | Auto-approve path exists and harness checks at least two auto-approvals. Need actual run result. |
| F7 | Configure policy/thresholds without redeploy | Partial/mostly done | `.env.example`, mounted policy, Dapr secret component, and env fallback exist. Local `secrets.json` is not committed and must be documented. |
| F8 | Dashboard metrics | Mostly done | `/api/dashboard/metrics` and Flutter modal exist. Needs verification against full run. |
| F9 | Complete decision trail by correlation id | Mostly done | `/api/audit/{id}` returns payload, rules, reason, final actor, payment outcome, and correlation id. |
| F10 | Prove never auto-approved above limit | Mostly done | Deterministic and post-LLM guards exist; harness includes adversarial and over-ceiling checks. Needs green execution evidence. |

## Must-Have Requirements

| ID | Requirement | Current status | Remaining gap |
| --- | --- | --- | --- |
| M1 | Single private monorepo | Likely done | Monorepo exists. GitHub privacy/contributors cannot be checked locally. |
| M2 | Main holds final evaluated submission | Process item | Current branch is `feature/n3-resiliency`; merge strategy and deadline discipline still matter. |
| M3 | At least 3 containerized services | Done | Gateway, workflow, AI, payment are containerized. |
| M4 | One-command compose stack | Mostly done | Compose includes services, infra, Dapr sidecars, and Jaeger. Needs clean `docker compose up --build` proof. |
| M5 | Dapr sync, async, state, secrets | Mostly done | Gateway uses Dapr invocation, services use pub/sub and state, secretstore component exists. Need local secrets file docs/proof. |
| M6 | API gateway single external entry with rate limit | Mostly done | App traffic enters through gateway. Jaeger and placement remain exposed as infrastructure ports. |
| M7 | Minimal UI | Mostly done | Flutter UI supports main flows. |
| M8 | Async submit and final result delivery | Partial/mostly done | Async submit exists. Final result is delivered by polling, not push notification. Document this as the notification channel or add SSE/webhook. |
| M9 | Consistent payment with compensation | Mostly done | Budget reservation, success finalization, and failure compensation exist. Add ETag/transaction protection or document concurrency limits. |
| M10 | Idempotency everywhere | Partial | Duplicate and ledger guards exist. Missing explicit processed-event idempotency for each pub/sub topic. |
| M11 | Durable HITL pause/resume | Partial/mostly done | Redis-backed queue/state exists. Need restart survival proof. |
| M12 | Provable autonomy ceiling | Mostly done | Hard gates exist. Need green harness/CI evidence. |
| M13 | Externally configurable policy/thresholds | Partial/mostly done | Env, Dapr secret lookup, and mounted policy exist. Need complete local secret setup docs. |
| M14 | Structured logs with correlation id | Mostly done | All three Python services and workflow write structured/correlation logs or correlation output. Need verify every log path. |
| M15 | Clean code, health checks, provider swap, fail cleanly | Mostly done | Health checks and mock provider exist. Code is still monolithic in workflow and AI. |
| M16 | CI quality gates | Mostly done | GitHub Actions CI exists. Needs observed green run. |
| M17 | Automated tests in CI | Partial/mostly done | Script-based core journeys run in CI. Dedicated unit/integration test coverage is still thin. |
| M18 | README with tech/run/test/system diagram | Partial/mostly done | README exists, but starts/ends with markdown code fences and contains a few overclaims/inaccuracies. |

## Development Process Requirements

| ID | Requirement | Current status | Remaining gap |
| --- | --- | --- | --- |
| D1 | Architecture doc with diagrams | Partial/mostly done | `ARCHITECTURE.md` exists, but its gateway flow is stale. `ARCHITECTURE-AGENT.MD` is added in this pass for the AI/agent architecture. |
| D2 | ADRs | Missing | No `docs/adr/` files found. |
| D3 | GitHub Flow and repo hygiene | Partial/mostly done | LICENSE and `.env.example` exist. Current generated `workflow-service/obj` changes should not be committed. |
| D4 | API docs/OpenAPI | Partial | FastAPI gateway docs exist. Root README should point to gateway `/docs`; workflow Swagger is not mapped. |
| D5 | Single verification command | Mostly done | `run-core-journeys.ps1` and `run-harness.ps1` assert results. Need clean run evidence. |
| D6 | README | Partial/mostly done | README exists but needs cleanup. |
| D7 | Demo recording | Missing | No demo URL/file found. |

## Nice-to-Have Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| N1 | AuthN/AuthZ with roles | Missing | No JWT/role enforcement found. |
| N2 | CD publish artifacts | Mostly done | GHCR image publish job exists after CI. Needs successful run proof. |
| N3 | Outbox and bulkhead/throttling | Partial | Dapr resiliency, retries, timeouts, circuit breaker, and gateway rate limiting exist. Outbox pattern is not implemented despite README wording. |
| N4 | OpenTelemetry metrics/traces | Partial/mostly done | Jaeger and service tracing are wired. Need one verified end-to-end trace screenshot or documented proof. Metrics are app-level, not full OTel metrics. |
| N5 | RAG over policy | Partial/mostly done | `retriever.py` chunks and retrieves relevant policy clauses. It is keyword/section retrieval, not vector RAG, but fits a lightweight local implementation. |
| N6 | Tests across layers | Partial | CI and E2E scripts exist, Flutter smoke test exists. Unit/integration depth still limited. |

## Bonus Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| B1 | Eval harness with committed metrics report | Partial | Fixture harness prints a scorecard but does not emit/commit a metrics report. |
| B2 | MCP server | Missing | No MCP server found. |
| B3 | Kubernetes manifests | Missing | No Kubernetes manifests found. |

## Current Risks

1. Verification has not been run in this audit, so compose/harness/CI status is unknown.
2. `README.md` appears wrapped in a markdown code fence and overclaims outbox/CD/RAG details.
3. `ARCHITECTURE.md` still says gateway publishes/saves state directly and references .NET 8, while current code forwards to workflow and targets .NET 10.
4. Dapr `secretstore.yaml` expects `/components/secrets.json`; CI creates it, but local setup must document/create it.
5. No ADRs or product dilemma document exist yet.
6. Pub/sub redelivery idempotency is not explicit.
7. Budget reservation concurrency should use ETags/transactions or be documented as a limitation.
8. `workflow-service/obj` generated files are modified and should not be part of meaningful source changes.

## Part 2 Definition of Done

The project is in strong submission shape when:

- `reset-state.ps1`, `docker compose up --build`, `run-core-journeys.ps1`, and `run-harness.ps1` pass from a clean state.
- CI is green on GitHub and CD publishes images only after CI.
- README and architecture docs accurately describe the implemented flow.
- Local Dapr secret setup is documented and works.
- ADRs and product dilemma doc exist.
- Demo recording is uploaded.
- Any generated `obj` changes are excluded from the final commit unless intentionally required.
