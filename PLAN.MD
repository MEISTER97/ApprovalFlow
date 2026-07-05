# ApprovalFlow Completion Plan

Last updated: 2026-07-04

## Priority 0 - Must-Have Finish Line

The project has moved from "skeleton" to "working candidate." The remaining work is mostly proof, polish, and closing must-have gaps.

1. Verify the stack from a clean state.
   - Start with a fresh Redis/container state.
   - Run `docker compose up --build`.
   - Confirm gateway health at `http://localhost:8080/healthz`.
   - Run `run-core-journeys.ps1`.
   - Run `run-harness.ps1`.
   - Capture failures and fix them before adding optional features.

2. Fix payment finalization.
   - Add `payment_succeeded` subscription in `workflow-service`.
   - Update invoice status to `PAID` or `PAYMENT_SUCCEEDED`.
   - Set `PaymentOutcome` to a final success message.
   - Keep `PAYMENT_FAILED` compensation behavior for `INV-1012`.
   - Update harness expectations if final status changes from `BUDGET_RESERVED` to `PAID`.

3. Finish payment-service cross-cutting requirements.
   - Add `/healthz`.
   - Add structured JSON logging.
   - Propagate and log correlation id from invoice state/event payload.
   - Include correlation id in `payment_failed` and `payment_succeeded` events.
   - Remove stray citation-like text from logs.

4. Complete Dapr secrets/config story.
   - Add a Dapr secret-store component for local development.
   - Move or document `GEMINI_API_KEY` loading through Dapr secrets.
   - Add an externally configurable threshold source or document env/mounted policy update procedure clearly.
   - Ensure `AUTONOMY_CEILING` in docs, compose, tests, and policy all match.

5. Harden deterministic routing.
   - Normalize payload keys once in AI service so camelCase and PascalCase both work.
   - Add deterministic checks for:
     - `MEAL-01` attendee requirement and per-attendee cap.
     - `MEAL-02` client entertainment over USD 500.
     - `MEAL-03` alcohol-only rejection.
     - `SAAS-01` subscriptions over USD 200/month.
     - `TRAVEL-03` first/business-class travel.
   - Keep post-LLM ceiling override as defense in depth.
   - Make mock provider decisions align with expected auto-approve fixtures.

6. Strengthen idempotency.
   - Add processed-event keys for `invoice_submitted`, `invoice_evaluated`, `invoice_approved`, `payment_failed`, and `payment_succeeded`.
   - Make repeated `POST /api/invoices` for the same business invoice return or preserve existing state.
   - Use business payment key in payment ledger, not only tracking id.
   - Add harness checks for duplicate submit and payment retry behavior.

7. Prove durable HITL pause/resume.
   - Add a verification step that submits an escalated invoice, restarts workflow service, then approves it.
   - Confirm the item remains in the escalation queue after restart.
   - Document this in README.

8. Correct and complete documentation.
   - Add root `README.md` with technologies, run steps, test steps, API gateway URL, system diagram, and demo flow.
   - Update `ARCHITECTURE.md` so gateway is shown as forwarding to workflow via Dapr service invocation, not directly publishing/saving state.
   - Correct runtime/version notes such as .NET target version.
   - Add API section listing gateway endpoints and links to OpenAPI docs.
   - Add `docs/PRODUCT-DILEMMA.md` explaining the USD 250 autonomy posture.
   - Add human-written ADRs under `docs/adr/`:
     - Autonomy ceiling and router-decides pattern.
     - Dapr pub/sub/state/service invocation/secrets.
     - Payment saga and compensation.
     - LLM provider abstraction and mock CI mode.

9. Finish repo hygiene.
   - Add `.env.example`.
   - Add `LICENSE`.
   - Add `.venv/` and local temp/output folders to `.gitignore`.
   - Check that no secrets are committed.
   - Keep all final evaluated work on `main` before the 2026-07-12 EOD deadline.

