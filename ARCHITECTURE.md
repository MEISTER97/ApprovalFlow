# ZioNet ApprovalFlow — System Architecture & Component Boundaries

This document outlines the physical microservice boundaries, event-driven choreography, and saga failure recovery patterns for the ZioNet ApprovalFlow platform.

---

## 1. System Component Boundaries

The platform is designed as a polyglot, event-driven microservice cluster choreographed via **Dapr (Distributed Application Runtime)** and backed by **Redis** for state persistence and message pub/sub.

```mermaid
graph TD
    UI[Flutter Frontend Portal] -->|HTTP POST /api/invoices| GW[API Gateway :8080]
    UI -->|HTTP GET /api/dashboard/metrics| GW
    
    subgraph Dapr Service & Event Mesh
        GW -->|Publishes: invoice_submitted| PS((Dapr Pub/Sub Broker))
        GW -->|Saves State| REDIS[(Redis State Store)]
        
        PS -->|Subscribes| AI[AI Service :8000<br>FastAPI + Gemini 2.5 Flash]
        AI -->|Publishes: invoice_evaluated| PS
        AI <-->|Idempotency Check| REDIS
        
        PS -->|Subscribes| WF[Workflow Service :5001<br>.NET 8 Minimal API Coordinator]
        WF <-->|Reads/Writes Saga Ledger & Queue| REDIS
        
        WF -->|Publishes: invoice_approved| PS
        PS -->|Subscribes| PAY[Payment Service :8001<br>FastAPI Banking Simulator]
        
        PAY -->|Publishes: payment_failed| PS
        PS -->|Triggers Rollback| WF
    end



```

### Microservice Responsibilities

1. **`api-gateway` (FastAPI / Python):** The single external ingress boundary. Enforces rate-limiting (`20 req/min`), validates payload schemas, generates non-blocking tracking IDs (`202 Accepted`), injects `X-Correlation-ID` headers, and exposes consolidated `/docs` OpenAPI endpoints.
2. **`workflow-service` (.NET 8 Minimal API / C#):** The central state machine and saga orchestrator. Manages invoice lifecycle transitions (`PENDING` -> `APPROVED` / `PENDING_HUMAN_REVIEW`), maintains atomic department budget balances in Redis, and manages the Human-in-the-Loop (HITL) escalation index (`index:escalations`).
3. **`ai-service` (FastAPI / Python + LangChain):** Evaluates expense policy compliance. Encapsulates the Google Gemini 2.5 Flash LLM within strict **Layer 1 (Pre-LLM)** and **Layer 3 (Post-LLM)** deterministic Python code guards to guarantee autonomy ceiling enforcement (`$250.00 USD`) regardless of LLM output.
4. **`payment-service` (FastAPI / Python):** Simulates external banking clearinghouses. Consumes approved invoices, executes simulated transaction delays, and broadcasts failure notifications (`payment_failed`) when settlement errors occur.
5. **`frontend` (Flutter / Dart):** Responsive web/desktop UI providing a submission form, real-time status tracker, manager escalation intervention dashboard (Approve/Reject/Send Back), and live executive metrics (Requirement F8).

---

## 2. Core Intake & Evaluation Sequence Diagram

This sequence illustrates the asynchronous intake pipeline and the triple-layer evaluation architecture protecting against LLM hallucination and prompt injection attacks.

```mermaid
sequenceDiagram
    autonumber
    actor Submitter
    participant GW as API Gateway (:8080)
    participant PS as Dapr Pub/Sub Mesh
    participant AI as AI Service (:8000)
    participant WF as Workflow Service (:5001)
    participant RD as Redis State Store

    Submitter->>GW: POST /api/invoices (Invoice Payload)
    GW->>RD: Save initial state: PENDING (Tracking ID)
    GW->>PS: Publish event: invoice_submitted
    GW-->>Submitter: 202 Accepted (Tracking ID & Correlation ID returned immediately)

    PS->>AI: Deliver invoice_submitted event
    AI->>RD: Check Idempotency / Duplicate Hash (inv:vendor:id:total)
    AI->>AI: Execute Layer 1: Pre-LLM Deterministic Guard (Math, Dups, Hardstops)
    
    alt Pre-LLM Guard Passes Cleanly
        AI->>Gemini: Prompt LLM for policy nuance interpretation
        Gemini-->>AI: Return structured AgentDecision (Route, Confidence, Reason)
        AI->>AI: Execute Layer 3: Post-LLM Safety Guard (Ceiling & Confidence Floor Check)
    else Pre-LLM Guard Tripped
        AI->>AI: Short-circuit to HUMAN_REVIEW (Skip LLM inference)
    end

    AI->>PS: Publish event: invoice_evaluated (Route, Violations, Reason)

    PS->>WF: Deliver invoice_evaluated event
    alt Route == AUTO_APPROVE
        WF->>RD: TryReserveBudgetAsync() -> Deduct funds from department ledger
        WF->>PS: Publish event: invoice_approved
    else Route == HUMAN_REVIEW
        WF->>RD: Add invoice ID to Manager Escalation Queue (index:escalations)
        WF->>RD: Update state: PENDING_HUMAN_REVIEW
    end

```

---

## 3. Payment Flow & Compensating Rollback Sequence Diagram (Two-Phase Saga)

To guarantee exact financial consistency without distributed two-phase database locking (2PC), the system implements an event-driven **Two-Phase Saga** with compensating transaction rollbacks.

```mermaid
sequenceDiagram
    autonumber
    participant WF as Workflow Service (Saga Coordinator)
    participant RD as Redis Budget Ledger
    participant PS as Dapr Pub/Sub Mesh
    participant PAY as Payment Service (:8001)

    Note over WF,RD: Phase 1: Saga Forward Action (Budget Reservation)
    WF->>RD: Get state: budget:{department}
    alt Sufficient Funds Available
        WF->>RD: Deduct invoice total & Save state (Atomically reserved)
        WF->>RD: Update invoice state: BUDGET_RESERVED
        WF->>PS: Publish event: invoice_approved
    else Insufficient Department Budget
        WF->>RD: Update invoice state: REJECTED_INSUFFICIENT_BUDGET
        Note over WF: Workflow terminates safely. No funds deducted.
    end

    PS->>PAY: Deliver invoice_approved event
    Note over PAY: Simulate External Banking Settlement Gateway

    alt Payment Clears Successfully
        PAY->>PAY: Finalize transaction logs
    else Payment Settlement Fails (e.g. Banking Error / NSF / INV-1014 Scenario)
        PAY->>PS: Publish event: payment_failed (Id, Failure Reason)
        
        Note over PS,WF: Phase 2: Saga Compensating Action (Rollback Ledger)
        PS->>WF: Deliver payment_failed notification
        WF->>RD: ReleaseBudgetAsync() -> Restore exact deducted amount back to budget:{department}
        WF->>RD: Update invoice state: PAYMENT_FAILED (Audit Trail & Outcome recorded)
    end

```

