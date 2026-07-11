import os
import json
import time
from fastapi import FastAPI, Request
from dapr.clients import DaprClient
from datetime import datetime
from typing import Optional
import uvicorn
import re
from otel_tracing import setup_opentelemetry, set_span_correlation_id

# AI Imports
from pydantic import BaseModel, Field
from typing import List, Literal
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.prompts import ChatPromptTemplate

from retriever import policy_retriever

app = FastAPI(title="ApprovalFlow AI Service")
setup_opentelemetry(app, service_name="ai-service")

# =========================================================================
# STRUCTURED JSON LOGGER (Requirement M14)
# =========================================================================
def log_structured(correlation_id: Optional[str], message: str, level: str = "INFO"):
    log_entry = {
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "service": "ai-service",
        "level": level,
        "correlationId": correlation_id or "N/A",
        "message": message
    }
    print(json.dumps(log_entry), flush=True)


# --- HEALTH CHECK ENDPOINT (Requirement M15) ---
@app.get("/healthz")
async def ai_service_health():
    return {
        "status": "HEALTHY",
        "service": "ai-service",
        "timestamp": time.time()
    }


# Helper to fetch config safely from Dapr Secret Store (with env fallback)
def get_dapr_secret(key: str, default: str = None) -> str:
    try:
        with DaprClient() as dapr:
            resp = dapr.get_secret(store_name="secretstore", key=key)
            if resp and resp.secret and key in resp.secret:
                return resp.secret[key]
    except Exception:
        pass  # Fall back to environment variable if Dapr secret is unreachable during init
    return os.getenv(key, default)


AUTONOMY_CEILING = float(get_dapr_secret("AUTONOMY_CEILING", "250.0"))
min_confidence = float(os.getenv("AUTONOMY_CONFIDENCE", "0.80"))
# Swappable LLM Provider configuration (gemini vs mock) - Requirement M15
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "gemini").lower()
api_key = get_dapr_secret("GEMINI_API_KEY")
STATE_STORE_NAME = "statestore"

FX_RATES = {
    "USD": 1.0,
    "EUR": 1.08,
    "GBP": 1.27
}


class AgentDecision(BaseModel):
    route: Literal["auto_approve", "human_review", "reject"] = Field(
        description="Recommended routing decision: 'auto_approve', 'human_review', or 'reject'."
    )
    confidence: float = Field(description="Confidence score between 0.0 and 1.0")
    reason: str = Field(description="Plain-language justification matching corporate policy.")
    violations: List[str] = Field(
        description="List of rule IDs violated or flagged (e.g., 'MEAL-01', 'TRAVEL-02')."
    )


llm = None
if LLM_PROVIDER == "gemini" and api_key:
    llm = ChatGoogleGenerativeAI(
        model="gemini-2.5-flash",
        google_api_key=api_key,
        temperature=0.0
    ).with_structured_output(AgentDecision)


@app.get("/dapr/subscribe")
def subscribe():
    return [{"pubsubname": "pubsub", "topic": "invoice_submitted", "route": "/evaluate"}]


# -------------------------------------------------------------------------
# HELPER: Normalize Payload Keys (camelCase vs PascalCase vs snake_case)
# -------------------------------------------------------------------------
def get_field(payload: dict, *keys, default=None):
    for key in keys:
        if key in payload and payload[key] is not None:
            return payload[key]
    return default


