# ApprovalFlow Specification and Gap Analysis

Last reviewed: 2026-07-04

## Assignment Goal

Build ApprovalFlow, a local, free-to-run, microservice-based, AI-assisted invoice and expense approval platform. The system must accept invoices asynchronously, evaluate them against a configurable policy, auto-approve only safe low-risk items, route risky or unclear items to a human approver, process approved payments with compensation on failure, and expose an auditable decision trail linked by correlation id.

Priority order remains:

1. Finish every Must-Have and required development-process item.
2. Then complete Nice-to-Have work.
3. Then attempt Bonus items.

## Current Project Snapshot

The project now contains:

- `api-gateway`: FastAPI gateway on port `8080`, with rate limiting, correlation-id middleware, CORS, `/healthz`, and Dapr service invocation forwarding to `workflow-service`.
- `workflow-service`: .NET minimal API service that stores workflow state in Dapr state, receives evaluated invoices, manages escalation queue state, handles human actions, reserves/releases department budgets, exposes audit and dashboard endpoints, and writes structured JSON logs.
- `ai-service`: FastAPI service that subscribes to `invoice_submitted`, applies deterministic pre-LLM guards, optionally calls Gemini or mock provider, applies post-LLM safety guards, and publishes `invoice_evaluated`.
- `payment-service`: FastAPI service that subscribes to approved invoices, applies a ledger idempotency guard, simulates `INV-1012` payment failure, stores paid ledger state, and publishes payment success/failure events.
- `frontend`: Flutter UI that submits invoices through the gateway, polls invoice state, supports approve/reject/send-back actions, displays correlation/audit metadata, and opens live controller metrics.
- `dapr-components`: Redis pub/sub and Redis state-store components.
- `docker-compose.yml`: Redis, Dapr placement, API gateway, workflow service, AI service, payment service, and sidecars. Only the gateway is exposed to the host.
- `.github/workflows/ci.yml`: CI job that builds the compose stack and runs `run-ci-tests.ps1`.
- `run-ci-tests.ps1`: CI smoke/quality gate script against the gateway.
- `run-core-journeys.ps1`: focused journey and anti-cheese verification script.
- `run-harness.ps1`: all-fixture verification/report script.
- `ARCHITECTURE.md`: architecture and payment saga diagrams.
- `SPEC.MD` and `PLAN.MD`: this audit and execution plan.

## Product Posture

Current autonomy posture:

- Default autonomy ceiling is USD 250.
- The AI service runs deterministic checks before model use for duplicate, math mismatch, receipt, vendor, FX, fraud signals, category hard stops, and autonomy ceiling.
- A post-LLM guard re-blocks auto-approval above the ceiling and blocks low-confidence auto-approval.
- `LLM_PROVIDER=mock` is available for deterministic CI/fallback behavior.
- The model is treated as advisory; deterministic guards hold the core safety posture.

Remaining posture gaps:

- Some policy details still appear simplified or fixture-focused. Examples: meal attendee limits, SaaS monthly cap, alcohol-only rejection, client entertainment details, and first/business-class travel should be explicitly deterministic if they are required by the fixtures or demo.
- `run_pre_llm_guard` should be hardened against both camelCase and PascalCase payload keys for every checked field.
- The mock provider currently auto-approves only `total_usd <= 150`; this may not match every expected auto-approve fixture such as `INV-1017` at USD 180.
- A product-dilemma document is still missing. The USD 250 posture needs a written defense.

