# ApprovalFlow Completion Plan

Last updated: 2026-07-04

## Priority 0 - Submission Blockers

These items must be finished before Nice-To-Have or Bonus work.

1. Add repo hygiene files.
   - Expand `.gitignore` to exclude `.venv`, `bin/`, `obj/`, Flutter build outputs, logs, temp files, and local env files.
   - Add `.env.example` with required variables such as `GEMINI_API_KEY`, `AUTONOMY_CEILING`, provider config, and gateway settings.
   - Add `LICENSE`.

2. Create root documentation.
   - Add `README.md` with purpose, technologies, local prerequisites, one-command run instructions, test instructions, and system diagram.
   - Add `ARCHITECTURE.md` with Mermaid component diagram, request sequence diagram, and payment saga/compensation diagram.
   - Add brief ADRs under `docs/adr/` for:
     - Autonomy posture and USD 250 ceiling.
     - Dapr state/pubsub/service invocation.
     - Payment saga and idempotency strategy.
     - LLM provider abstraction and deterministic router.
   - Add `docs/PRODUCT-DILEMMA.md` explaining why the selected autonomy thresholds are safe but not a "$0 ceiling" dodge.

3. Implement the API gateway.
   - Build the currently empty `api-gateway` service.
   - Make it the single exposed backend entry point.
   - Add rate limiting.
   - Route submit/status/escalation/action/dashboard/audit endpoints through the gateway.
   - Update Flutter `ApiService` to call the gateway instead of workflow service directly.
   - Stop exposing internal services to the host except where needed for local debugging.

4. Demonstrate required Dapr features.
   - Keep pub/sub for submitted/evaluated/approved/payment events.
   - Keep Dapr state for workflow, ledger, idempotency, escalation index, and audit trail.
   - Add one synchronous Dapr service invocation path, for example gateway-to-workflow or workflow-to-payment health/status call.
   - Add Dapr secrets component and move provider/API secrets through it or document local secret loading clearly.

5. Complete deterministic routing.
   - Move hard stops out of the LLM path:
     - Unknown vendor.
     - Missing required receipt.
     - FX over configured ceiling or over USD 1000.
     - Category caps and always-human rules.
     - Alcohol-only rejection.
     - Fraud signals from fixture set.
     - Prompt-injection/adversarial notes.
   - Keep the LLM as recommendation/rationale only.
   - Re-apply the autonomy ceiling after the LLM result before publishing any auto-approve decision.

6. Fix idempotency end to end.
   - Use stable submission id when provided by fixtures, while still generating a tracking id for arbitrary submissions.
   - Store duplicate keys by vendor, invoice number, total, and final effect.
   - Add processed-event keys for pub/sub handlers.
   - Add payment idempotency by business invoice key, not only generated tracking id.
   - Make retry/redelivery paths return the existing state instead of creating new effects.

7. Implement the escalation queue.
   - Maintain a durable escalation index in Dapr state.
   - Return only pending human-review items from `GET /api/escalations`.
   - Include recommendation, confidence, reason, cited policy rules, and original payload.
   - Support approve, reject, and send-back-for-more-info.
   - Remove items from the queue when resolved.

8. Strengthen payment saga and compensation.
   - Add budget reservation state by department.
   - Reserve budget before payment.
   - On payment failure, release reservation and set final state to `PAYMENT_FAILED`.
   - Prevent duplicate payment and orphaned reservations.
   - Handle `INV-1014A/B` concurrency so budget never goes below zero.
   - Document the saga in `ARCHITECTURE.md`.

9. Add audit trail and correlation ids.
   - Introduce a correlation id at submission.
   - Propagate it through Dapr messages, state records, logs, payment events, and UI/API responses.
   - Use structured JSON logs in every service.
   - Add `GET /api/audit/{id}` that returns extracted data, deterministic rules, agent recommendation, final decision, human actor/action, and payment outcome.

10. Add health checks and clean failure modes.
   - Add `/healthz` to every service.
   - Add validation errors for malformed submissions.
   - Make provider errors explicit and route to human review or fail cleanly.
   - Add provider abstraction/config so Gemini can be swapped with a stub/local model.

