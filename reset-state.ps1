# ==============================================================================
# ApprovalFlow - State Reset Utility
# ==============================================================================
Write-Host "🧹 Flushing Redis Dapr State Store..." -ForegroundColor Cyan

try {
    $output = docker compose exec -T redis redis-cli flushall
    if ($output -match "OK") {
        Write-Host "✅ All invoices, ledgers, and budget reservations have been reset!" -ForegroundColor Green
    } else {
        Write-Host "Output: $output"
    }
} catch {
    Write-Host "❌ Failed to clear Redis. Ensure your Docker Compose stack is running (`docker compose up -d`)." -ForegroundColor Red
}