## Functional Requirements Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| F1 | Async submit with tracking id | Mostly done | Gateway routes to workflow; workflow returns 202 with tracking id and correlation id, saves state, and publishes asynchronously. Need run verification. |
| F2 | Status and plain-language reason | Mostly done | `GET /api/invoices/{id}` returns state/reason via gateway. Payment success state is not yet reflected back into workflow. |
| F3 | Duplicate not paid twice | Partial | Duplicate guard and payment ledger exist. Needs stronger retry/redelivery idempotency and proof that duplicate submissions preserve one financial effect. |
| F4 | Escalation queue with recommendation, confidence, cited rules | Partial | Durable escalation index exists and returns pending items. State includes reason/violations but not a separate confidence field or structured cited-rule detail. |
| F5 | Approve, reject, or send back; resume where paused | Mostly done | Approve/reject/send-back actions exist. Approve resumes into budget reservation and payment event. Need restart-survival test. |
| F6 | No rubber-stamping safe items | Partial | Auto-approve path exists and harness targets at least two auto-approvals. Deterministic category eligibility needs more complete coverage. |
| F7 | Configure policy and thresholds without redeploy | Partial | `AUTONOMY_CEILING`, `LLM_PROVIDER`, and `policy.md` mount exist. Dapr config/secrets and a documented update path are still missing. |
| F8 | Dashboard of throughput/rates/money | Mostly done | Workflow exposes `/api/dashboard/metrics`; gateway and Flutter call it. Need verify metrics correctness after full journey run. |
| F9 | Complete decision trail by correlation id | Partial | Audit endpoint exists with correlation id, payload, rules, reason, actor, and payment outcome. Structured logs exist in gateway/workflow/AI. Payment-service still uses plain logs and success payment outcome is not sent back to workflow. |
| F10 | Prove never auto-approved above limit | Partial | Pre/post LLM guards and anti-cheese harness exist. Need run evidence and add/keep CI coverage for over-ceiling + prompt injection. |

## Must-Have Requirements Status

| ID | Requirement | Current status | Gap to close |
| --- | --- | --- | --- |
| M1 | Single private GitHub monorepo | Likely done | Monorepo is present. Privacy/contributors cannot be verified locally. |
| M2 | Main holds evaluated submission and stops at deadline | Process item | Must be handled in GitHub by 2026-07-12 EOD. |
| M3 | At least 3 containerized services | Done | Gateway, workflow, AI, and payment are containerized. |
| M4 | Single `docker compose up` brings up system | Mostly done | Compose includes gateway, services, Redis, placement, sidecars. Frontend is not in compose but can run separately. Full startup not verified in this pass. |
| M5 | Dapr sync, async, state, and secrets | Partial | Async pub/sub, state, and sync service invocation through gateway are present. Dapr secrets component is still missing. |
| M6 | API gateway as only external entry point with rate limiting | Mostly done | Gateway exists, has rate limits, and compose exposes only `8080` for app traffic. Placement port `50005` is still exposed for Dapr. |
| M7 | Minimal UI | Mostly done | Flutter UI supports submit/status/HITL/metrics through gateway. Need smoke test update if UI text changed. |
| M8 | Async intake and notification channel | Partial | Async intake exists. Final result is still polling, not a push notification channel. If polling is accepted as UI delivery, document it clearly. |
| M9 | Consistent payment with compensation | Partial | Budget reservation/release and failure compensation exist in workflow. Payment success does not update workflow final state; atomic/concurrency guarantees depend on Dapr state entry save without explicit ETag handling. |
| M10 | Idempotency for duplicates, redelivered events, retried payments | Partial | Duplicate and payment ledger guards exist. Missing processed-event idempotency for pub/sub redelivery and business-key ledger protection across generated IDs. |
| M11 | Durable HITL pause/resume survives restart | Partial | Escalation queue and state are in Redis. Need restart test in harness or docs. |
| M12 | Provably incapable of over-ceiling auto-approve | Mostly done | Pre-LLM and post-LLM guards exist. Need test evidence and possibly a unit test around forced approve recommendation. |
| M13 | Externally configurable policy/thresholds | Partial | Env and mounted policy file exist. Dapr config/secrets or documented no-redeploy change procedure remains. |
| M14 | Structured logs with correlation id on every line | Partial | Gateway, workflow, and AI use structured/correlation logging. Payment-service still uses plain `print` and does not propagate correlation id in logs/events. |
| M15 | Clean code, error handling, health checks, separation, swappable LLM provider | Partial | Gateway/workflow/AI have health checks; AI provider is swappable. Payment-service lacks `/healthz`; some code remains monolithic and error handling is thin. |
| M16 | CI quality gates on every push | Mostly done | GitHub Actions workflow exists and runs compose plus `run-ci-tests.ps1`. Needs a real run to confirm it passes. |
| M17 | Automated tests in CI | Partial | CI smoke tests exist. Backend unit/integration tests are still light; current tests are mostly script-based E2E checks. |
| M18 | README with tech, run, test, system diagram | Missing/Partial | `ARCHITECTURE.md` exists, but root `README.md` is still missing. |

