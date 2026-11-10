$ErrorActionPreference = "Stop"

function Assert-Health([string]$Name, [string]$Url) {
    $response = Invoke-RestMethod -Method Get -Uri $Url
    if ($response.status -notin @("ok", "ready", "success")) {
        throw "$Name returned an unexpected status: $($response.status)"
    }
    Write-Host "[OK] $Name" -ForegroundColor Green
}

Assert-Health "auth-service" "http://localhost:8001/ready"
Assert-Health "course-service" "http://localhost:8002/ready"
Assert-Health "enrollment-service" "http://localhost:8003/ready"
Assert-Health "notification-service" "http://localhost:8004/ready"

$grafana = Invoke-RestMethod -Method Get -Uri "http://localhost:3000/api/health"
if ($grafana.database -ne "ok") {
    throw "Grafana database is not ready"
}
Write-Host "[OK] grafana" -ForegroundColor Green

& "$PSScriptRoot/demo.ps1"

$metrics = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8003/metrics"
if ($metrics.Content -notmatch "lms_http_requests_total") {
    throw "Enrollment metrics are missing"
}
Write-Host "[OK] prometheus metrics endpoint" -ForegroundColor Green

Start-Sleep -Seconds 2
$notificationMetrics = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8004/metrics"
if ($notificationMetrics.Content -notmatch "lms_notification_events_total") {
    throw "Notification event metric is missing"
}
Write-Host "[OK] RabbitMQ consumer metric" -ForegroundColor Green
Write-Host "All smoke checks passed." -ForegroundColor Green