10. Tighten CI.
   - Make CI set `LLM_PROVIDER=mock` in a way compose actually passes to `ai-service`.
   - Ensure `run-ci-tests.ps1` is compatible with the GitHub runner PowerShell version.
   - Add log dump and compose shutdown cleanup.
   - Add at least one over-ceiling/prompt-injection assertion to CI.
   - Consider running `run-core-journeys.ps1` in CI after the lighter smoke checks.

11. Add or improve automated tests.
   - Unit-test AI deterministic guards.
   - Unit-test workflow status transitions and budget reservation/release logic.
   - Add an integration test for gateway-to-workflow Dapr invocation.
   - Keep Flutter smoke test passing after UI text changes.

12. Record demo.
   - Show gateway health and UI.
   - Submit `INV-1001` or equivalent auto-approve.
   - Submit `INV-1003`, show escalation queue, approve, and resume.
   - Submit `INV-1007`, show duplicate is discarded.
   - Submit/approve `INV-1012`, show payment failure and compensation.
   - Show audit endpoint and dashboard metrics.
   - Upload 2-5 minute recording and use the URL in the submission form.

## Priority 1 - Nice-To-Have

Start this only after the Must-Have harness and CI are green.

1. Add AuthN/AuthZ.
   - Add self-signed JWT support at the gateway.
   - Roles: submitter, approver, admin/controller, auditor.
   - Restrict escalation actions, dashboard, and audit endpoints by role.

2. Improve dashboard depth.
   - Add payment success/failure counts.
   - Add average processing latency.
   - Add open escalation count and oldest escalation age.
   - Add frontend view beyond modal if time allows.

3. Add CD.
   - Build Docker images after CI passes.
   - Publish to GitHub Container Registry or another free registry.
   - Keep CD separate from required CI if time is tight.

4. Add reliability extras.
   - Implement outbox records for state changes plus published events.
   - Add retry-safe outbox drain.
   - Add LLM/payment bulkheads and timeouts.
   - Add dead-letter or poison-message handling notes.

5. Add OpenTelemetry.
   - Instrument gateway, workflow, AI, and payment.
   - Propagate trace context through Dapr messages.
   - Add one documented end-to-end trace tied to correlation id.

6. Add RAG over policy.
   - Split `policy.md` into retrievable rule sections.
   - Retrieve category/global clauses per invoice.
   - Keep deterministic router authoritative after retrieval.

7. Expand tests across layers.
   - Unit tests.
   - Integration tests with Redis/Dapr.
   - End-to-end tests against compose.
   - Frontend widget tests for submit/HITL/metrics states.

## Priority 2 - Bonus

1. Commit an eval report.
   - Extend `run-harness.ps1` to emit JSON/Markdown metrics.
   - Track route accuracy, false auto-approval count, duplicate/payment safety results, and adversarial results.
   - Commit the latest report under `reports/`.

2. Build an MCP server for agent tools.
   - Expose tools such as `fetch_policy`, `lookup_vendor`, `check_duplicate`, and `reserve_budget`.
   - Keep hard safety decisions outside the model.

3. Add Kubernetes manifests.
   - Local cluster manifests for Redis, Dapr components, services, gateway, and frontend.
   - Document local deployment and teardown.

## Recommended Next 5 Moves

1. Run compose and `run-core-journeys.ps1` from a clean state.
2. Fix any harness failures before editing optional features.
3. Add payment success handling and payment-service health/structured logs.
4. Add README, `.env.example`, LICENSE, product dilemma doc, and ADRs.
5. Run CI or reproduce its exact commands locally with `LLM_PROVIDER=mock`.

## Fastest Path to a Strong Main Branch

If time is tight, focus on this slice:

1. Green `run-core-journeys.ps1`.
2. Green GitHub Actions CI.
3. Root README plus corrected `ARCHITECTURE.md`.
4. Dapr secrets component or clearly documented local secret path.
5. Payment success/failure final workflow states.
6. ADRs, product dilemma doc, `.env.example`, and LICENSE.
7. Demo recording.
