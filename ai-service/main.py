import os
import json
import time
from fastapi import FastAPI, Request
from dapr.clients import DaprClient
from datetime import datetime
from typing import Optional
import uvicorn

# AI Imports
from pydantic import BaseModel, Field
from typing import List, Literal
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.prompts import ChatPromptTemplate

app = FastAPI(title="ApprovalFlow AI Service")


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


AUTONOMY_CEILING = float(os.getenv("AUTONOMY_CEILING", 250.0))
# Swappable LLM Provider configuration (gemini vs mock) - Requirement M15
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "gemini").lower()
api_key = os.getenv("GEMINI_API_KEY")
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

POLICY_TEXT = ""
try:
    with open("policy.md", "r") as f:
        POLICY_TEXT = f.read()
except FileNotFoundError:
    log_structured(None, "WARNING: policy.md not found in ai-service directory!", "WARN")


@app.get("/dapr/subscribe")
def subscribe():
    return [{"pubsubname": "pubsub", "topic": "invoice_submitted", "route": "/evaluate"}]


# -------------------------------------------------------------------------
# LAYER 1: Pre-LLM Guard (Pure Deterministic Code Gateways)
# -------------------------------------------------------------------------
def run_pre_llm_guard(payload: dict, dup_intercepted: bool) -> tuple[str | None, list[str], str]:
    violations = []

    if dup_intercepted:
        return "duplicate", ["GLOBAL-DUP"], "Duplicate invoice detected: matching combination already processed."

    total = float(payload.get("total") or 0.0)
    currency = payload.get("currency", "USD").upper()
    fx_rate = FX_RATES.get(currency, 1.0)
    total_usd = round(total * fx_rate, 2)

    line_items = payload.get("lineItems") or payload.get("line_items") or []
    tax_amount = float(payload.get("taxAmount") or payload.get("tax_amount") or 0.0)
    receipt_present = payload.get("receiptPresent", True) if payload.get("receiptPresent") is not None else payload.get(
        "receipt_present", True)
    vendor_known = payload.get("vendorKnown", True) if payload.get("vendorKnown") is not None else payload.get(
        "vendor_known", True)

    if line_items:
        calc_subtotal = sum(
            float(item.get("quantity", 1)) * float(item.get("unitPrice", 0.0) or item.get("unit_price", 0.0)) for item
            in line_items)
        if round(calc_subtotal + tax_amount, 2) != round(total, 2):
            return "human_review", [
                "GLOBAL-MATH"], f"Line items subtotal ({calc_subtotal}) + tax ({tax_amount}) != total ({total}). Math does not reconcile."

    if total_usd > 25.0 and not receipt_present:
        violations.append("GLOBAL-RECEIPT")

    if not vendor_known:
        violations.append("GLOBAL-VENDOR")

    if currency != "USD" and (total_usd > 1000.0 or total_usd > AUTONOMY_CEILING):
        violations.append("GLOBAL-FX")

    is_round_number = (total % 100 == 0 or total % 1000 == 0)
    if (is_round_number and not vendor_known) or (not line_items and not vendor_known):
        violations.append("GLOBAL-FRAUD")

    category = str(payload.get("category", "")).lower()
    if category == "travel" and total_usd > 1500.0:
        violations.append("TRAVEL-02")
    if category == "hardware" and total_usd > 1000.0:
        violations.append("HW-02")

    if total_usd > AUTONOMY_CEILING:
        violations.append("AUTONOMY-CEILING")

    if violations:
        return "human_review", violations, f"Deterministic hardstop triggered via policy violations: {', '.join(violations)}."

    return None, [], ""


# -------------------------------------------------------------------------
# LAYER 3: Post-LLM Guard (The Absolute Safety Net)
# -------------------------------------------------------------------------
def run_post_llm_guard(llm_route: str, llm_confidence: float, llm_violations: list[str], total_usd: float) -> tuple[
    str, list[str], str]:
    final_route = llm_route
    final_violations = list(set(llm_violations))
    reason_prefix = "AI evaluation applied successfully."

    if total_usd > AUTONOMY_CEILING and final_route == "auto_approve":
        final_route = "human_review"
        if "AUTONOMY-CEILING" not in final_violations:
            final_violations.append("AUTONOMY-CEILING")
        reason_prefix = f"Post-LLM Safety Override: Auto-approval blocked because USD total (${total_usd}) exceeds ceiling (${AUTONOMY_CEILING})."

    if final_route == "auto_approve" and llm_confidence < 0.80:
        final_route = "human_review"
        if "AUTONOMY-CONFIDENCE" not in final_violations:
            final_violations.append("AUTONOMY-CONFIDENCE")
        reason_prefix = f"Post-LLM Safety Override: Confidence score ({llm_confidence}) is below required 0.80 threshold."

    return final_route, final_violations, reason_prefix


