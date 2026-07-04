import os
import json
import time
from fastapi import FastAPI, Request
from dapr.clients import DaprClient
import uvicorn

# AI Imports
from pydantic import BaseModel, Field
from typing import List, Literal
from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_core.prompts import ChatPromptTemplate

app = FastAPI()

AUTONOMY_CEILING = float(os.getenv("AUTONOMY_CEILING", 250.0))
api_key = os.getenv("GEMINI_API_KEY")
STATE_STORE_NAME = "statestore"

FX_RATES = {
    "USD": 1.0,
    "EUR": 1.08,
    "GBP": 1.27
}

# Initial seed budgets matching sample-invoices.json
DEFAULT_BUDGETS = {
    "marketing-2026Q2": 1000.0,
    "engineering-2026Q2": 50000.0,
    "sales-2026Q2": 20000.0
}

class AgentDecision(BaseModel):
    route: Literal["auto_approve", "human_review", "reject", "duplicate"] = Field(
        description="Final routing decision: 'auto_approve', 'human_review', 'reject', or 'duplicate'."
    )
    confidence: float = Field(description="Confidence score between 0.0 and 1.0")
    reason: str = Field(description="Plain-language justification matching corporate policy.")
    violations: List[str] = Field(
        description="List of salient rule tags violated or flagged."
    )

llm = ChatGoogleGenerativeAI(
  # model="gemini-2.5-flash",
    model="gemini-2.5-flash-lite",
    google_api_key=api_key,
    temperature=0.0
).with_structured_output(AgentDecision)

POLICY_TEXT = ""
try:
    with open("policy.md", "r") as f:
        POLICY_TEXT = f.read()
except FileNotFoundError:
    print("WARNING: policy.md not found in ai-service directory!")

@app.get("/dapr/subscribe")
def subscribe():
    return [{"pubsubname": "pubsub", "topic": "invoice_submitted", "route": "/evaluate"}]

