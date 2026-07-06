# ZioNet ApprovalFlow — System Architecture & Component Boundaries

This document defines the physical microservice boundaries, event-driven choreography, AI agent safety guards, and compensating saga recovery patterns for the ZioNet ApprovalFlow platform.

---

## 1. System Component Boundaries & Tech Stack

ApprovalFlow is structured as a polyglot, cloud-native microservice cluster orchestrated via **Dapr (Distributed Application Runtime v1.13)** and backed by **Redis Alpine** for distributed state persistence and pub/sub messaging.

```mermaid
graph TD
    UI[Flutter Frontend Portal] -->|HTTP REST| GW[api-gateway :8080<br>FastAPI + SlowAPI Rate Limiter]
    
    subgraph Synchronous Ingress Mesh
        GW -->|Dapr Service Invocation<br>POST /v1.0/invoke/workflow-service/method/api/invoices| WF[workflow-service :8080<br>.NET 10 Minimal API State Machine]
    end
    
    subgraph Event-Driven Pub/Sub Mesh [Dapr Pub/Sub & State Mesh]
        WF -->|Publishes: invoice_submitted| PS((Dapr Pub/Sub Broker<br>Redis))
        WF <-->|Saves / Reads Ledger| REDIS[(Redis State Store)]
        
        PS -->|Subscribes| AI[ai-service :8000<br>Python 3.11 FastAPI + LangChain]
        AI -->|Publishes: invoice_evaluated| PS
        AI <-->|Duplicate Idempotency Check| REDIS
        
        PS -->|Subscribes| WF
        WF -->|Publishes: invoice_approved| PS
        
        PS -->|Subscribes| PAY[payment-service :8001<br>Python 3.11 FastAPI Banking Ledger]
        PAY <-->|Idempotency Guard| REDIS
        PAY -->|Publishes: payment_failed / payment_succeeded| PS
        PS -->|Triggers Saga Rollback| WF
    end

    subgraph Observability & Infrastructure
        GW -.->|OTLP Spans| JAEGER[Jaeger Tracing UI :16686]
        WF -.->|OTLP Spans| JAEGER
        AI -.->|OTLP Spans| JAEGER
        PAY -.->|OTLP Spans| JAEGER
    end

```

### Microservice Responsibilities

1. **`api-gateway` (FastAPI / Python 3.11):** The single external ingress boundary. Enforces IP-based rate-limiting (`60 req/min` via SlowAPI), injects distributed `X-Correlation-ID` headers, handles CORS for Flutter web clients, and proxies business operations to `workflow-service` via Dapr Service Invocation.
2. **`workflow-service` (ASP.NET Core / .NET 10):** The primary state machine orchestrator. Ingests raw invoices (`202 Accepted`), persists initial state, publishes `invoice_submitted` events, manages departmental budget reservations (`TryReserveBudgetAsync`), and maintains the Human-in-the-Loop (HITL) escalation queue index (`index:escalations`).
3. **`ai-service` (FastAPI / Python 3.11 + LangChain):** The policy compliance evaluation engine. Executes a 3-layer zero-trust evaluation pipeline utilizing local keyword/section Retrieval-Augmented Generation (RAG) over `policy.md` and Google Gemini 2.5 Flash (with a swappable `mock` fallback provider).
4. **`payment-service` (FastAPI / Python 3.11):** Simulates external banking settlement gateways. Consumes approved invoices, enforces strict Redis ledger idempotency checks (`ledger:{id}`), and emits saga failure notifications (`payment_failed`) or success receipts (`payment_succeeded`).
5. **`frontend` (Flutter / Dart):** Responsive UI providing invoice submission forms, real-time status polling, manager escalation dashboards (Approve / Reject / Request More Info), and live audit trail visualizers.

---

## 2. Zero-Trust AI Agent Architecture

To prevent hallucinations, prompt injections, and unauthorized budget overruns, the AI service operates under a **router-decides safety posture**. The LLM acts strictly as an advisor; deterministic Python code gates the entry and exit of every evaluation.