## Required Development Process Status

| ID | Requirement | Current status | Gap to close |
| --- | --- | --- | --- |
| D1 | `ARCHITECTURE.md` with sequence and payment compensation diagrams | Mostly done | Architecture doc exists. It should be corrected where it says gateway publishes/saves state directly; current gateway forwards to workflow via Dapr invocation. It also says .NET 8 while csproj targets .NET 10. |
| D2 | ADRs for key decisions | Missing | No `docs/adr/` files found. Add human-written ADRs. |
| D3 | GitHub Flow and repo hygiene | Partial | `.gitignore` is much better. Still missing `LICENSE` and `.env.example`; `.venv/` should be explicitly ignored. Current branch is `main`; PR history cannot be verified locally. |
| D4 | API docs/OpenAPI | Partial | FastAPI gateway has OpenAPI docs. Workflow has OpenAPI package but no visible Swagger mapping. Root API documentation is still missing. |
| D5 | Single command verification | Partial/Mostly done | `run-core-journeys.ps1`, `run-harness.ps1`, and CI script now assert pass/fail. They still need to be run and may need fixes for timing, fresh state, PowerShell version, and expected final statuses. |
| D6 | README documentation | Missing | Root README is still missing. |
| D7 | 2-5 minute demo recording | Not in repo | Must be recorded/uploaded for submission. |

## Nice-To-Have Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| N1 | AuthN/AuthZ with roles | Missing | No JWT or role enforcement. |
| N2 | CD build/publish artifacts | Missing | CI exists, but no publish stage. |
| N3 | Outbox and bulkhead/throttling | Partial | Gateway rate limiting exists. No outbox or clear bulkhead around LLM/payment calls. |
| N4 | OpenTelemetry metrics and trace | Missing | Correlation ids exist, but no OTel tracing/metrics setup. |
| N5 | RAG over policy document | Missing | Full policy is still loaded into prompt. |
| N6 | Tests across layers | Partial | Flutter smoke test, CI script, and harnesses exist. Dedicated unit/integration tests are still thin. |

## Bonus Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| B1 | Automated eval harness with metrics report | Partial | `run-harness.ps1` runs all fixtures and prints a scorecard. It does not generate a committed metrics report artifact yet. |
| B2 | MCP server for agent tools | Missing | Not started. |
| B3 | Kubernetes manifests | Missing | Not started. |

## Main Remaining Risks

1. Dapr secrets are not implemented, so M5/M13 are still only partially satisfied.
2. Root README, LICENSE, `.env.example`, ADRs, and product dilemma documentation are missing.
3. Verification scripts exist but have not been run in this audit; they may fail due to stack timing, stale Redis state, PowerShell compatibility, or status expectations.
4. Payment success is not consumed by workflow, so successful payments may remain `BUDGET_RESERVED` instead of a final `PAID` state.
5. Payment-service lacks structured correlation logs and `/healthz`.
6. Pub/sub redelivery idempotency is incomplete.
7. Architecture documentation needs alignment with the actual gateway behavior and .NET target version.
8. Deterministic routing should be made complete for all policy hard stops and all fixture labels.
9. No authentication/authorization, OTel, RAG, outbox, CD, MCP, or Kubernetes work is present yet.

## Updated Definition of Done for Main Submission

The project is ready for `main` submission when:

- `docker compose up --build` starts the gateway, services, Dapr sidecars, Redis, and placement cleanly.
- All external app traffic goes through `http://localhost:8080`.
- `run-core-journeys.ps1` passes from a fresh state.
- `run-harness.ps1` passes or clearly documents any non-blocking fixture deviations.
- CI passes on GitHub using mock/stub LLM mode.
- Dapr async pub/sub, sync service invocation, state, and secrets are all demonstrated.
- Audit output and logs include correlation ids across gateway, workflow, AI, and payment.
- Payment success and payment failure both end in explicit workflow states.
- Root README, architecture doc, ADRs, API docs, `.env.example`, LICENSE, and demo link are ready.
