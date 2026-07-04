# Ensure the file encoding is read properly
$jsonContent = Get-Content -Path "sample-invoices.json" -Raw | ConvertFrom-Json
$fixtures = $jsonContent.fixtures

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "🚀 STARTING ZIONET FINAL PROJECT EVALUATION HARNESS" -ForegroundColor Cyan
Write-Host "Total Fixtures Loaded: $($fixtures.Count)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

foreach ($fixture in $fixtures) {
    $id = $fixture.id
    $vendor = $fixture.vendor
    $total = $fixture.total
    $currency = $fixture.currency
    $expectedRoute = $fixture.expected.route
    $expectedViolations = $fixture.expected.violations -join ", "

    Write-Host "`n----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "Submitting Fixture: " -NoNewline
    Write-Host "$id" -ForegroundColor Yellow -NoNewline
    Write-Host " | Vendor: $vendor ($total $currency)"
    
    # Color-code expected route for quick scanning
    $routeColor = switch ($expectedRoute) {
        "auto_approve" { "Green" }
        "human_review" { "Yellow" }
        "reject"       { "Red" }
        "duplicate"    { "Magenta" }
        default        { "White" }
    }
    Write-Host "Expected Route:      " -NoNewline
    Write-Host "$expectedRoute" -ForegroundColor $routeColor
    Write-Host "Expected Violations: [$expectedViolations]"

    # Convert the fixture object cleanly back to JSON for the POST body
    $body = $fixture | ConvertTo-Json -Depth 10 -Compress

    try {
        $response = Invoke-RestMethod -Uri "http://localhost:5001/api/invoices" `
            -Method Post `
            -Headers @{"Content-Type"="application/json"} `
            -Body $body

        Write-Host "Status: Queued to Dapr (Tracking ID: $($response.trackingId))" -ForegroundColor Gray
    }
    catch {
        Write-Host "❌ HTTP Request Failed for $id : $_" -ForegroundColor Red
    }

    # Pause 3 seconds between submissions so Dapr and Gemini process sequentially
    Start-Sleep -Seconds 6
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "🏁 HARNESS SUBMISSION COMPLETE!" -ForegroundColor Cyan