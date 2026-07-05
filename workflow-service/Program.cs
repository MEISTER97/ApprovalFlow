using Dapr.Client;
using Microsoft.AspNetCore.Mvc;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// Register Dapr Client
builder.Services.AddDaprClient();

// Add CORS policy for Flutter Web / Desktop UI 
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        policy.AllowAnyOrigin()
              .AllowAnyMethod()
              .AllowAnyHeader();
    });
});

var app = builder.Build();
app.UseCors();
app.UseCloudEvents();

// --- HEALTH CHECK ENDPOINT (Requirement M15) ---
app.MapGet("/healthz", () => Results.Ok(new 
{ 
    status = "HEALTHY", 
    service = "workflow-service", 
    timestamp = DateTime.UtcNow 
}));

app.MapSubscribeHandler();

const string StateStoreName = "statestore";

// Initial department budget defaults matching sample-invoices.json section 7
var DefaultBudgets = new Dictionary<string, double>
{
    ["marketing-2026Q2"] = 1000.0,
    ["engineering-2026Q2"] = 50000.0,
    ["sales-2026Q2"] = 20000.0
};

// =========================================================================
// STRUCTURED JSON LOGGER (Requirement M14)
// =========================================================================
void LogStructured(string? correlationId, string message, string level = "INFO")
{
    var logEntry = new
    {
        timestamp = DateTime.UtcNow.ToString("o"),
        service = "workflow-service",
        level = level,
        correlationId = correlationId ?? "N/A",
        message = message
    };
    Console.WriteLine(JsonSerializer.Serialize(logEntry));
}

// =========================================================================
// SAGA HELPER METHODS (Budget Reservation & Compensation)
// =========================================================================

async Task<bool> TryReserveBudgetAsync(DaprClient dapr, string department, double amount, string invoiceId, string? correlationId = null)
{
    string budgetKey = $"budget:{department}";
    var budgetState = await dapr.GetStateEntryAsync<double?>(StateStoreName, budgetKey);
    
    if (budgetState.Value == null)
    {
        budgetState.Value = DefaultBudgets.GetValueOrDefault(department, 10000.0);
    }

    LogStructured(correlationId, $"[Saga Reserve] Checking {budgetKey}: Balance = ${budgetState.Value:F2} | Requested = ${amount:F2}");

    if (budgetState.Value < amount)
    {
        LogStructured(correlationId, $"[Saga Reserve] BLOCKED: Insufficient funds in {department}. Budget cannot fall below $0.", "WARN");
        return false;
    }

    budgetState.Value -= amount;
    await budgetState.SaveAsync();
    LogStructured(correlationId, $"[Saga Reserve] SUCCESS: Reserved ${amount:F2} for {invoiceId}. Remaining Balance = ${budgetState.Value:F2}");
    return true;
}

async Task ReleaseBudgetAsync(DaprClient dapr, string department, double amount, string invoiceId, string? correlationId = null)
{
    string budgetKey = $"budget:{department}";
    var budgetState = await dapr.GetStateEntryAsync<double?>(StateStoreName, budgetKey);
    
    double currentBalance = budgetState.Value ?? DefaultBudgets.GetValueOrDefault(department, 0.0);
    currentBalance += amount;
    
    await dapr.SaveStateAsync(StateStoreName, budgetKey, currentBalance);
    LogStructured(correlationId, $"[Saga Rollback] COMPENSATED: Released ${amount:F2} back to {budgetKey} for {invoiceId}. Restored Balance = ${currentBalance:F2}");
}

const string EscalationIndexKey = "index:escalations";

async Task AddToEscalationQueueAsync(DaprClient dapr, string invoiceId, string? correlationId = null)
{
    var indexEntry = await dapr.GetStateEntryAsync<HashSet<string>>(StateStoreName, EscalationIndexKey);
    indexEntry.Value ??= new HashSet<string>();
    
    if (indexEntry.Value.Add(invoiceId))
    {
        await indexEntry.SaveAsync();
        LogStructured(correlationId, $"[Escalation Registry] Added {invoiceId} to open manager queue.");
    }
}

