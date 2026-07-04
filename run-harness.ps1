# ==============================================================================
# ApprovalFlow - Complete 19-Fixture Automated Verification Suite
# ==============================================================================
$GatewayUrl = "http://localhost:8080"
$JsonPath = Join-Path $PSScriptRoot "sample-invoices.json"

if (-not (Test-Path $JsonPath)) {
    Write-Host "❌ Error: sample-invoices.json not found!" -ForegroundColor Red
    exit 1
}

$data = Get-Content $JsonPath -Raw | ConvertFrom-Json
$fixtures = $data.fixtures

Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host " 📦 INGESTING ALL $($fixtures.Count) FIXTURES FROM SAMPLE-INVOICES.JSON" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan

foreach ($item in $fixtures) {
    Write-Host " Submitting [$($item.id)] ($($item.vendor) - `$$($item.total))..." -NoNewline
    $payload = $item | ConvertTo-Json -Depth 10
    try {
        $null = Invoke-RestMethod -Uri "$GatewayUrl/api/invoices" -Method Post -Body $payload -ContentType "application/json"
        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
    # Rate limit safety delay (750ms pacing)
    Start-Sleep -Milliseconds 750
}

Write-Host "`n⏳ Allowing 6 seconds for asynchronous Dapr evaluations to settle..." -ForegroundColor DarkGray
Start-Sleep -Seconds 6

# --- Execute HITL Actions on Stateful Journeys ---
Write-Host "`n⚙️ Executing interactive Saga steps on stateful fixtures..." -ForegroundColor Yellow
$approveAction = @{ Action="APPROVE"; Notes="HITL Automated Suite Signoff" } | ConvertTo-Json
$null = Invoke-RestMethod -Uri "$GatewayUrl/api/escalations/INV-1014A/action" -Method Post -Body $approveAction -ContentType "application/json" -ErrorAction SilentlyContinue
$null = Invoke-RestMethod -Uri "$GatewayUrl/api/escalations/INV-1014B/action" -Method Post -Body $approveAction -ContentType "application/json" -ErrorAction SilentlyContinue
$null = Invoke-RestMethod -Uri "$GatewayUrl/api/escalations/INV-1012/action" -Method Post -Body $approveAction -ContentType "application/json" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# --- Final Verification Matrix ---
Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host " 📋 EVALUATION MATRIX & GRADING REPORT" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan

$Passed = 0
$Failed = 0

foreach ($item in $fixtures) {
    $expectedRoute = $item.expected.route
    
    # Map label routes to our exact internal status states
    $expectedStatus = switch ($expectedRoute) {
        "auto_approve" { "BUDGET_RESERVED" }
        "human_review" { "PENDING_HUMAN_REVIEW" }
        "reject"       { "REJECTED" }
        "duplicate"    { "DUPLICATE_DISCARDED" }
        default        { $expectedRoute }
    }

    # Handle scenario overrides for stateful saga tests
    if ($item.id -eq "INV-1012") { $expectedStatus = "PAYMENT_FAILED" }
    if ($item.id -eq "INV-1014B") { $expectedStatus = "REJECTED_INSUFFICIENT_BUDGET" }

    try {
        $actual = Invoke-RestMethod -Uri "$GatewayUrl/api/invoices/$($item.id)" -Method Get
        $status = $actual.status

        # Treat APPROVED and BUDGET_RESERVED equivalently for auto-approval grading
        if ($status -eq $expectedStatus -or ($expectedStatus -eq "BUDGET_RESERVED" -and $status -eq "APPROVED")) {
            Write-Host " [PASS] $($item.id.PadRight(10)) | Expected: $($expectedStatus.PadRight(28)) | Actual: $status" -ForegroundColor Green
            $Passed++
        } else {
            Write-Host " [FAIL] $($item.id.PadRight(10)) | Expected: $($expectedStatus.PadRight(28)) | Actual: $status" -ForegroundColor Red
            $Failed++
        }
    } catch {
        Write-Host " [FAIL] $($item.id.PadRight(10)) | API Read Error" -ForegroundColor Red
        $Failed++
    }
}

Write-Host "`n====================================================================" -ForegroundColor Cyan
Write-Host " 🏆 SCORECARD: Total: $($fixtures.Count) | Passed: $Passed | Failed: $Failed" -ForegroundColor ($Failed -eq 0 ? "Green" : "Red")
Write-Host "====================================================================" -ForegroundColor Cyan
if ($Failed -gt 0) { exit 1 } else { exit 0 }