### AI Evaluation Flow Diagram

```mermaid
flowchart TD
    A["Dapr Event: invoice_submitted"] --> B["Normalize Payload & Extract CorrelationId"]
    B --> C["Check Redis State Store for Exact Duplicate Hash"]
    C -->|Duplicate Found| D["Abort: Return route='duplicate'"]
    C -->|Unique Item| E["Layer 1: Pre-LLM Deterministic Guard"]
    
    E -->|Hardstop Violated<br>Math / Alcohol / Over Ceiling| F["Short-Circuit: Return 'human_review' or 'reject'"]
    E -->|Passes Cleanly| G["Policy Retriever (Local RAG)"]
    
    G -->|Chunk & Filter policy.md| H["Retrieve Category-Relevant Policy Clauses"]
    H --> I{"Check LLM_PROVIDER"}
    
    I -->|LLM_PROVIDER=mock| J["Deterministic Mock Fallback Evaluation"]
    I -->|LLM_PROVIDER=gemini| K["LangChain + Gemini 2.5 Flash Structured AgentDecision"]
    
    J --> L["Layer 3: Post-LLM Safety Guard"]
    K --> L
    
    L -->|If USD Total > $250 or Confidence < 0.80| M["Safety Override: Force route='human_review'"]
    L -->|Passes Post-LLM Guard| N["Publish event: invoice_evaluated"]
    M --> N

```

### Detailed Safety Layers

* **Layer 1 — Pre-LLM Guard (Pure Code):** Intercepts submissions before LLM inference. Verifies exact math reconciliation (`LineItems + Tax == Total`), checks for missing receipts on totals over `$25 USD`, verifies known vendors, blocks non-reimbursable categories (e.g., alcohol-only items matching rule `MEAL-ALCOHOL`), and flags round-number fraud signals.
* **Layer 2 — RAG Policy Retriever & Advisory LLM:** `retriever.py` dynamically splits `policy.md` by Markdown headers and extracts clauses matching the invoice category and description keywords. This focused context is fed to Gemini alongside a strict Pydantic JSON schema (`AgentDecision`). If `LLM_PROVIDER=mock` or API keys are missing, the system swaps to a deterministic code path.
* **Layer 3 — Post-LLM Safety Net:** Enforces non-negotiable hard boundaries. If the LLM returns `auto_approve` for an invoice exceeding the `$250.00 USD` autonomy ceiling (`AUTONOMY_CEILING`), or if the AI's confidence score is `< 0.80`, the route is programmatically overridden to `human_review`.

---

## 3. Core End-to-End Choreography Sequence

```mermaid
sequenceDiagram
    autonumber
    actor Submitter
    participant GW as api-gateway (:8080)
    participant WF as workflow-service (:8080)
    participant PS as Dapr Pub/Sub Mesh
    participant AI as ai-service (:8000)
    participant RD as Redis State Store

    Submitter->>GW: POST /api/invoices (Invoice Payload)
    GW->>WF: Dapr Invoke: POST /api/invoices (Forwarded with X-Correlation-ID)
    WF->>RD: Save initial state: PENDING
    WF->>PS: Publish event: invoice_submitted
    WF-->>GW: 202 Accepted (Tracking ID)
    GW-->>Submitter: 202 Accepted

    PS->>AI: Deliver invoice_submitted event
    AI->>RD: Check duplicate ledger hash (inv:vendor:id:total)
    AI->>AI: Execute 3-Layer Evaluation Pipeline (Pre-Guard -> RAG/LLM -> Post-Guard)
    AI->>PS: Publish event: invoice_evaluated (Route, Violations, Reason)

    PS->>WF: Deliver invoice_evaluated event
    alt Route == auto_approve
        WF->>RD: TryReserveBudgetAsync() -> Deduct funds atomically
        WF->>PS: Publish event: invoice_approved
    else Route == human_review
        WF->>RD: Append invoice ID to index:escalations
        WF->>RD: Update state: PENDING_HUMAN_REVIEW
    end

```