# -------------------------------------------------------------------------
# LAYER 1: Pre-LLM Guard (Dynamic)
# -------------------------------------------------------------------------
def run_pre_llm_guard(payload: dict, dup_intercepted: bool, ceiling: float, saas_limit: float, meal_limit: float) -> tuple[str | None, list[str], str]:
    violations = []

    if dup_intercepted:
        return "duplicate", ["GLOBAL-DUP"], "Duplicate invoice detected: matching combination already processed."

    total = float(get_field(payload, "total", "Total") or 0.0)
    currency = get_field(payload, "currency", "Currency", default="USD").upper()
    fx_rate = FX_RATES.get(currency, 1.0)
    total_usd = round(total * fx_rate, 2)

    line_items = get_field(payload, "lineItems", "LineItems", "line_items", default=[])
    tax_amount = float(get_field(payload, "taxAmount", "TaxAmount", "tax_amount", default=0.0))
    receipt_present = get_field(payload, "receiptPresent", "ReceiptPresent", "receipt_present", default=True)
    vendor_known = get_field(payload, "vendorKnown", "VendorKnown", "vendor_known", default=True)
    attendees = int(get_field(payload, "attendees", "Attendees", default=1))
    notes = str(get_field(payload, "notes", "Notes", "description", "Description", default="")).lower()

    # Math Reconcile Check
    if line_items:
        calc_subtotal = sum(
            float(get_field(item, "quantity", "Quantity", default=1)) *
            float(get_field(item, "unitPrice", "UnitPrice", "unit_price", default=0.0))
            for item in line_items
        )
        if round(calc_subtotal + tax_amount, 2) != round(total, 2):
            return "human_review", ["GLOBAL-MATH"], f"Line items subtotal ({calc_subtotal}) + tax ({tax_amount}) != total ({total}). Math does not reconcile."

    # Global Hard Constraints
    if total_usd > 25.0 and not receipt_present:
        violations.append("GLOBAL-RECEIPT")
    if not vendor_known:
        violations.append("GLOBAL-VENDOR")
    if currency != "USD" and (total_usd > 1000.0 or total_usd > ceiling):
        violations.append("GLOBAL-FX")

    is_round_number = (total % 100 == 0 or total % 1000 == 0)
    if (is_round_number and not vendor_known) or (not line_items and not vendor_known):
        violations.append("GLOBAL-FRAUD")

    category = str(get_field(payload, "category", "Category", default="")).lower()

    # --- CATEGORY SPECIFIC HARDSTOPS (Now Dynamic) ---
    if "alcohol" in notes or "beer" in notes or "wine" in notes or "liquor" in notes or "whiskey" in notes:
        return "reject", ["MEAL-ALCOHOL"], "Explicit rejection: Alcohol-only expenses."

    if category == "meals":
        per_attendee = total_usd / max(attendees, 1)
        if per_attendee > meal_limit or total_usd > 200.0:
            violations.append("MEAL-01")
        if total_usd > 500.0:
            violations.append("MEAL-02")

    if category == "saas" and total_usd > saas_limit:
        violations.append("SAAS-01")

    if category == "travel":
        if total_usd > 1500.0:
            violations.append("TRAVEL-02")
        if "first class" in notes or "business class" in notes:
            violations.append("TRAVEL-03")

    if category == "hardware" and total_usd > 1000.0:
        violations.append("HW-02")

    if total_usd > ceiling:
        violations.append("AUTONOMY-CEILING")

    if violations:
        return "human_review", violations, f"Deterministic hardstop triggered via policy violations: {', '.join(violations)}."

    return None, [], ""

# -------------------------------------------------------------------------
# LAYER 3: Post-LLM Guard (Now Dynamic)
# -------------------------------------------------------------------------
def run_post_llm_guard(llm_route: str, llm_confidence: float, llm_violations: list[str], total_usd: float, ceiling: float) -> tuple[str, list[str], str]:
    final_route = llm_route
    final_violations = list(set(llm_violations))
    reason_prefix = "AI evaluation applied successfully."

    if total_usd > ceiling and final_route == "auto_approve":
        final_route = "human_review"
        if "AUTONOMY-CEILING" not in final_violations:
            final_violations.append("AUTONOMY-CEILING")
        reason_prefix = f"Post-LLM Safety Override: Auto-approval blocked because USD total (${total_usd}) exceeds ceiling (${ceiling})."

    if final_route == "auto_approve" and llm_confidence < min_confidence:
        final_route = "human_review"
        if "AUTONOMY-CONFIDENCE" not in final_violations:
            final_violations.append("AUTONOMY-CONFIDENCE")
        reason_prefix = f"Post-LLM Safety Override: Confidence score ({llm_confidence}) is below required ({min_confidence}) threshold."

    return final_route, final_violations, reason_prefix