async Task RemoveFromEscalationQueueAsync(DaprClient dapr, string invoiceId, string? correlationId = null)
{
    var indexEntry = await dapr.GetStateEntryAsync<HashSet<string>>(StateStoreName, EscalationIndexKey);
    if (indexEntry.Value != null && indexEntry.Value.Remove(invoiceId))
    {
        await indexEntry.SaveAsync();
        LogStructured(correlationId, $"[Escalation Registry] Removed {invoiceId} from open manager queue.");
    }
}

const string MetricsKey = "metrics:dashboard";

async Task UpdateMetricsAsync(DaprClient dapr, string actionType, double amount = 0.0)
{
    var entry = await dapr.GetStateEntryAsync<DashboardMetrics>(StateStoreName, MetricsKey);
    var current = entry.Value ?? new DashboardMetrics();

    entry.Value = actionType switch
    {
        "SUBMIT" => current with { TotalSubmissions = current.TotalSubmissions + 1 },
        "AUTO_APPROVE" => current with 
        { 
            AutoApprovedCount = current.AutoApprovedCount + 1, 
            AutoApprovedAmount = current.AutoApprovedAmount + amount 
        },
        "ESCALATE" => current with { EscalatedCount = current.EscalatedCount + 1 },
        "HUMAN_APPROVE" => current with 
        { 
            HumanApprovedCount = current.HumanApprovedCount + 1, 
            HumanApprovedAmount = current.HumanApprovedAmount + amount 
        },
        _ => current
    };

    await entry.SaveAsync();
}

// =========================================================================
// ENDPOINTS
// =========================================================================

// --- ENDPOINT 1: Intake (Asynchronous & Non-blocking) ---
app.MapPost("/api/invoices", async (HttpContext context, [FromBody] InvoiceSubmission payload, DaprClient daprClient) =>
{
    var trackingId = payload.Id ?? Guid.NewGuid().ToString();
    var correlationId = context.Request.Headers["X-Correlation-ID"].FirstOrDefault() ?? Guid.NewGuid().ToString();
    
    var state = new WorkflowState(
        Id: trackingId, 
        Payload: payload, 
        Status: "PENDING", 
        Violations: new List<string>(), 
        Reason: "Awaiting AI/Deterministic Evaluation",
        CorrelationId: correlationId,
        FinalActor: "Pending Evaluation",
        PaymentOutcome: "Not Started"
    );
    
    LogStructured(correlationId, $"Ingested invoice {trackingId} for vendor {payload.Vendor}");

    await daprClient.SaveStateAsync(StateStoreName, trackingId, state);
    await daprClient.PublishEventAsync("pubsub", "invoice_submitted", state);
    await UpdateMetricsAsync(daprClient, "SUBMIT");
    return Results.Accepted(value: new { trackingId, correlationId, status = "PENDING" });
});

