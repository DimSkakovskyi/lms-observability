$ErrorActionPreference = "Stop"

$apiBase = "http://localhost:8080/api"
$studentName = "student_$(Get-Date -Format 'yyyyMMddHHmmssfff')"
$studentPassword = "student12345"

Write-Host "1/5 Registering $studentName..." -ForegroundColor Cyan
$registerBody = @{ username = $studentName; password = $studentPassword } | ConvertTo-Json
Invoke-RestMethod -Method Post -Uri "$apiBase/auth/register" -ContentType "application/json" -Body $registerBody | Out-Null

Write-Host "2/5 Logging in..." -ForegroundColor Cyan
$loginBody = @{ username = $studentName; password = $studentPassword } | ConvertTo-Json
$login = Invoke-RestMethod -Method Post -Uri "$apiBase/auth/login" -ContentType "application/json" -Body $loginBody
$headers = @{ Authorization = "Bearer $($login.access_token)" }

Write-Host "3/5 Loading courses from course-service..." -ForegroundColor Cyan
$courseResponse = Invoke-RestMethod -Method Get -Uri "$apiBase/courses" -Headers $headers
if ($courseResponse.total -lt 1) {
    throw "The course catalog is empty"
}
$course = $courseResponse.items[0]
Write-Host "    Selected: $($course.title)" -ForegroundColor DarkGray

Write-Host "4/5 Enrolling through enrollment-service and RabbitMQ..." -ForegroundColor Cyan
$enrollmentBody = @{ course_id = $course.id } | ConvertTo-Json
$enrollment = Invoke-RestMethod -Method Post -Uri "$apiBase/enrollments" -Headers $headers -ContentType "application/json" -Body $enrollmentBody

Write-Host "5/5 Updating progress to 25%..." -ForegroundColor Cyan
$progressBody = @{ progress_percent = 25 } | ConvertTo-Json
$updated = Invoke-RestMethod -Method Patch -Uri "$apiBase/enrollments/$($enrollment.id)/progress" -Headers $headers -ContentType "application/json" -Body $progressBody

Write-Host ""
Write-Host "Demo flow completed successfully." -ForegroundColor Green
Write-Host "User:       $studentName"
Write-Host "Course:     $($course.title)"
Write-Host "Enrollment: $($updated.id)"
Write-Host "Progress:   $($updated.progress_percent)%"
Write-Host "Grafana:    http://localhost:3000/d/lms-overview/lms-overview"