@app.post("/evaluate")
async def evaluate_invoice(request: Request):
    body = await request.body()
    event = json.loads(body)
    data = event.get("data", {})

    tracking_id = get_field(data, "id", "Id", default="UNKNOWN")
    correlation_id = get_field(data, "CorrelationId", "correlationId") or request.headers.get("X-Correlation-ID")

    if correlation_id:
        set_span_correlation_id(correlation_id)

    payload = get_field(data, "payload", "Payload", default={})

    total = float(get_field(payload, "total", "Total", default=0.0))
    currency = get_field(payload, "currency", "Currency", default="USD").upper()
    vendor = get_field(payload, "vendor", "Vendor", default="Unknown")
    invoice_num = get_field(payload, "invoiceNumber", "InvoiceNumber", "invoice_number", default=tracking_id)

    fx_rate = FX_RATES.get(currency, 1.0)
    total_usd = round(total * fx_rate, 2)

    log_structured(correlation_id, f"Evaluating {tracking_id} | {vendor} | {total} {currency} (${total_usd} USD)")

    dup_intercepted = False
    dup_key = f"inv:{vendor}:{invoice_num}:{total}"

    # CRITICAL FIX 1: Re-opened the DaprClient connection so 'dapr' is defined
    with DaprClient() as dapr:
        try:
            state_item = dapr.get_state(store_name=STATE_STORE_NAME, key=dup_key)
            if state_item.data and state_item.data.decode("utf-8") == "PROCESSED":
                dup_intercepted = True
                log_structured(correlation_id, f"Redis Duplicate Caught: {dup_key}", "WARN")
        except Exception as e:
            log_structured(correlation_id, f"Redis read error: {e}", "ERROR")

        # ---------------------------------------------------------------------
        # DYNAMIC POLICY EXTRACTION (Stateless Data Engineering)
        # ---------------------------------------------------------------------
        dyn_ceiling = AUTONOMY_CEILING  # Fallbacks from .env
        dyn_saas = 200.0
        dyn_meal = 75.0
        dyn_policy_text = ""

        try:
            policy_state = dapr.get_state(store_name=STATE_STORE_NAME, key="config:policy")
            if policy_state.data:
                dyn_policy_text = policy_state.data.decode("utf-8")

                # Use Regex to extract the numbers the Controller typed in the UI
                c_match = re.search(r'MAX_AUTO_APPROVE:\s*([0-9.]+)', dyn_policy_text)
                if c_match: dyn_ceiling = float(c_match.group(1))

                s_match = re.search(r'SAAS_PER_MONTH:\s*([0-9.]+)', dyn_policy_text)
                if s_match: dyn_saas = float(s_match.group(1))

                m_match = re.search(r'MEALS_PER_HEAD:\s*([0-9.]+)', dyn_policy_text)
                if m_match: dyn_meal = float(m_match.group(1))

                log_structured(correlation_id, f"Loaded dynamic policy from Redis. Ceiling: ${dyn_ceiling}")
        except Exception as e:
            log_structured(correlation_id, f"Redis policy fetch failed, using defaults: {e}", "WARN")

        # Execute Layer 1: Pre-LLM Guard using live variables
        route, violations, reason = run_pre_llm_guard(payload, dup_intercepted, dyn_ceiling, dyn_saas, dyn_meal)

        # Execute Layer 2: LLM Advisory Layer
        if not route:
            if LLM_PROVIDER == "mock" or llm is None:
                log_structured(correlation_id, "Executing swappable deterministic fallback evaluation.")
                route = "auto_approve" if total_usd <= dyn_ceiling else "human_review"
                violations = []
                reason = f"Deterministic Fallback Evaluation: Compliant expense of ${total_usd} categorized as {route}."
            else:
                log_structured(correlation_id, "Passing to Gemini for policy nuance evaluation...")

                invoice_category = get_field(payload, "category", "Category", default="other")
                invoice_desc = get_field(payload, "notes", "Notes", "description", "Description", default="")

                # Fallback to the first line item's description if root notes are missing (Fixes INV-1016)
                if not invoice_desc:
                    lines = get_field(payload, "lineItems", "LineItems", "line_items", default=[])
                    if lines and len(lines) > 0:
                        invoice_desc = get_field(lines[0], "Description", "description",
                                                 default="No description provided")

                retrieved_policy_context = policy_retriever.retrieve(
                    category=invoice_category,
                    query_text=str(invoice_desc)
                )

                # --- COMBINE RAG WITH CONTROLLER OVERRIDES ---
                combined_policy = f"BASE RAG POLICY:\n{retrieved_policy_context}\n\nLIVE CONTROLLER OVERRIDES:\n{dyn_policy_text}"

                # Update the prompt to note that math is already verified to prevent LLM hesitation
                prompt = ChatPromptTemplate.from_messages([
                    ("system",
                     """You are an expert corporate expense auditor enforcing these retrieved policy clauses:\n{policy}\n\nEvaluate the invoice payload carefully and classify it into exactly one of these routes:\n- 'auto_approve': Fully compliant, under ceiling, known vendor, receipt attached, valid math.\n- 'human_review': Missing receipts/info, new vendors, ambiguous categories, over caps, or requires manager sign-off.\n- 'reject': Explicitly non-reimbursable items.\n\nNote: All policy dollar thresholds apply to the USD Converted Total. Output strict JSON adhering to the schema."""),
                    ("user",
                     "Category: {category}\nVendor: {vendor} (Known: {vendor_known})\nOriginal Amount: {total} {currency}\nUSD Converted Total: ${total_usd}\nTax Amount: ${tax_amount} (Math Pre-Verified)\nReceipt Present: {receipt_present}\nLine Items: {line_items}\nDescription/Notes: {description}")
                ])

                chain = prompt | llm
                try:
                    ai_decision: AgentDecision = chain.invoke({
                        "policy": combined_policy,  # <-- PASS THE COMBINED DYNAMIC POLICY
                        "category": invoice_category,
                        "vendor": vendor,
                        "vendor_known": get_field(payload, "vendorKnown", "VendorKnown", "vendor_known", default=True),
                        "total": total,
                        "currency": currency,
                        "total_usd": total_usd,
                        "tax_amount": get_field(payload, "taxAmount", "TaxAmount", "tax_amount", default=0.0),
                        "receipt_present": get_field(payload, "receiptPresent", "ReceiptPresent", "receipt_present",
                                                     default=True),
                        "line_items": str(get_field(payload, "lineItems", "LineItems", "line_items", default=[])),
                        "description": invoice_desc
                    })

                    # Execute Layer 3: Post-LLM Guard using live ceiling
                    route, violations, guard_reason = run_post_llm_guard(
                        ai_decision.route,
                        ai_decision.confidence,
                        ai_decision.violations,
                        total_usd,
                        dyn_ceiling
                    )

                    reason = f"{guard_reason} | LLM Rationale: {ai_decision.reason} (Confidence: {ai_decision.confidence})"
                    log_structured(correlation_id, f"Pipeline complete: {route} | Violations: {violations}")

                # CRITICAL FIX 2: Re-aligned the indentation to properly catch the try block
                except Exception as e:
                    route = "human_review"
                    violations = ["AI-PROVIDER-ERROR"]
                    reason = f"AI gateway bypassed due to unexpected provider error: {str(e)}"
                    log_structured(correlation_id, reason, "WARN")

        # State Management & Event Dissemination
        if route != "duplicate":
            try:
                dapr.save_state(store_name=STATE_STORE_NAME, key=dup_key, value="PROCESSED")
            except Exception as e:
                log_structured(correlation_id, f"Failed to save state to Redis: {e}", "ERROR")

        eval_result = {
            "Id": tracking_id,
            "Route": route,
            "Violations": violations,
            "Reason": reason
        }

        dapr.publish_event(
            pubsub_name="pubsub",
            topic_name="invoice_evaluated",
            data=json.dumps(eval_result),
            data_content_type="application/json"
        )
        log_structured(correlation_id, f"Successfully published {route} matrix upstream.")

    return {"status": "SUCCESS"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)