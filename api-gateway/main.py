import os
import uuid
import uvicorn
import time
import httpx
from fastapi import FastAPI, Request, Response, HTTPException
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from fastapi.middleware.cors import CORSMiddleware
from otel_tracing import setup_opentelemetry, set_span_correlation_id

# Initialize rate limiter: Max 60 requests per minute per IP address
limiter = Limiter(key_func=get_remote_address, default_limits=["60/minute"])
app = FastAPI(title="ApprovalFlow API Gateway")
setup_opentelemetry(app, service_name="api-gateway")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows Flutter Web on any local port
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# Internal configuration ports
DAPR_HTTP_PORT = os.getenv("DAPR_HTTP_PORT", "3500")
WORKFLOW_SERVICE_NAME = "workflow-service"

# Timeout configurations for microservices
TIMEOUT_CONFIG = httpx.Timeout(30.0, connect=5.0)


# -------------------------------------------------------------------------
# CORRELATION ID MIDDLEWARE
# -------------------------------------------------------------------------
@app.middleware("http")
async def correlation_id_middleware(request: Request, call_next):
    correlation_id = request.headers.get("X-Correlation-ID")
    if not correlation_id:
        correlation_id = str(uuid.uuid4())

    request.state.correlation_id = correlation_id

    set_span_correlation_id(correlation_id)

    start_time = time.time()
    response: Response = await call_next(request)
    duration = time.time() - start_time

    response.headers["X-Correlation-ID"] = correlation_id
    response.headers["X-Response-Time-Seconds"] = f"{duration:.4f}"

    print(
        f"[Gateway] LOG | CorrelationID: {correlation_id} | Path: {request.url.path} | Status: {response.status_code} | ProcessTime: {duration:.4f}s")
    return response


# -------------------------------------------------------------------------
# REVERSE PROXY / DAPR SERVICE INVOCATION
# -------------------------------------------------------------------------
async def forward_to_service(service_name: str, method: str, path: str, request: Request):
    dapr_url = f"http://localhost:{DAPR_HTTP_PORT}/v1.0/invoke/{service_name}/method/{path}"

    headers = dict(request.headers)
    headers["X-Correlation-ID"] = request.state.correlation_id

    body = await request.body()
    params = dict(request.query_params)

    async with httpx.AsyncClient(timeout=TIMEOUT_CONFIG) as client:
        try:
            res = await client.request(
                method=method,
                url=dapr_url,
                headers=headers,
                params=params,
                content=body
            )
            return Response(content=res.content, status_code=res.status_code, headers=dict(res.headers))

        except httpx.RequestError as exc:
            print(f"[Gateway] ❌ Downstream service error linking to {service_name}: {exc}")
            raise HTTPException(status_code=502, detail=f"Target service unreachable: {str(exc)}")


# -------------------------------------------------------------------------
# GATEWAY ROUTE EXPOSURES
# -------------------------------------------------------------------------
@app.post("/api/invoices")
@limiter.limit("20/minute")
async def submit_invoice(request: Request):
    return await forward_to_service(WORKFLOW_SERVICE_NAME, "POST", "api/invoices", request)


@app.get("/api/invoices/{invoice_id}")
async def get_invoice_status(invoice_id: str, request: Request):
    return await forward_to_service(WORKFLOW_SERVICE_NAME, "GET", f"api/invoices/{invoice_id}", request)


@app.get("/api/escalations")
async def get_human_queue(request: Request):
    return await forward_to_service(WORKFLOW_SERVICE_NAME, "GET", "api/escalations", request)


@app.post("/api/escalations/{invoice_id}/action")
async def handle_human_action(invoice_id: str, request: Request):
    return await forward_to_service(WORKFLOW_SERVICE_NAME, "POST", f"api/escalations/{invoice_id}/action", request)


@app.get("/api/audit/{invoice_id}")
async def get_audit_trail(invoice_id: str, request: Request):
    return await forward_to_service(WORKFLOW_SERVICE_NAME, "GET", f"api/audit/{invoice_id}", request)


@app.get("/healthz")
async def gateway_health():
    return {"status": "HEALTHY", "timestamp": time.time()}

@app.get("/api/dashboard/metrics")
async def get_dashboard_metrics(request: Request):
    return await forward_to_service(WORKFLOW_SERVICE_NAME, "GET", "api/dashboard/metrics", request)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)