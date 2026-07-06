# ApprovalFlow Completion Plan - Part 2

Last updated: 2026-07-06

## Priority 0 - Prove The Must-Haves

1. Run a clean local verification.
   - Start Docker Desktop.
   - Run `docker compose down` if the stack is already running.
   - Run `docker compose up --build -d`.
   - Run `.\reset-state.ps1`.
   - Run `.\run-core-journeys.ps1`.
   - Run `.\run-harness.ps1`.
   - Save the pass/fail output for README/demo notes.

2. Fix any harness failures before adding new features.
   - Check timing issues around Dapr startup and payment finalization.
   - Verify expected statuses now that successful payments can become `PAID`.
   - Confirm `INV-1001`, `INV-1003`, `INV-1007`, and `INV-1012` all pass.
   - Confirm at least two auto-approvals and the adversarial `INV-1013` guard.

3. Clean up README truthfulness.
   - Remove the outer ```markdown fence from `README.md`.
   - Correct any claim that Dapr resiliency equals an outbox pattern.
   - Clarify that RAG is keyword/section retrieval over `policy.md`.
   - Clarify that CD publishes images through GHCR only after CI succeeds.
   - Add the exact local secret setup for `dapr-components/secrets.json`.
   - Add the gateway OpenAPI URL: `http://localhost:8080/docs`.

4. Correct `ARCHITECTURE.md`.
   - Show gateway forwarding to workflow through Dapr service invocation.
   - Show workflow publishing `invoice_submitted`.
   - Add `payment_succeeded` returning to workflow and ending in `PAID`.
   - Correct .NET version from 8 to 10 if you keep net10.0.
   - Add Jaeger/OTel and Dapr secret store/resiliency components.

5. Add required decision docs.
   - Create `docs/PRODUCT-DILEMMA.md` explaining the USD 250 autonomy ceiling and why it is not a "$0 ceiling" dodge.
   - Create ADRs under `docs/adr/`:
     - Router-decides safety posture.
     - Dapr pub/sub/state/service invocation/secrets.
     - Payment saga and compensation.
     - Mock/Gemini provider switch.
     - RAG policy retrieval.

6. Finish Dapr secrets local setup.
   - Add a non-secret template such as `dapr-components/secrets.example.json`.
   - Document copying it to `dapr-components/secrets.json`.
   - Ensure `.gitignore` excludes `dapr-components/secrets.json`.
   - Confirm AI service reads `AUTONOMY_CEILING` and `GEMINI_API_KEY` from Dapr secret store when present.

7. Strengthen idempotency proof.
   - Add processed-event keys per topic:
     - `invoice_submitted`
     - `invoice_evaluated`
     - `invoice_approved`
     - `payment_succeeded`
     - `payment_failed`
   - Add harness retry tests for payment and event replay.
   - Use business payment keys where possible, not only tracking id.

8. Harden budget concurrency.
   - Use Dapr state ETags or a transaction-style compare/update for budget reservation.
   - Make the `INV-1014A/B` race deterministic.
   - Document the reservation and release behavior in architecture docs.

9. Prove durable HITL pause/resume.
   - Add a test step that submits `INV-1003`, confirms it is in the escalation queue, restarts `workflow-service`, then approves it.
   - Confirm the workflow resumes and reaches `PAID` or another documented final state.

10. Keep repo hygiene clean.
   - Do not commit generated `workflow-service/obj` changes.
   - Ensure `.gitignore` excludes `obj`, `bin`, `.venv`, `.dart_tool`, build outputs, `.env`, and `dapr-components/secrets.json`.
   - Keep final evaluated work on `main` before the assignment deadline.

## Priority 1 - Nice-To-Have Polish

1. AuthN/AuthZ roles (N1).
   - Add a self-signed JWT mode at the gateway.
   - Roles: submitter, approver, admin/controller, auditor.
   - Protect submit, escalation actions, dashboard, and audit endpoints.

2. Strengthen CD proof (N2).
   - Verify GHCR image publishing succeeds.
   - Add image names to README.
   - Keep publishing disabled for pull requests.

3. Improve resiliency beyond current N3.
   - Keep Dapr retry/timeout/circuit breaker config.
   - Add an actual outbox if time allows.
   - Add poison-message/dead-letter notes if outbox is skipped.

4. Prove OpenTelemetry (N4).
   - Run a core journey.
   - Open Jaeger at `http://localhost:16686`.
   - Capture one trace that includes gateway, workflow, AI, and payment where possible.
   - Add trace instructions or screenshot reference to README.

5. Improve RAG (N5).
   - Add retrieval logging to audit trail if useful.
   - Include retrieved clause IDs/titles in AI reason or audit output.
   - Keep deterministic gates authoritative.

6. Broaden tests (N6).
   - Add Python unit tests for AI guard functions.
   - Add payment-service unit tests for idempotency/failure events.
   - Add workflow tests for status transitions if feasible.
   - Keep Flutter widget test passing.

## Priority 2 - Bonus

1. B1 eval report.
   - Extend `run-harness.ps1` to write `reports/eval-latest.json` and `reports/eval-latest.md`.
   - Include route accuracy, false auto-approval count, duplicate safety, payment safety, and adversarial safety.
   - Commit a sample report after a passing run.

2. B2 MCP server.
   - Build only if Must-Haves are green.
   - Expose tools such as `fetch_policy`, `lookup_vendor`, `check_duplicate`, and `reserve_budget`.
   - Keep hard safety decisions outside model control.

3. B3 Kubernetes.
   - Add manifests for Redis, Dapr components, services, gateway, frontend, and Jaeger.
   - Add local cluster run instructions.

## Immediate Next Moves

1. Fix README outer fence and architecture mismatch.
2. Add `docs/PRODUCT-DILEMMA.md` and ADRs.
3. Add `dapr-components/secrets.example.json` plus `.gitignore` protection for real secrets.
4. Run clean compose plus `run-core-journeys.ps1`.
5. Resolve any failures and then run `run-harness.ps1`.
