# ApprovalFlow Specification and Gap Analysis

Last reviewed: 2026-07-04

## Assignment Goal

Build ApprovalFlow, a local, free-to-run, microservice-based, AI-assisted invoice and expense approval platform. The system must accept invoice submissions asynchronously, evaluate them against an externally configurable policy, auto-approve only safe low-risk items, escalate risky or unclear items to a human approver, process approved payments with compensation on failure, and provide an auditable decision trail linked by correlation id.

The highest priority is to finish every Must-Have and required development-process item before adding Nice-to-Have or Bonus work.

## Current Project Snapshot

The repository currently contains:

- `workflow-service`: .NET minimal API service that accepts invoices, stores workflow state in Dapr state, publishes/subscribes via Dapr pub/sub, pauses for human review, resumes after manager approval, and handles payment-failed compensation events.
- `ai-service`: FastAPI service that subscribes to submitted invoices, loads `policy.md`, applies deterministic checks for duplicate, math mismatch, and hard autonomy ceiling, calls Gemini through LangChain for policy routing, then publishes an evaluation result.
- `payment-service`: FastAPI service that subscribes to approved invoices, applies a payment idempotency guard, simulates a forced failure for `INV-1012`, stores paid ledger state, and publishes success/failure events.
- `frontend`: Flutter UI that can submit an invoice, poll status, and approve/reject an escalated item.
- `dapr-components`: Redis pub/sub and Redis state-store components.
- `docker-compose.yml`: Redis, Dapr placement, the three services, and Dapr sidecars.
- `sample-invoices.json`: assignment fixtures.
- `run-harness.ps1`: submits fixtures to the workflow API, but does not currently assert pass/fail outcomes.

## Product Posture

Current effective autonomy posture:

- Default autonomy ceiling is USD 250.
- Items above the ceiling are deterministically routed to human review before the LLM can auto-approve.
- Math mismatch and duplicate detection are deterministic checks.
- AI confidence below 0.80 is escalated when the model recommends auto-approval.
- Unknown vendor, missing receipt, category caps, reject-only cases, fraud patterns, and prompt-injection resistance currently depend heavily on the LLM and should be moved into deterministic router code for proof and repeatability.

Target posture for submission:

- Keep the USD 250 ceiling unless intentionally changed and justified in `docs/PRODUCT-DILEMMA.md`.
- Make every hard stop deterministic and testable before the LLM result is trusted.
- Treat the LLM as a recommender only. The router must make the final decision.

## Functional Requirements Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| F1 | Async submit with tracking id | Partial | `workflow-service` returns 202 with a generated tracking id and publishes to Dapr. Needs stable external gateway route and idempotent submitted fixture id handling. |
| F2 | Status and plain-language reason | Partial | `GET /api/invoices/{id}` returns state and reason. Needs payment outcome and audit detail completeness. |
| F3 | Duplicate not paid twice | Partial | AI service detects duplicates by vendor, invoice number, and total. Payment service has ledger idempotency by tracking id. Needs duplicate behavior to work with generated IDs and retries/redeliveries. |
| F4 | Escalation queue with recommendation, confidence, cited rules | Missing/Partial | Escalation endpoint returns placeholder message. State stores violations/reason but not confidence or queue listing. |
| F5 | Approve, reject, or send back; resume where paused | Partial | Approve/reject exists. Send-back-for-info is missing. Pause is state-backed. |
| F6 | No rubber-stamping safe items | Partial | Auto-approve path exists. Needs deterministic category checks so eligible fixtures reliably auto-approve without human. |
| F7 | Configure policy and thresholds without redeploy | Partial | `AUTONOMY_CEILING` is environment config and `policy.md` is file-based. Needs Dapr config/secrets or mounted external config and documented reload/update path. |
| F8 | Throughput and approval dashboard | Missing | Frontend has tracker/manager actions but no aggregate dashboard. |
| F9 | Complete decision trail by correlation id | Missing/Partial | State contains basic payload/status/violations/reason. Missing correlation-id propagation, structured logs, agent reasoning fields, final caller, and payment outcome trail. |
| F10 | Prove never auto-approved above limit | Partial | Code has a hard ceiling guard. Needs automated tests/harness proving it, including adversarial "approve me" note. |

## Must-Have Requirements Status

