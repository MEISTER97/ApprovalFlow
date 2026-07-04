import os
import json
from fastapi import FastAPI, Request
from dapr.clients import DaprClient
import uvicorn

app = FastAPI()
STATE_STORE_NAME = "statestore"


@app.get("/dapr/subscribe")
def subscribe():
    # Listen for approved invoices coming out of C# Workflow Service
    return [{"pubsubname": "pubsub", "topic": "invoice_approved", "route": "/process-payment"}]


@app.post("/process-payment")
async def process_payment(request: Request):
    body = await request.body()
    event = json.loads(body)
    data = event.get("data", {})

    tracking_id = data.get("Id") or data.get("id")
    payload = data.get("Payload") or data.get("payload", {})
    vendor = payload.get("Vendor") or payload.get("vendor", "Unknown")
    total = float(payload.get("Total") or payload.get("total", 0.0))
    invoice_num = payload.get("InvoiceNumber") or payload.get("invoiceNumber", "")

    print(f"\n[Payment Service] 💳 Received payment instruction for {tracking_id} | {vendor} (${total})")

    with DaprClient() as dapr:
        # ---------------------------------------------------------
        # 1. Idempotency Guard (M10): Check if already paid
        # ---------------------------------------------------------
        ledger_key = f"ledger:{tracking_id}"
        try:
            existing_entry = dapr.get_state(store_name=STATE_STORE_NAME, key=ledger_key)
            if existing_entry.data and existing_entry.data.decode("utf-8") == "PAID":
                print(
                    f"[Payment Service] 🛡️ IDEMPOTENCY HIT: Invoice {tracking_id} was already paid! Halting transfer.")
                return {"status": "DUPLICATE_IGNORED"}
        except Exception as e:
            print(f"[Payment Service] Redis read warning: {e}")

        # ---------------------------------------------------------
        # 2. Journey D Simulation (INV-1012 Forced Failure)
        # ---------------------------------------------------------
        # If the invoice is INV-1012 or RackSpace Supplies, simulate forced payment rejection
        if tracking_id == "INV-1012" or invoice_num == "RS-90021" or vendor.lower() == "rackspace supplies":
            print(f"[Payment Service] 💥 SIMULATING PAYMENT FAILURE (Journey D Triggered for {vendor})[cite: 1]")

            failure_event = {
                "Id": tracking_id,
                "Reason": "Bank API Error: Insufficient corporate account funds or vendor account frozen."
            }
            dapr.publish_event(
                pubsub_name="pubsub",
                topic_name="payment_failed",
                data=json.dumps(failure_event),
                data_content_type="application/json"
            )
            print(f"[Payment Service] Published payment_failed rollback event to Dapr pub/sub.")
            return {"status": "FAILED"}

        # ---------------------------------------------------------
        # 3. Execute Happy Path Transfer & Save Ledger State
        # ---------------------------------------------------------
        print(f"[Payment Service] ✅ Transferring ${total} to {vendor} bank account...")

        # Durably write PAID record to Redis ledger
        dapr.save_state(store_name=STATE_STORE_NAME, key=ledger_key, value="PAID")
        print(f"[Payment Service] 🏛️ Committed [{ledger_key} = PAID] to Redis Ledger.")

        # Optionally publish payment_succeeded completion event
        success_event = {"Id": tracking_id, "Status": "PAID", "Amount": total}
        dapr.publish_event(
            pubsub_name="pubsub",
            topic_name="payment_succeeded",
            data=json.dumps(success_event),
            data_content_type="application/json"
        )

    return {"status": "SUCCESS"}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001)