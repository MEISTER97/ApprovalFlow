import os
import json
from datetime import datetime, timezone
from fastapi import FastAPI, Request
from dapr.clients import DaprClient
import uvicorn

app = FastAPI()
STATE_STORE_NAME = "statestore"


# =========================================================================
# STRUCTURED JSON LOGGER (Requirement M14)
# =========================================================================
def log_structured(correlation_id: str, message: str, level: str = "INFO"):
    log_entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service": "payment-service",
        "level": level,
        "correlationId": correlation_id or "N/A",
        "message": message,
    }
    print(json.dumps(log_entry), flush=True)


# --- HEALTH CHECK ENDPOINT (Requirement M15) ---
@app.get("/healthz")
def healthz():
    return {
        "status": "HEALTHY",
        "service": "payment-service",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/dapr/subscribe")
def subscribe():
    # Listen for approved invoices coming out of C# Workflow Service
    return [
        {
            "pubsubname": "pubsub",
            "topic": "invoice_approved",
            "route": "/process-payment",
        }
    ]


@app.post("/process-payment")
async def process_payment(request: Request):
    body = await request.body()
    event = json.loads(body)
    data = event.get("data", {})

    tracking_id = data.get("Id") or data.get("id", "UNKNOWN")
    correlation_id = (
        data.get("CorrelationId") or data.get("correlationId") or tracking_id
    )
    payload = data.get("Payload") or data.get("payload", {})
    vendor = payload.get("Vendor") or payload.get("vendor", "Unknown")
    total = float(payload.get("Total") or payload.get("total", 0.0))
    invoice_num = (
        payload.get("InvoiceNumber") or payload.get("invoiceNumber", "")
    )

    log_structured(
        correlation_id,
        f"Received payment instruction for {tracking_id} | {vendor} (${total})",
    )

    with DaprClient() as dapr:
        # ---------------------------------------------------------
        # 1. Idempotency Guard (M10): Check if already paid
        # ---------------------------------------------------------
        ledger_key = f"ledger:{tracking_id}"
        try:
            existing_entry = dapr.get_state(
                store_name=STATE_STORE_NAME, key=ledger_key
            )
            if existing_entry.data and existing_entry.data.decode(
                "utf-8"
            ) == "PAID":
                log_structured(
                    correlation_id,
                    f"IDEMPOTENCY HIT: Invoice {tracking_id} was already paid! Halting transfer.",
                    "WARN",
                )
                return {"status": "DUPLICATE_IGNORED"}
        except Exception as e:
            log_structured(
                correlation_id, f"Redis read warning: {e}", "WARN"
            )

        # ---------------------------------------------------------
        # 2. Journey D Simulation (INV-1012 Forced Failure)
        # ---------------------------------------------------------
        # If the invoice is INV-1012 or RackSpace Supplies, simulate forced payment rejection
        if (
            tracking_id == "INV-1012"
            or invoice_num == "RS-90021"
            or vendor.lower() == "rackspace supplies"
        ):
            log_structured(
                correlation_id,
                f"SIMULATING PAYMENT FAILURE (Journey D Triggered for {vendor})",
                "WARN",
            )

            failure_event = {
                "Id": tracking_id,
                "CorrelationId": correlation_id,
                "Reason": "Bank API Error: Insufficient corporate account funds or vendor account frozen.",
            }
            dapr.publish_event(
                pubsub_name="pubsub",
                topic_name="payment_failed",
                data=json.dumps(failure_event),
                data_content_type="application/json",
            )
            log_structured(
                correlation_id,
                "Published payment_failed rollback event to Dapr pub/sub.",
            )
            return {"status": "FAILED"}

        # ---------------------------------------------------------
        # 3. Execute Happy Path Transfer & Save Ledger State
        # ---------------------------------------------------------
        log_structured(
            correlation_id, f"Transferring ${total} to {vendor} bank account..."
        )

        # Durably write PAID record to Redis ledger
        dapr.save_state(
            store_name=STATE_STORE_NAME, key=ledger_key, value="PAID"
        )
        log_structured(
            correlation_id, f"Committed [{ledger_key} = PAID] to Redis Ledger."
        )

        # Publish payment_succeeded completion event
        success_event = {
            "Id": tracking_id,
            "Status": "PAID",
            "Amount": total,
            "CorrelationId": correlation_id,
        }
        dapr.publish_event(
            pubsub_name="pubsub",
            topic_name="payment_succeeded",
            data=json.dumps(success_event),
            data_content_type="application/json",
        )
        log_structured(
            correlation_id,
            "Published payment_succeeded finalization event to Dapr pub/sub.",
        )

    return {"status": "SUCCESS"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)