| ID | Requirement | Current status | Gap to close |
| --- | --- | --- | --- |
| M1 | Single private GitHub monorepo | Likely done | Repo is a monorepo. Privacy/contributors cannot be verified locally. |
| M2 | Main holds evaluated submission and stops at deadline | Process item | Must be handled in GitHub before 2026-07-12 EOD. |
| M3 | At least 3 containerized services | Done | Workflow, AI, and payment services each have Dockerfiles. |
| M4 | Single `docker compose up` brings up system | Partial | Compose exists for services, Redis, Dapr sidecars. Frontend and API gateway are not included. Need verify full startup. |
| M5 | Dapr sync, async, state, and secrets | Partial | Async pub/sub and state exist. Dapr sync service invocation is not evident. Dapr secrets are not configured. |
| M6 | API gateway as only external entry point with rate limiting | Missing | `api-gateway` is empty and workflow service is exposed directly. |
| M7 | Minimal UI | Partial | Flutter UI can submit/status/action. Needs compose/run docs and may need gateway URL. |
| M8 | Async intake and notification channel | Partial | Async intake exists. Final result is polled, not delivered via notification channel. |
| M9 | Payment consistency with compensation | Partial | Failure event updates state to `PAYMENT_FAILED`. No reservation step, no budget release, no atomic saga state, no concurrency protection. |
| M10 | Idempotency for duplicate submissions, redelivered events, retried payments | Partial | Some guards exist. Needs event idempotency keys and retry-safe state transitions across services. |
| M11 | Durable HITL pause/resume survives restart | Partial | Pause state is Redis-backed. Needs queue/index for escalations and verification after restart. |
| M12 | Provably incapable of over-ceiling auto-approve | Partial | Hard ceiling exists. Needs deterministic tests and final-router enforcement after model output as defense in depth. |
| M13 | Externally configurable policy/thresholds | Partial | Env var/file only. Needs Dapr config/secrets or mounted config with documented change path. |
| M14 | Structured logs with correlation id on every line | Missing | Services use plain `print`/`Console.WriteLine`; no consistent correlation id. |
| M15 | Clean code, error handling, health checks, separation, swappable LLM provider | Partial | Basic error handling exists. Missing health checks, provider abstraction/config, stronger validation, and cleaner module separation. |
| M16 | CI quality gates on every push | Missing | `.github/workflows` appears empty. |
| M17 | Automated tests in CI | Missing/Partial | Flutter smoke test exists, but no CI and little backend coverage. |
| M18 | README with tech, run, test, system diagram | Missing | Only default Flutter README exists. Root README is missing. |

## Required Development Process Status

| ID | Requirement | Current status | Gap to close |
| --- | --- | --- | --- |
| D1 | `ARCHITECTURE.md` with sequence and payment compensation diagrams | Missing | Create architecture doc with Mermaid diagrams. |
| D2 | ADRs for key decisions | Missing | Add short human-owned ADRs for autonomy posture, Dapr, saga/idempotency, LLM provider. |
| D3 | GitHub Flow and repo hygiene | Partial | Git branch is `main` and clean. Missing `LICENSE`, `.env.example`; `.gitignore` is too small and does not ignore venv/build outputs. |
| D4 | API documentation/OpenAPI | Partial | FastAPI and .NET can expose OpenAPI, but root API contract docs are missing. |
| D5 | Single command verification of four journeys and anti-cheese guards | Partial | `run-harness.ps1` submits fixtures only. It does not assert results, payment outcomes, restart behavior, two auto-approvals, or prompt-injection guard. |
| D6 | README documentation | Missing | Root README needed. |
| D7 | 2-5 minute demo recording | Not in repo | Must be recorded and uploaded for submission. |

## Nice-To-Have Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| N1 | AuthN/AuthZ with roles | Missing | No JWT or role enforcement. |
| N2 | CD build/publish artifacts | Missing | No CI/CD workflow yet. |
| N3 | Outbox and bulkhead/throttling | Missing | No outbox; rate limiting absent. |
| N4 | OpenTelemetry metrics and trace | Missing | No OTel setup. |
| N5 | RAG over policy document | Missing | Entire policy is placed in prompt. |
| N6 | Tests across layers | Missing/Partial | Only frontend smoke test is visible. |

## Bonus Status

| ID | Requirement | Current status | Notes |
| --- | --- | --- | --- |
| B1 | Automated eval harness with metrics report | Missing/Partial | Fixture harness exists, but not a scoring eval harness with committed report. |
| B2 | MCP server for agent tools | Missing | Not started. |
| B3 | Kubernetes manifests | Missing | Not started. |

## Main Risks

1. The missing API gateway and rate limiting are must-have blockers.
2. The harness currently does not prove correctness; it only submits data.
3. The escalation queue is not implemented, so approver story F4 is not met.
4. Payment saga is too shallow for M9 because there is no reservation/release model or concurrency-safe budget protection.
5. Correlation-id logging and audit trail are missing, which affects F9, M14, and observability claims.
6. Deterministic routing is incomplete; several hard stops still rely on the LLM.
7. CI, tests, README, architecture docs, ADRs, `.env.example`, and LICENSE are missing or incomplete.
8. Dapr secrets and synchronous service invocation are not yet demonstrated.
9. `.gitignore` does not ignore `.venv`, build, and generated outputs, increasing repo hygiene risk.

## Definition of Done for Main Submission

The project is ready for `main` submission when:

- `docker compose up` starts the gateway, all services, Dapr sidecars, Redis, and the UI or documented UI target.
- All external API/UI access goes through the gateway.
- The single verification command passes the four required journeys:
  - `INV-1001`: auto-approve with no human.
  - `INV-1003`: escalate, pause, human action, resume.
  - `INV-1007`: duplicate of `INV-1001`, no second payment.
  - `INV-1012`: human approval followed by payment failure and compensation.
- Anti-cheese guards pass:
  - At least two fixtures auto-approve without human action.
  - Over-ceiling invoices never auto-approve, even with adversarial notes.
  - Duplicate submissions, redelivered events, and retried payments have exactly one effect.
- CI runs backend/frontend tests and quality checks.
- Root README, architecture diagrams, ADRs, API docs, `.env.example`, LICENSE, and demo link are ready.