@app.post("/evaluate")
async def evaluate_invoice(request: Request):
    body = await request.body()
    event = json.loads(body)
    data = event.get("data", {})

    tracking_id = data.get("id") or data.get("Id") or "UNKNOWN"
    # Extract end-to-end Correlation ID forwarded by C# Dapr pub/sub
    correlation_id = data.get("CorrelationId") or data.get("correlationId") or request.headers.get("X-Correlation-ID")

    payload = data.get("payload") or data.get("Payload", {})

    total = float(payload.get("total") or payload.get("Total") or 0.0)
    currency = payload.get("currency", "USD").upper()
    vendor = payload.get("vendor", "Unknown")
    invoice_num = payload.get("invoiceNumber") or payload.get("invoice_number") or tracking_id

    fx_rate = FX_RATES.get(currency, 1.0)
    total_usd = round(total * fx_rate, 2)

    log_structured(correlation_id, f"Evaluating {tracking_id} | {vendor} | {total} {currency} (${total_usd} USD)")

    dup_intercepted = False
    dup_key = f"inv:{vendor}:{invoice_num}:{total}"

    with DaprClient() as dapr:
        try:
            state_item = dapr.get_state(store_name=STATE_STORE_NAME, key=dup_key)
            if state_item.data and state_item.data.decode("utf-8") == "PROCESSED":
                dup_intercepted = True
                log_structured(correlation_id, f"Redis Duplicate Caught: {dup_key}", "WARN")
        except Exception as e:
            log_structured(correlation_id, f"Redis read error: {e}", "ERROR")

        # Execute Layer 1: Pre-LLM Guard
        route, violations, reason = run_pre_llm_guard(payload, dup_intercepted)

        # Execute Layer 2: LLM Advisory Layer (Only if Layer 1 passes cleanly)
        if not route:
            if LLM_PROVIDER == "mock" or llm is None:
                log_structured(correlation_id,
                               "Executing swappable deterministic fallback evaluation (LLM_PROVIDER=mock or API key unset).")
                route = "auto_approve" if total_usd <= 150.0 else "human_review"
                violations = []
                reason = f"Deterministic Fallback Evaluation: Expense of ${total_usd} categorized as {route}."
            else:
                log_structured(correlation_id, "Passing to Gemini for policy nuance evaluation...")
                prompt = ChatPromptTemplate.from_messages([
                    ("system",
                     """You are an expert corporate expense auditor enforcing this policy:\n{policy}\n\nEvaluate the invoice payload carefully and classify it into exactly one of these routes:\n- 'auto_approve': Fully compliant, under ceiling, known vendor, receipt attached, valid math.\n- 'human_review': Missing receipts/info, new vendors, ambiguous categories, over caps, or requires manager sign-off.\n- 'reject': Explicitly non-reimbursable items.\n\nNote: All policy dollar thresholds apply to the USD Converted Total. Output strict JSON adhering to the schema."""),
                    ("user",
                     "Category: {category}\nVendor: {vendor} (Known: {vendor_known})\nOriginal Amount: {total} {currency}\nUSD Converted Total: ${total_usd}\nReceipt Present: {receipt_present}\nLine Items: {line_items}\nDescription/Notes: {description}")
                ])

                chain = prompt | llm
                try:
                    ai_decision: AgentDecision = chain.invoke({
                        "policy": POLICY_TEXT,
                        "category": payload.get("category", "other"),
                        "vendor": vendor,
                        "vendor_known": payload.get("vendorKnown", True) if payload.get(
                            "vendorKnown") is not None else payload.get("vendor_known", True),
                        "total": total,
                        "currency": currency,
                        "total_usd": total_usd,
                        "receipt_present": payload.get("receiptPresent", True) if payload.get(
                            "receiptPresent") is not None else payload.get("receipt_present", True),
                        "line_items": str(payload.get("lineItems") or []),
                        "description": payload.get("notes") or payload.get("description") or "No description."
                    })

                    # Execute Layer 3: Post-LLM Guard
                    route, violations, guard_reason = run_post_llm_guard(
                        ai_decision.route,
                        ai_decision.confidence,
                        ai_decision.violations,
                        total_usd
                    )

                    reason = f"{guard_reason} | LLM Rationale: {ai_decision.reason} (Confidence: {ai_decision.confidence})"
                    log_structured(correlation_id, f"Pipeline complete: {route} | Violations: {violations}")

                except Exception as e:
                    # Clean failure fallback matching Requirement M15
                    route = "human_review"
                    violations = ["AI-PROVIDER-ERROR"]
                    reason = f"AI gateway bypassed due to unexpected provider error: {str(e)}"
                    log_structured(correlation_id, reason, "WARN")

        # ---------------------------------------------------------
        # State Management & Event Dissemination
        # ---------------------------------------------------------
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