// --- ENDPOINT 2: Catch AI / Deterministic Routing Decision ---
app.MapPost("/api/workflow/evaluated", async ([FromBody] EvaluationResult aiResponse, DaprClient daprClient) =>
{
    var currentState = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, aiResponse.Id);
    if (currentState == null)
    {
        LogStructured(null, $"Error: State not found for Invoice {aiResponse.Id}", "ERROR");
        return Results.NotFound();
    }

    string correlationId = currentState.CorrelationId ?? aiResponse.Id;

    string updatedStatus = aiResponse.Route?.ToLower() switch
    {
        "auto_approve" => "APPROVED",
        "human_review" => "PENDING_HUMAN_REVIEW",
        "reject"       => "REJECTED",
        "duplicate"    => "DUPLICATE_DISCARDED",
        _              => "PENDING_HUMAN_REVIEW"
    };

    string actor = updatedStatus switch
    {
        "APPROVED" => "AI Agent (Autonomous)",
        "PENDING_HUMAN_REVIEW" => "Pending HITL Manager Review",
        "REJECTED" => "Deterministic Safety Guard / AI Agent",
        "DUPLICATE_DISCARDED" => "Deterministic Idempotency Guard",
        _ => "System"
    };

    var updatedState = currentState with 
    { 
        Status = updatedStatus,
        Violations = aiResponse.Violations ?? new List<string>(),
        Reason = aiResponse.Reason ?? "No reason provided by evaluator.",
        FinalActor = actor,
        PaymentOutcome = updatedStatus == "APPROVED" ? "Processing Payment Saga" : "N/A (Did Not Approve)"
    };

    if (updatedStatus == "APPROVED")
    {
        string dept = currentState.Payload.Department ?? "engineering-2026Q2";
        double amount = currentState.Payload.Total;

        bool reserved = await TryReserveBudgetAsync(daprClient, dept, amount, aiResponse.Id, correlationId);
        if (reserved)
        {
            updatedState = updatedState with { Status = "BUDGET_RESERVED", PaymentOutcome = "Reserved & Forwarded to Payments" };
            await daprClient.SaveStateAsync(StateStoreName, aiResponse.Id, updatedState);
            
            LogStructured(correlationId, $"RESUMING WORKFLOW: Item {aiResponse.Id} reserved budget. Forwarding to payments.");
            await daprClient.PublishEventAsync("pubsub", "invoice_approved", updatedState);
        }
        else
        {
            updatedState = updatedState with 
            { 
                Status = "REJECTED_INSUFFICIENT_BUDGET",
                Reason = $"Saga Aborted: Department budget '{dept}' has insufficient funds for ${amount:F2}.",
                PaymentOutcome = "Aborted: Insufficient Budget"
            };
            await daprClient.SaveStateAsync(StateStoreName, aiResponse.Id, updatedState);
            LogStructured(correlationId, $"BLOCKED: Insufficient budget for item {aiResponse.Id}.", "WARN");
        }
        await UpdateMetricsAsync(daprClient, "AUTO_APPROVE", amount);
    }
    else if (updatedStatus == "PENDING_HUMAN_REVIEW")
    {
        await daprClient.SaveStateAsync(StateStoreName, aiResponse.Id, updatedState);
        await AddToEscalationQueueAsync(daprClient, aiResponse.Id, correlationId);
        LogStructured(correlationId, $"State committed to Redis & Escalation Queue: [{updatedStatus}]");
        await UpdateMetricsAsync(daprClient, "ESCALATE");
    }
    else
    {
        await daprClient.SaveStateAsync(StateStoreName, aiResponse.Id, updatedState);
        LogStructured(correlationId, $"State committed to Redis: [{updatedStatus}]");
    }

    return Results.Ok();
})
.WithTopic("pubsub", "invoice_evaluated")
.WithName("invoice_evaluated");

// --- ENDPOINT 3: Live Query Poll ---
app.MapGet("/api/invoices/{id}", async (string id, DaprClient daprClient) =>
{
    var state = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, id);
    return state != null ? Results.Ok(state) : Results.NotFound(new { error = "Invoice tracking ID not found." });
});

// --- ENDPOINT 4: Fetch Human Review Queue ---
app.MapGet("/api/escalations", async (DaprClient daprClient) =>
{
    var indexEntry = await daprClient.GetStateEntryAsync<HashSet<string>>(StateStoreName, EscalationIndexKey);
    var pendingIds = indexEntry.Value ?? new HashSet<string>();

    var escalatedItems = new List<WorkflowState>();

    foreach (var id in pendingIds)
    {
        var item = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, id);
        if (item != null && item.Status == "PENDING_HUMAN_REVIEW")
        {
            escalatedItems.Add(item);
        }
    }

    return Results.Ok(new
    {
        totalEscalations = escalatedItems.Count,
        queue = escalatedItems
    });
});