11. Build a real verification command.
   - Replace or extend `run-harness.ps1` so it submits required fixtures and asserts final states.
   - Print clear pass/fail output.
   - Cover:
     - `INV-1001` auto-approve.
     - `INV-1003` escalation and resume.
     - `INV-1007` duplicate paid once.
     - `INV-1012` payment failure and compensation.
     - At least two no-human auto-approvals.
     - `INV-1013` adversarial "approve me" guard.
     - Above-ceiling never auto-approves.
   - Prefer stubbed model mode for deterministic CI runs.

12. Add automated tests and CI.
   - Backend unit tests for deterministic router, idempotency keys, and payment saga transitions.
   - API integration tests for workflow submission, escalation action, status, and audit endpoints.
   - Frontend smoke test should remain, with text updated if UI changes.
   - Add GitHub Actions workflow to run quality gates on every push.
   - Include the verification harness in CI if runtime cost is acceptable; otherwise add a documented local full verification step.

13. Verify full compose run.
   - Run `docker compose up --build`.
   - Execute the verification command against the composed stack.
   - Capture known limitations in README only if they are not Must-Have blockers.

14. Record demo.
   - Show compose startup or already-running stack.
   - Submit an auto-approved invoice.
   - Submit an escalated invoice, approve it, and show workflow resume.
   - Submit duplicate and payment-failure scenarios.
   - Show audit trail and dashboard.
   - Upload 2-5 minute recording and add URL to submission form.

## Priority 1 - Nice-To-Have

Start only after every Must-Have and required development-process item is complete.

1. Add AuthN/AuthZ.
   - Self-signed JWT is enough.
   - Roles: submitter, approver, admin/controller, auditor.
   - Enforce roles at gateway.

2. Add dashboard metrics.
   - Throughput count.
   - Auto-approved vs human-reviewed counts.
   - Money auto-approved vs human-approved.
   - Payment success/failure counts.
   - Expose via API and frontend dashboard.

3. Add CD.
   - Build Docker images after CI passes.
   - Publish to GitHub Container Registry or another free registry.

4. Add reliability extras.
   - Outbox for state changes plus published events.
   - Bulkhead/throttling around LLM calls and payment calls.

5. Add OpenTelemetry.
   - Instrument gateway, workflow, AI, payment.
   - Propagate trace/correlation ids through Dapr messages.
   - Add one end-to-end trace screenshot or documented trace query.

6. Add RAG over policy.
   - Index `policy.md` by rule section.
   - Retrieve only relevant rules per invoice category/global gates.
   - Keep deterministic router authoritative.

7. Add multi-layer tests.
   - Unit tests.
   - Integration tests with Dapr/Redis.
   - End-to-end tests against compose.

## Priority 2 - Bonus

1. Upgrade the harness into an eval report.
   - Run all labeled fixtures plus hard/adversarial cases.
   - Generate committed metrics report with route accuracy, false auto-approval count, and notes.

2. Build an MCP server for agent tools.
   - Expose tools such as `fetch_policy`, `lookup_vendor`, `check_duplicate`, and `reserve_budget`.
   - Keep deterministic safety outside the model.

3. Add Kubernetes manifests.
   - Local cluster deployment manifests.
   - Redis, Dapr components, services, gateway, and frontend.
   - Document local deployment steps.

## Recommended Order of Work

1. Gateway and repo docs first, because they unblock M6, M18, D1, D3, D4, and demo structure.
2. Deterministic router, idempotency, escalation queue, and payment saga next, because they decide correctness.
3. Verification harness and tests next, because they prove the four required journeys.
4. CI and final README polish last in the Must-Have phase.
5. Nice-To-Have and Bonus only after the harness is green.

## Fastest Path to a Passable Main Branch

If time is tight, do this minimum slice:

1. Implement gateway with rate limiting.
2. Complete deterministic router for all required fixtures.
3. Implement durable escalation queue and send-back action.
4. Add payment reservation/release compensation.
5. Add correlation id and audit endpoint.
6. Make `run-harness.ps1` assert pass/fail for required journeys.
7. Add root README, architecture doc, ADRs, `.env.example`, LICENSE, and CI.
8. Run compose and harness, then record the demo.