---

## 4. Two-Phase Saga Payment & Compensating Rollback

To maintain strict accounting consistency across decoupled containers without distributed locking, the system executes an event-driven **Two-Phase Saga**.

```mermaid
sequenceDiagram
    autonumber
    participant WF as workflow-service (Saga Coordinator)
    participant RD as Redis Budget Ledger
    participant PS as Dapr Pub/Sub Mesh
    participant PAY as payment-service (:8001)

    Note over WF,RD: Phase 1: Forward Action (Budget Reservation)
    WF->>RD: Get current budget state (e.g., budget:Engineering)
    alt Sufficient Funds Available
        WF->>RD: Deduct invoice total & Save budget state
        WF->>RD: Update invoice state: BUDGET_RESERVED
        WF->>PS: Publish event: invoice_approved
    else Insufficient Department Budget
        WF->>RD: Update invoice state: REJECTED_INSUFFICIENT_BUDGET
        Note over WF: Workflow terminates safely. No funds deducted.
    end

    PS->>PAY: Deliver invoice_approved event
    PAY->>RD: Check idempotency ledger (ledger:{tracking_id})
    
    alt Bank Clearing Succeeds
        PAY->>RD: Write ledger state: PAID
        PAY->>PS: Publish event: payment_succeeded
        PS->>WF: Finalize invoice state to PAID
    else Bank Clearing Fails (e.g., INV-1012 Forced Failure Scenario)
        PAY->>PS: Publish event: payment_failed (Id, CorrelationId, Reason)
        
        Note over PS,WF: Phase 2: Compensating Action (Budget Rollback)
        PS->>WF: Deliver payment_failed notification
        WF->>RD: ReleaseBudgetAsync() -> Add exact deducted amount back to departmental budget
        WF->>RD: Update invoice state: PAYMENT_FAILED
    end

```

---

## 5. Data Contracts & Event Schemas

All event payloads broadcast over Dapr Pub/Sub adhere to strict JSON contracts stamped with correlation headers.

### `invoice_submitted` (Published by `workflow-service`)

```json
{
  "Id": "INV-1001",
  "CorrelationId": "12385cbb-8a8c-4cbb-8bff-e9ed3fec80c8",
  "Payload": {
    "InvoiceNumber": "INV-1001",
    "Vendor": "Team Lunch Co",
    "Total": 45.00,
    "Currency": "USD",
    "Category": "meals",
    "ReceiptPresent": true,
    "LineItems": [{"Description": "Lunch buffet", "Quantity": 5, "UnitPrice": 9.00}],
    "Notes": "Engineering sprint planning meal"
  }
}

```

### `invoice_evaluated` (Published by `ai-service`)

```json
{
  "Id": "INV-1001",
  "Route": "auto_approve",
  "Violations": [],
  "Reason": "AI evaluation applied successfully. | LLM Rationale: Compliant meal expense under departmental cap. (Confidence: 0.95)"
}

```

---

## 6. Cloud-Native Reliability & Observability

* **Distributed Tracing (OpenTelemetry / Jaeger):** All services configure `OpenTelemetry` SDKs on boot. Python containers emit HTTP OTLP spans, while ASP.NET Core emits `HttpProtobuf` traces. Every request extracts and stamps `correlation_id` tags across boundaries, rendering end-to-end multi-service waterfall diagrams in Jaeger (`http://localhost:16686`).
* **Declarative Resiliency (`resiliency.yaml`):** The Dapr sidecars mount declarative outbox resiliency rules intercepting network communication. External state and pub/sub calls are automatically wrapped in 15-second timeouts, exponential backoff retries (`maxRetries: 3`), and circuit breakers that trip after 5 consecutive failures to prevent cascading cluster lockups.
* **Secret Management (`secretstore.yaml`):** Sensitive API tokens (`GEMINI_API_KEY`) and dynamic operational boundaries (`AUTONOMY_CEILING`) are injected into runtime components via Dapr secret store lookups, falling back safely to local environment variables during local CI/CD testing.