// --- ENDPOINT 5: Human Overrides (Approve / Reject / Send Back Action) ---
app.MapPost("/api/escalations/{id}/action", async (string id, [FromBody] HumanActionRequest request, DaprClient daprClient) =>
{
    var state = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, id);
    if (state == null) return Results.NotFound();
    
    string correlationId = state.CorrelationId ?? id;
    await RemoveFromEscalationQueueAsync(daprClient, id, correlationId);

    if (state.Status != "PENDING_HUMAN_REVIEW" && state.Status != "PENDING_MORE_INFO")
    {
        return Results.BadRequest(new { error = $"Invoice is currently in [{state.Status}] status and cannot be actioned." });
    }

    string actionUpper = request.Action.ToUpper();
    string targetStatus = actionUpper switch
    {
        "APPROVE" => "APPROVED",
        "REJECT"  => "REJECTED",
        "SEND_BACK" or "MORE_INFO" or "REQUEST_INFO" => "PENDING_MORE_INFO",
        _         => "REJECTED"
    };

    string paymentOutcome = targetStatus switch
    {
        "APPROVED" => "Processing Payment Saga",
        "PENDING_MORE_INFO" => "Paused: Awaiting Submitter Clarification",
        _ => "Rejected by Manager"
    };

    var updatedState = state with 
    { 
        Status = targetStatus,
        Reason = $"HITL Manager Action ({actionUpper}): {request.Notes}",
        FinalActor = $"HITL Manager ({actionUpper})",
        PaymentOutcome = paymentOutcome
    };

    if (targetStatus == "APPROVED")
    {
        string dept = state.Payload.Department ?? "engineering-2026Q2";
        double amount = state.Payload.Total;

        bool reserved = await TryReserveBudgetAsync(daprClient, dept, amount, id, correlationId);
        if (reserved)
        {
            updatedState = updatedState with { Status = "BUDGET_RESERVED", PaymentOutcome = "Reserved & Forwarded to Payments" };
            await daprClient.SaveStateAsync(StateStoreName, id, updatedState);
            
            LogStructured(correlationId, $"HITL OVERRIDE: Manager approved {id}. Budget reserved. Sending to payments.");
            await daprClient.PublishEventAsync("pubsub", "invoice_approved", updatedState);
        }
        else
        {
            updatedState = updatedState with 
            { 
                Status = "REJECTED_INSUFFICIENT_BUDGET",
                Reason = $"HITL Approved, but aborted: Department '{dept}' lacks sufficient budget.",
                PaymentOutcome = "Aborted: Insufficient Budget"
            };
            await daprClient.SaveStateAsync(StateStoreName, id, updatedState);
        }
        await UpdateMetricsAsync(daprClient, "HUMAN_APPROVE", amount);
    }
    else if (targetStatus == "PENDING_MORE_INFO")
    {
        await daprClient.SaveStateAsync(StateStoreName, id, updatedState);
        LogStructured(correlationId, $"HITL OVERRIDE: Manager sent item {id} back for more info.");
    }
    else
    {
        await daprClient.SaveStateAsync(StateStoreName, id, updatedState);
        LogStructured(correlationId, $"HITL OVERRIDE: Manager rejected item {id}.");
    }
    
    return Results.Ok(updatedState);
});

// --- ENDPOINT 6: Saga Compensating Transaction (Catch Payment Failure) ---
app.MapPost("/api/workflow/payment-failed", async ([FromBody] PaymentFailureNotification failure, DaprClient daprClient) =>
{
    var currentState = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, failure.Id);
    string correlationId = currentState?.CorrelationId ?? failure.Id;

    LogStructured(correlationId, $"SAGA ROLLBACK TRIGGERED for Invoice {failure.Id}", "WARN");

    if (currentState != null)
    {
        if (currentState.Status == "BUDGET_RESERVED" || currentState.Status == "APPROVED")
        {
            string dept = currentState.Payload.Department ?? "engineering-2026Q2";
            double amount = currentState.Payload.Total;
            await ReleaseBudgetAsync(daprClient, dept, amount, failure.Id, correlationId);
        }

        var compensatedState = currentState with
        {
            Status = "PAYMENT_FAILED",
            Reason = $"Saga Compensating Rollback Executed: {failure.Reason}",
            PaymentOutcome = $"FAILED & COMPENSATED: {failure.Reason}"
        };

        await daprClient.SaveStateAsync(StateStoreName, failure.Id, compensatedState);
        LogStructured(correlationId, $"Saga completed. Status rolled back to [PAYMENT_FAILED] in Redis.");
    }

    return Results.Ok();
})
.WithTopic("pubsub", "payment_failed")
.WithName("payment_failed");

// --- ENDPOINT 7: Auditor Decision Trail (Requirement F9) ---
app.MapGet("/api/audit/{id}", async (string id, DaprClient daprClient) =>
{
    var state = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, id);
    if (state == null) return Results.NotFound(new { error = "Audit trail not found for invoice ID." });

    var auditReport = new
    {
        CorrelationId = state.CorrelationId ?? "N/A",
        TrackingId = state.Id,
        CurrentStatus = state.Status,
        WhoMadeFinalCall = state.FinalActor,
        PaymentOutcome = state.PaymentOutcome,
        RulesApplied = state.Violations,
        AgentReasoning = state.Reason,
        ExtractedData = state.Payload
    };

    return Results.Ok(auditReport);
});