@app.post("/evaluate")
async def evaluate_invoice(request: Request):
    body = await request.body()
    event = json.loads(body)
    data = event.get("data", {})

    tracking_id = data.get("id") or data.get("Id")
    payload = data.get("payload") or data.get("Payload", {})
    total = float(payload.get("total") or payload.get("Total") or 0.0)
    vendor = payload.get("vendor", "Unknown")
    invoice_num = payload.get("invoiceNumber", tracking_id)
    department = payload.get("department", "engineering-2026Q2")
    description = payload.get("notes") or payload.get("description") or "No description provided."
    receipt_present = payload.get("receiptPresent", True)
    vendor_known = payload.get("vendorKnown", True)
    currency = payload.get("currency", "USD").upper()
    line_items = payload.get("lineItems", [])
    tax_amount = float(payload.get("taxAmount") or 0.0)
    fx_rate = FX_RATES.get(currency, 1.0)
    total_usd = round(total * fx_rate, 2)

    print(f"\n[AI Service] Evaluating {tracking_id} | {vendor} | {total} {currency} (${total_usd} USD)")

    route = None
    violations = []
    reason = ""

    with DaprClient() as dapr:
        # ---------------------------------------------------------
        # 1. Deterministic Redis Check: Idempotency / Duplicates (INV-1007)
        # ---------------------------------------------------------
        dup_key = f"inv:{vendor}:{invoice_num}:{total}"
        try:
            state_item = dapr.get_state(store_name=STATE_STORE_NAME, key=dup_key)
            if state_item.data and state_item.data.decode("utf-8") == "PROCESSED":
                route = "duplicate"
                violations = ["GLOBAL-DUP"]
                reason = f"Duplicate invoice detected: {vendor} invoice {invoice_num} for ${total} has already been processed."
                print(f"[AI Service] 🛡️ Redis Duplicate Intercept: {dup_key}")
        except Exception as e:
            print(f"[AI Service] Redis read error (continuing): {e}")

        # ---------------------------------------------------------
        # 2. Deterministic Math Reconciliation Check (INV-1006)
        # ---------------------------------------------------------
        if not route and line_items:
            calc_subtotal = sum(float(item.get("quantity", 1)) * float(item.get("unitPrice", 0.0)) for item in line_items)
            if round(calc_subtotal + tax_amount, 2) != round(total, 2):
                route = "human_review"
                violations = ["GLOBAL-MATH"]
                reason = f"Line items subtotal ({calc_subtotal}) + tax ({tax_amount}) != total ({total}). Math does not reconcile."
                print(f"[AI Service] ❌ Math Reconciliation Intercept: {route}")

        # ---------------------------------------------------------
        # 3. Deterministic Gate: Hard Autonomy Ceiling Check
        # ---------------------------------------------------------
        if not route and total_usd > AUTONOMY_CEILING:
            route = "human_review"
            violations = ["AUTONOMY-CEILING"]
            if currency != "USD":
                violations.append("GLOBAL-FX")
            reason = f"Hard limit enforced. Converted total ${total_usd} USD ({total} {currency}) exceeds the ${AUTONOMY_CEILING} ceiling."
            print(f"[AI Service] ❌ Hard Ceiling Intercept: {route} | {violations}")

        # ---------------------------------------------------------
        # 4. LLM Evaluation (Only if passed all deterministic gates!)
        # ---------------------------------------------------------
        if not route:
            print("[AI Service] Passing to Gemini for policy evaluation...")
            prompt = ChatPromptTemplate.from_messages([
                ("system", """You are an expert corporate expense auditor enforcing this policy:
{policy}

Evaluate the invoice payload carefully and classify it into exactly one of these routes:
- 'auto_approve': Fully compliant, under ceiling, known vendor, receipt attached, valid math.
- 'human_review': Missing receipts/info, new vendors, ambiguous categories, over caps, or requires manager sign-off.
- 'reject': Explicitly non-reimbursable items (e.g., alcohol-only receipts under MEAL-03).
- 'duplicate': Identical duplicate submission.

Note: All policy dollar thresholds apply to the USD Converted Total. Output strict JSON adhering to the schema."""),
                ("user", "Vendor: {vendor} (Known: {vendor_known})\nOriginal Amount: {total} {currency}\nUSD Converted Total: ${total_usd}\nReceipt Present: {receipt_present}\nDescription: {description}")
            ])

            chain = prompt | llm
            try:
                ai_decision: AgentDecision = chain.invoke({
                    "policy": POLICY_TEXT,
                    "vendor": vendor,
                    "vendor_known": vendor_known,
                    "total": total,
                    "currency": currency,
                    "total_usd": total_usd,
                    "receipt_present": receipt_present,
                    "description": description
                })

                route = ai_decision.route
                violations = ai_decision.violations
                if currency != "USD" and "GLOBAL-FX" not in violations and route != "auto_approve":
                    violations.append("GLOBAL-FX")

                reason = f"{ai_decision.reason} (Confidence: {ai_decision.confidence})"
                print(f"[AI Service] ✅ Agent decided: {route} | Violations: {violations}")

                if route == "auto_approve" and ai_decision.confidence < 0.80:
                    route = "human_review"
                    violations.append("AUTONOMY-CONFIDENCE")
                    reason = f"AI recommended auto_approve, but confidence ({ai_decision.confidence}) was below 0.80 threshold."
                    print(f"[AI Service] ⚠️ Low confidence override -> {route}")

            except Exception as e:
                # Catch 429 Rate Limits gracefully so the workflow doesn't crash
                route = "human_review"
                violations = ["AI-RATE-LIMIT-OR-ERROR"]
                reason = f"AI evaluation bypassed due to API limit or error: {str(e)}"
                print(f"[AI Service] ⚠️ {reason}")

        # ---------------------------------------------------------
        # 5. Save State to Redis if Processed Successfully
        # ---------------------------------------------------------
        if route != "duplicate":
            try:
                # Save invoice key to prevent future duplicate submissions
                dapr.save_state(store_name=STATE_STORE_NAME, key=dup_key, value="PROCESSED")
            except Exception as e:
                print(f"[AI Service] Failed to save state to Redis: {e}")

        # Publish structured result back to Dapr
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
        print(f"[AI Service] Published {route} result to workflow queue.")

    return {"status": "SUCCESS"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)