// --- ENDPOINT 8: Controller Dashboard Metrics (Requirement F8) ---
app.MapGet("/api/dashboard/metrics", async (DaprClient daprClient) =>
{
    var entry = await daprClient.GetStateEntryAsync<DashboardMetrics>(StateStoreName, MetricsKey);
    var m = entry.Value ?? new DashboardMetrics();

    double totalProcessed = m.AutoApprovedCount + m.EscalatedCount;
    double autoRate = totalProcessed > 0 ? Math.Round((m.AutoApprovedCount / totalProcessed) * 100, 1) : 0.0;
    double escalationRate = totalProcessed > 0 ? Math.Round((m.EscalatedCount / totalProcessed) * 100, 1) : 0.0;

    return Results.Ok(new
    {
        throughput = new { totalSubmissions = m.TotalSubmissions, totalEvaluated = totalProcessed },
        rates = new { autoApprovalRatePct = autoRate, escalationRatePct = escalationRate },
        financials = new
        {
            autoApprovedDollars = Math.Round(m.AutoApprovedAmount, 2),
            humanApprovedDollars = Math.Round(m.HumanApprovedAmount, 2),
            totalApprovedDollars = Math.Round(m.AutoApprovedAmount + m.HumanApprovedAmount, 2)
        },
        counts = new
        {
            autoApproved = m.AutoApprovedCount,
            humanApproved = m.HumanApprovedCount,
            escalatedToHuman = m.EscalatedCount
        }
    });
});

// --- ENDPOINT 9: Saga Final Completion (Catch Payment Success) ---
app.MapPost("/api/workflow/payment-succeeded", async ([FromBody] PaymentSuccessNotification success, DaprClient daprClient) =>
{
    var currentState = await daprClient.GetStateAsync<WorkflowState>(StateStoreName, success.Id);
    string correlationId = currentState?.CorrelationId ?? success.CorrelationId ?? success.Id;

    LogStructured(correlationId, $"SAGA FINALIZED for Invoice {success.Id}: Payment Successful.");

    if (currentState != null)
    {
        // Idempotency: Ignore if already marked PAID
        if (currentState.Status == "PAID")
        {
            LogStructured(correlationId, $"Idempotency Hit: Invoice {success.Id} is already marked PAID.");
            return Results.Ok();
        }

        var finalizedState = currentState with
        {
            Status = "PAID",
            PaymentOutcome = $"PAID: Successfully transferred ${success.Amount:F2}"
        };

        await daprClient.SaveStateAsync(StateStoreName, success.Id, finalizedState);
        LogStructured(correlationId, $"Workflow finalized. Status updated to [PAID] in Redis.");
    }

    return Results.Ok();
})
.WithTopic("pubsub", "payment_succeeded")
.WithName("payment_succeeded");

app.Run();

// Core Data Structures Aligned with Grading and Plan Schemas
public record LineItem(string Description, int Quantity, double UnitPrice);

public record InvoiceSubmission(
    string? Id, string? Submitter, string? Department, string Vendor, bool? VendorKnown,
    string? InvoiceNumber, string Currency, string? Category, int? Attendees,
    List<LineItem>? LineItems, double? TaxAmount, double Total, bool? ReceiptPresent,
    string? Date, string? Notes, string? Description
);

public record WorkflowState(
    string Id, 
    InvoiceSubmission Payload, 
    string Status, 
    List<string> Violations, 
    string Reason,
    string? CorrelationId = null,
    string? FinalActor = "Pending Evaluation",
    string? PaymentOutcome = "Awaiting Processing"
);
public record EvaluationResult(string Id, string Route, List<string> Violations, string Reason);
public record HumanActionRequest(string Action, string Notes);
public record PaymentFailureNotification(string Id, string Reason);
public record PaymentSuccessNotification(string Id, string Status, double Amount, string? CorrelationId = null);

public record DashboardMetrics(
    int TotalSubmissions = 0,
    int AutoApprovedCount = 0,
    double AutoApprovedAmount = 0.0,
    int HumanApprovedCount = 0,
    double HumanApprovedAmount = 0.0,
    int EscalatedCount = 0
);