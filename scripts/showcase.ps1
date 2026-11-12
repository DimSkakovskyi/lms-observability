#requires -Version 5.1

<#
.SYNOPSIS
Runs automated CourseFlow demonstration scenarios.

.DESCRIPTION
Checks databases, CRUD, JWT authorization, Prometheus metrics, Loki logs,
Tempo traces, and durable RabbitMQ delivery. The script creates timestamped
demo users. The CRUD scenario removes its temporary course automatically, and
the RabbitMQ scenario always restarts notification-service in a finally block.

.PARAMETER Scenario
Selects databases, crud, auth, metrics, logs, traces, rabbitmq, or all.

.PARAMETER Interactive
Pauses between scenarios and before disruptive restart/stop demonstrations.

.PARAMETER OpenBrowser
Opens the relevant Prometheus, Grafana, and RabbitMQ pages.

.EXAMPLE
./scripts/showcase.ps1 -Scenario auth

.EXAMPLE
./scripts/showcase.ps1 -Scenario all -Interactive -OpenBrowser
#>

[CmdletBinding()]
param(
    [ValidateSet("databases", "crud", "auth", "metrics", "logs", "traces", "rabbitmq", "all")]
    [string]$Scenario = "all",

    [switch]$Interactive,

    [switch]$OpenBrowser
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:AuthUrl = "http://localhost:8001"
$script:CourseUrl = "http://localhost:8002"
$script:EnrollmentUrl = "http://localhost:8003"
$script:NotificationUrl = "http://localhost:8004"
$script:PrometheusUrl = "http://localhost:9090"
$script:LokiUrl = "http://localhost:3100"
$script:TempoUrl = "http://localhost:3200"
$script:GrafanaUrl = "http://localhost:3000"
$script:RabbitManagementUrl = "http://localhost:15672"

function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message)

    Write-Host "[STEP] $Message" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)

    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)

    Write-Host "[INFO] $Message" -ForegroundColor DarkGray
}

function Write-Fail {
    param([string]$Message)

    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Wait-ForPresenter {
    param([string]$Message = "Press Enter to continue")

    if ($Interactive) {
        [void](Read-Host $Message)
    }
}

function Open-DemoUrl {
    param([string]$Url)

    if ($OpenBrowser) {
        Write-Info "Opening $Url"
        Start-Process $Url
    }
}

function Read-DotEnv {
    param([string]$Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }

        $name = $parts[0].Trim()
        $value = $parts[1].Trim()
        if ($value.Length -ge 2) {
            $doubleQuoted = $value.StartsWith('"') -and $value.EndsWith('"')
            $singleQuoted = $value.StartsWith("'") -and $value.EndsWith("'")
            if ($doubleQuoted -or $singleQuoted) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$name] = $value
    }

    return $values
}

$script:DotEnv = Read-DotEnv -Path (Join-Path $script:ProjectRoot ".env")

function Get-ConfigValue {
    param(
        [string]$Name,
        [string]$DefaultValue
    )

    $environmentValue = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
        return $environmentValue
    }

    if ($script:DotEnv.ContainsKey($Name)) {
        return [string]$script:DotEnv[$Name]
    }

    return $DefaultValue
}

$script:AdminUsername = Get-ConfigValue -Name "ADMIN_USERNAME" -DefaultValue "admin"
$script:AdminPassword = Get-ConfigValue -Name "ADMIN_PASSWORD" -DefaultValue "admin12345"
$script:PostgresUser = Get-ConfigValue -Name "POSTGRES_USER" -DefaultValue "lms"
$script:RabbitUsername = Get-ConfigValue -Name "RABBITMQ_USER" -DefaultValue "lms"
$script:RabbitPassword = Get-ConfigValue -Name "RABBITMQ_PASSWORD" -DefaultValue "lms_password"

function Invoke-DockerCommand {
    param([string[]]$DockerArguments)

    # Docker Compose writes normal progress messages (Creating, Restarting,
    # Started) to stderr. With ErrorActionPreference=Stop, PowerShell 5.1 can
    # incorrectly turn those lines into terminating NativeCommandError records.
    # Temporarily allow stderr, then decide success only from the process exit
    # code.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& docker @DockerArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
        throw "Docker command failed (exit $exitCode): docker $($DockerArguments -join ' ')`n$details"
    }

    return $output
}

function Test-DockerCommand {
    param([string[]]$DockerArguments)

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & docker @DockerArguments *> $null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return $exitCode -eq 0
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [string]$Description,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if (& $Condition) {
                return
            }
        }
        catch {
            # The dependency can fail while a container is restarting.
        }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Description"
}

function Wait-ForHttp {
    param(
        [string]$Uri,
        [string]$Description,
        [int]$TimeoutSeconds = 60
    )

    Wait-Until -Description $Description -TimeoutSeconds $TimeoutSeconds -Condition {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 5
            return [int]$response.StatusCode -lt 500
        }
        catch {
            return $false
        }
    }
}

function Invoke-JsonApi {
    param(
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method = "GET",
        [string]$Uri,
        [hashtable]$Headers,
        $Body
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
    }
    if ($Headers) {
        $parameters.Headers = $Headers
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = if ($Body -is [string]) {
            $Body
        }
        else {
            $Body | ConvertTo-Json -Depth 10
        }
    }

    return Invoke-RestMethod @parameters
}

function Get-HttpStatus {
    param(
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method = "GET",
        [string]$Uri,
        [hashtable]$Headers,
        $Body
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        UseBasicParsing = $true
        ErrorAction = "Stop"
    }
    if ($Headers) {
        $parameters.Headers = $Headers
    }
    if ($null -ne $Body) {
        $parameters.ContentType = "application/json"
        $parameters.Body = if ($Body -is [string]) {
            $Body
        }
        else {
            $Body | ConvertTo-Json -Depth 10
        }
    }

    try {
        $response = Invoke-WebRequest @parameters
        return [int]$response.StatusCode
    }
    catch {
        if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
            return [int]$_.Exception.Response.StatusCode
        }
        throw
    }
}

function Assert-Value {
    param(
        $Actual,
        $Expected,
        [string]$Description
    )

    if ($Actual -ne $Expected) {
        throw "$Description. Expected '$Expected', got '$Actual'."
    }

    Write-Pass "${Description}: $Expected"
}

function Get-AdminSession {
    $login = Invoke-JsonApi -Method POST -Uri "$script:AuthUrl/api/v1/auth/login" -Body @{
        username = $script:AdminUsername
        password = $script:AdminPassword
    }

    return [pscustomobject]@{
        Login = $login
        Headers = @{ Authorization = "Bearer $($login.access_token)" }
    }
}

function New-DemoStudent {
    $suffix = "$(Get-Date -Format 'yyyyMMddHHmmssfff')_$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $username = "showcase_$suffix"
    $password = "student12345"
    $body = @{
        username = $username
        password = $password
    }

    $registered = Invoke-JsonApi -Method POST -Uri "$script:AuthUrl/api/v1/auth/register" -Body $body
    $login = Invoke-JsonApi -Method POST -Uri "$script:AuthUrl/api/v1/auth/login" -Body $body

    return [pscustomobject]@{
        Username = $username
        Password = $password
        User = $registered
        Login = $login
        Headers = @{ Authorization = "Bearer $($login.access_token)" }
    }
}

function Invoke-DemoEnrollmentFlow {
    param([switch]$SkipProgress)

    $student = New-DemoStudent
    $catalog = Invoke-JsonApi -Uri "$script:CourseUrl/api/v1/courses" -Headers $student.Headers
    if ([int]$catalog.total -lt 1) {
        throw "The course catalog is empty."
    }

    $course = $catalog.items[0]
    $enrollment = Invoke-JsonApi -Method POST -Uri "$script:EnrollmentUrl/api/v1/enrollments" -Headers $student.Headers -Body @{
        course_id = $course.id
    }

    if (-not $SkipProgress) {
        $enrollment = Invoke-JsonApi -Method PATCH -Uri "$script:EnrollmentUrl/api/v1/enrollments/$($enrollment.id)/progress" -Headers $student.Headers -Body @{
            progress_percent = 25
        }
    }

    return [pscustomobject]@{
        Student = $student
        Course = $course
        Enrollment = $enrollment
    }
}

function Assert-Preflight {
    Write-Step "Checking Docker Compose and running services"

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker CLI was not found. Start Docker Desktop and try again."
    }

    Invoke-DockerCommand -DockerArguments @("compose", "version") | Out-Null

    $requiredServices = @(
        "course-db",
        "enrollment-db",
        "rabbitmq",
        "auth-service",
        "course-service",
        "enrollment-service",
        "notification-service",
        "frontend",
        "prometheus",
        "loki",
        "tempo",
        "otel-collector",
        "alloy",
        "grafana"
    )
    $runningServices = @(Invoke-DockerCommand -DockerArguments @("compose", "ps", "--services"))
    $missing = @($requiredServices | Where-Object { $_ -notin $runningServices })
    if ($missing.Count -gt 0) {
        throw "These services are not running: $($missing -join ', '). Run: docker compose up --build -d"
    }

    Wait-ForHttp -Uri "$script:AuthUrl/ready" -Description "auth-service"
    Wait-ForHttp -Uri "$script:CourseUrl/ready" -Description "course-service"
    Wait-ForHttp -Uri "$script:EnrollmentUrl/ready" -Description "enrollment-service"
    Wait-ForHttp -Uri "$script:NotificationUrl/ready" -Description "notification-service"
    Write-Pass "All required services are running"
}

function Invoke-DatabaseShowcase {
    Write-Section "DATABASES: PostgreSQL, SQLite, and persistent volumes"

    Write-Step "Checking both PostgreSQL databases"
    $courseReady = (Invoke-DockerCommand -DockerArguments @(
        "compose", "exec", "-T", "course-db",
        "pg_isready", "-U", $script:PostgresUser, "-d", "course_db"
    )) -join "`n"
    $enrollmentReady = (Invoke-DockerCommand -DockerArguments @(
        "compose", "exec", "-T", "enrollment-db",
        "pg_isready", "-U", $script:PostgresUser, "-d", "enrollment_db"
    )) -join "`n"
    Write-Info $courseReady.Trim()
    Write-Info $enrollmentReady.Trim()
    Write-Pass "Both PostgreSQL databases accept connections"

    Write-Step "Reading data directly from the databases"
    $courseCount = ((Invoke-DockerCommand -DockerArguments @(
        "compose", "exec", "-T", "course-db", "psql",
        "-U", $script:PostgresUser, "-d", "course_db", "-tAc", "SELECT COUNT(*) FROM courses;"
    )) -join "").Trim()
    $enrollmentCount = ((Invoke-DockerCommand -DockerArguments @(
        "compose", "exec", "-T", "enrollment-db", "psql",
        "-U", $script:PostgresUser, "-d", "enrollment_db", "-tAc", "SELECT COUNT(*) FROM enrollments;"
    )) -join "").Trim()
    $userCount = ((Invoke-DockerCommand -DockerArguments @(
        "compose", "exec", "-T", "auth-service", "python", "-c",
        "import sqlite3; db=sqlite3.connect('/app/data/auth.db'); print(db.execute('SELECT COUNT(*) FROM users').fetchone()[0])"
    )) -join "").Trim()

    Write-Info "Courses in PostgreSQL: $courseCount"
    Write-Info "Enrollments in PostgreSQL: $enrollmentCount"
    Write-Info "Users in SQLite: $userCount"
    if ([int]$courseCount -lt 1) {
        throw "No seeded courses were found."
    }
    Write-Pass "Application data is available in all three databases"

    Write-Step "Checking Docker volumes"
    $volumes = @(Invoke-DockerCommand -DockerArguments @(
        "volume", "ls",
        "--filter", "label=com.docker.compose.project=lms-observability",
        "--format", "{{.Name}}"
    ))
    if (-not ($volumes | Where-Object { "$_" -like "*course-db-data*" })) {
        throw "The course database volume was not found."
    }
    Write-Info ($volumes -join ", ")
    Write-Pass "Persistent Docker volumes are present"

    Wait-ForPresenter "Press Enter to restart course-db and prove persistence"

    Write-Step "Restarting course-db"
    Invoke-DockerCommand -DockerArguments @("compose", "restart", "course-db") | ForEach-Object {
        Write-Info "$_"
    }
    Wait-Until -Description "course-db readiness" -TimeoutSeconds 60 -Condition {
        Test-DockerCommand -DockerArguments @(
            "compose", "exec", "-T", "course-db",
            "pg_isready", "-U", $script:PostgresUser, "-d", "course_db"
        )
    }
    Wait-ForHttp -Uri "$script:CourseUrl/ready" -Description "course-service after database restart"

    $courseCountAfter = ((Invoke-DockerCommand -DockerArguments @(
        "compose", "exec", "-T", "course-db", "psql",
        "-U", $script:PostgresUser, "-d", "course_db", "-tAc", "SELECT COUNT(*) FROM courses;"
    )) -join "").Trim()
    Assert-Value -Actual $courseCountAfter -Expected $courseCount -Description "Course count survived the database restart"
}

function Invoke-CrudShowcase {
    Write-Section "CRUD: programmatic course updates"

    $admin = Get-AdminSession
    $slug = "showcase-course-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
    $created = $null

    try {
        Write-Step "Creating a course through the admin API"
        $created = Invoke-JsonApi -Method POST -Uri "$script:CourseUrl/api/v1/courses" -Headers $admin.Headers -Body @{
            slug = $slug
            title = "Automated showcase course"
            description = "A temporary course created by the automated showcase."
            instructor = "Demo Instructor"
            duration_hours = 8
            published = $true
        }
        Write-Info "Created course id=$($created.id), slug=$($created.slug)"
        Write-Pass "Course was created"

        Write-Step "Reading the created course"
        $loaded = Invoke-JsonApi -Uri "$script:CourseUrl/api/v1/courses/$($created.id)" -Headers $admin.Headers
        Assert-Value -Actual $loaded.slug -Expected $slug -Description "Created course can be read"

        Write-Step "Updating the course"
        $updated = Invoke-JsonApi -Method PATCH -Uri "$script:CourseUrl/api/v1/courses/$($created.id)" -Headers $admin.Headers -Body @{
            title = "Automated showcase course - updated"
            duration_hours = 12
        }
        Assert-Value -Actual ([double]$updated.duration_hours) -Expected ([double]12) -Description "Course duration was updated"
        Write-Info "Updated title: $($updated.title)"

        Write-Step "Checking the row in PostgreSQL"
        $databaseRow = (Invoke-DockerCommand -DockerArguments @(
            "compose", "exec", "-T", "course-db", "psql",
            "-U", $script:PostgresUser, "-d", "course_db", "-tAc",
            "SELECT slug || ' | ' || title || ' | ' || duration_hours FROM courses WHERE id = $($created.id);"
        )) -join ""
        if ($databaseRow -notmatch [regex]::Escape($slug)) {
            throw "The created course was not found in PostgreSQL."
        }
        Write-Info $databaseRow.Trim()
        Write-Pass "API changes are stored in PostgreSQL"
    }
    finally {
        if ($null -ne $created) {
            Write-Step "Deleting the temporary course"
            try {
                Invoke-JsonApi -Method DELETE -Uri "$script:CourseUrl/api/v1/courses/$($created.id)" -Headers $admin.Headers | Out-Null
                $status = Get-HttpStatus -Uri "$script:CourseUrl/api/v1/courses/$($created.id)" -Headers $admin.Headers
                Assert-Value -Actual $status -Expected 404 -Description "Deleted course is no longer available"
            }
            catch {
                Write-Fail "Temporary course cleanup failed: $($_.Exception.Message)"
                throw
            }
        }
    }
}

function Invoke-AuthShowcase {
    Write-Section "AUTH: JWT, roles, HTTP 401, and HTTP 403"

    Write-Step "Checking access without a token"
    $anonymousStatus = Get-HttpStatus -Uri "$script:CourseUrl/api/v1/courses"
    Assert-Value -Actual $anonymousStatus -Expected 401 -Description "Anonymous course request is rejected"

    Write-Step "Checking invalid credentials"
    $invalidStatus = Get-HttpStatus -Method POST -Uri "$script:AuthUrl/api/v1/auth/login" -Body @{
        username = $script:AdminUsername
        password = "incorrect-password"
    }
    Assert-Value -Actual $invalidStatus -Expected 401 -Description "Invalid password is rejected"

    Write-Step "Registering and logging in a student"
    $student = New-DemoStudent
    $me = Invoke-JsonApi -Uri "$script:AuthUrl/api/v1/auth/me" -Headers $student.Headers
    Assert-Value -Actual $me.role -Expected "student" -Description "New user receives the student role"
    Assert-Value -Actual ([int]$student.Login.expires_in) -Expected 3600 -Description "JWT lifetime in seconds"
    Write-Info "Student: $($student.Username)"

    Write-Step "Trying to create a course as a student"
    $forbiddenStatus = Get-HttpStatus -Method POST -Uri "$script:CourseUrl/api/v1/courses" -Headers $student.Headers -Body @{
        slug = "forbidden-$(Get-Date -Format 'yyyyMMddHHmmssfff')"
        title = "Student cannot create this course"
        description = "This valid payload must be rejected by role-based access control."
        instructor = "Student"
        duration_hours = 5
        published = $true
    }
    Assert-Value -Actual $forbiddenStatus -Expected 403 -Description "Student admin action is forbidden"

    Write-Step "Checking the administrator role"
    $admin = Get-AdminSession
    $adminMe = Invoke-JsonApi -Uri "$script:AuthUrl/api/v1/auth/me" -Headers $admin.Headers
    Assert-Value -Actual $adminMe.role -Expected "admin" -Description "Default administrator has the admin role"
}

function Get-PrometheusValue {
    param([string]$Expression)

    $query = [uri]::EscapeDataString($Expression)
    $response = Invoke-RestMethod -Uri "$script:PrometheusUrl/api/v1/query?query=$query"
    if ($response.status -ne "success" -or @($response.data.result).Count -lt 1) {
        throw "Prometheus returned no data for: $Expression"
    }

    return [double]$response.data.result[0].value[1]
}

function Invoke-MetricsShowcase {
    Write-Section "METRICS: Prometheus collection and time-series persistence"

    $admin = Get-AdminSession
    Write-Step "Generating HTTP traffic"
    1..12 | ForEach-Object {
        Invoke-JsonApi -Uri "$script:CourseUrl/api/v1/courses" -Headers $admin.Headers | Out-Null
    }
    Start-Sleep -Seconds 6
    Write-Pass "HTTP traffic was generated"

    Write-Step "Checking service metric endpoints"
    $metricEndpoints = [ordered]@{
        "auth-service" = "$script:AuthUrl/metrics"
        "course-service" = "$script:CourseUrl/metrics"
        "enrollment-service" = "$script:EnrollmentUrl/metrics"
        "notification-service" = "$script:NotificationUrl/metrics"
    }
    foreach ($entry in $metricEndpoints.GetEnumerator()) {
        $content = (Invoke-WebRequest -UseBasicParsing -Uri $entry.Value).Content
        if ($content -notmatch "lms_http_requests_total") {
            throw "$($entry.Key) does not expose lms_http_requests_total."
        }
        Write-Pass "$($entry.Key) exposes Prometheus metrics"
    }

    Write-Step "Checking Prometheus scrape targets"
    $targets = (Invoke-RestMethod -Uri "$script:PrometheusUrl/api/v1/targets").data.activeTargets
    $expectedJobs = @("auth-service", "course-service", "enrollment-service", "notification-service", "prometheus")
    foreach ($job in $expectedJobs) {
        $target = @($targets | Where-Object { $_.labels.job -eq $job }) | Select-Object -First 1
        if ($null -eq $target) {
            throw "Prometheus target '$job' was not found."
        }
        Assert-Value -Actual $target.health -Expected "up" -Description "Prometheus target $job"
    }

    $query = [uri]::EscapeDataString("sum by (service) (lms_http_requests_total)")
    $requestTotals = Invoke-RestMethod -Uri "$script:PrometheusUrl/api/v1/query?query=$query"
    foreach ($item in $requestTotals.data.result) {
        Write-Info "$($item.metric.service): $($item.value[1]) requests"
    }

    Write-Step "Checking 24-hour retention configuration"
    $composeConfig = (Invoke-DockerCommand -DockerArguments @("compose", "config")) -join "`n"
    if ($composeConfig -notmatch "storage\.tsdb\.retention\.time=24h") {
        throw "Prometheus 24-hour retention is not configured."
    }
    Write-Pass "Prometheus retention is configured for 24 hours"

    Write-Step "Restarting Prometheus to prove TSDB persistence"
    $beforeRestart = Get-PrometheusValue -Expression "sum(lms_http_requests_total)"
    Invoke-DockerCommand -DockerArguments @("compose", "restart", "prometheus") | ForEach-Object {
        Write-Info "$_"
    }
    Wait-ForHttp -Uri "$script:PrometheusUrl/-/ready" -Description "Prometheus after restart" -TimeoutSeconds 60
    Start-Sleep -Seconds 3
    $afterRestart = Get-PrometheusValue -Expression "sum(lms_http_requests_total)"
    if ($afterRestart -lt $beforeRestart) {
        throw "Prometheus metric history decreased after restart ($beforeRestart -> $afterRestart)."
    }
    Write-Pass "Prometheus data survived restart ($beforeRestart -> $afterRestart)"

    Open-DemoUrl "$script:PrometheusUrl/targets"
    Open-DemoUrl "$script:GrafanaUrl/d/lms-overview/lms-overview"
}

function Invoke-LogsShowcase {
    Write-Section "LOGS: JSON stdout, Grafana Alloy, and Loki"

    Write-Step "Generating a traced course request"
    $admin = Get-AdminSession
    Invoke-JsonApi -Uri "$script:CourseUrl/api/v1/courses" -Headers $admin.Headers | Out-Null
    Start-Sleep -Seconds 2

    $dockerLogs = @(Invoke-DockerCommand -DockerArguments @(
        "compose", "logs", "--since", "2m", "--no-log-prefix", "course-service"
    ))
    $requestLog = $dockerLogs | Where-Object { "$_" -match '"message"\s*:\s*"request_completed"' } | Select-Object -Last 1
    if (-not $requestLog) {
        throw "No structured request_completed log was found in course-service output."
    }
    Write-Info "$requestLog"
    Write-Pass "Course service writes structured JSON logs"

    Write-Step "Waiting for Grafana Alloy to send the log to Loki"
    $encodedQuery = [uri]::EscapeDataString('{service="course-service"} |= "request_completed"')
    $lokiResult = $null
    $deadline = (Get-Date).AddSeconds(45)
    do {
        try {
            $endNanoseconds = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) * 1000000
            $startNanoseconds = [int64]([DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()) * 1000000
            $uri = "$script:LokiUrl/loki/api/v1/query_range?query=$encodedQuery&start=$startNanoseconds&end=$endNanoseconds&limit=50&direction=BACKWARD"
            $candidate = Invoke-RestMethod -Uri $uri
            if ($candidate.status -eq "success" -and @($candidate.data.result).Count -gt 0) {
                $lokiResult = $candidate
                break
            }
        }
        catch {
            # Alloy and Loki can need a few seconds after the request.
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if ($null -eq $lokiResult) {
        throw "The generated course-service log was not found in Loki."
    }
    Write-Pass "Loki returned $(@($lokiResult.data.result).Count) matching log stream(s)"
    Write-Info 'Grafana LogQL: {service="course-service"} |= "request_completed"'

    Open-DemoUrl "$script:GrafanaUrl/explore"
}

function Find-EnrollmentTraceId {
    param(
        [string]$EnrollmentId,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $lines = @(Invoke-DockerCommand -DockerArguments @(
            "compose", "logs", "--since", "5m", "--no-log-prefix", "enrollment-service"
        ))
        foreach ($line in $lines) {
            try {
                $record = "$line" | ConvertFrom-Json
                if ($record.message -eq "student_enrolled" -and $record.enrollment_id -eq $EnrollmentId -and $record.trace_id) {
                    return [string]$record.trace_id
                }
            }
            catch {
                # Ignore non-JSON container output.
            }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Could not find a trace_id for enrollment $EnrollmentId in the service logs."
}

function Invoke-TracesShowcase {
    Write-Section "TRACES: OpenTelemetry, Tempo, HTTP, and RabbitMQ spans"

    Write-Step "Running the complete enrollment flow"
    $flow = Invoke-DemoEnrollmentFlow
    Write-Info "Student: $($flow.Student.Username)"
    Write-Info "Course: $($flow.Course.title)"
    Write-Info "Enrollment: $($flow.Enrollment.id)"
    Write-Pass "Enrollment flow completed"

    Write-Step "Reading trace_id from the structured enrollment log"
    $traceId = Find-EnrollmentTraceId -EnrollmentId $flow.Enrollment.id
    Write-Info "Trace ID: $traceId"
    Write-Pass "Trace context is present in application logs"

    Write-Step "Waiting for the complete trace in Tempo"
    $traceJson = $null
    $deadline = (Get-Date).AddSeconds(60)
    do {
        try {
            $trace = Invoke-RestMethod -Uri "$script:TempoUrl/api/traces/$traceId"
            $candidateJson = $trace | ConvertTo-Json -Depth 100 -Compress
            $hasCourse = $candidateJson -match "course-service"
            $hasNotification = $candidateJson -match "notification-service"
            $hasPublish = $candidateJson -match "rabbitmq publish enrollment\.created"
            $hasConsumer = $candidateJson -match "rabbitmq process enrollment\.created"
            if ($hasCourse -and $hasNotification -and $hasPublish -and $hasConsumer) {
                $traceJson = $candidateJson
                break
            }
        }
        catch {
            # Tempo can return 404 while the batch is still being flushed.
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if (-not $traceJson) {
        throw "Tempo did not return the complete HTTP and RabbitMQ trace within 60 seconds. Trace ID: $traceId"
    }

    Write-Pass "Trace contains course-service HTTP spans"
    Write-Pass "Trace contains the RabbitMQ producer span"
    Write-Pass "Trace contains the notification-service consumer span"
    Write-Info "Open Tempo in Grafana and search for Trace ID: $traceId"

    Open-DemoUrl "$script:GrafanaUrl/explore"
}

function Get-RabbitAuthorizationHeader {
    $bytes = [Text.Encoding]::ASCII.GetBytes("$script:RabbitUsername`:$script:RabbitPassword")
    return @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }
}

function Get-RabbitQueue {
    $headers = Get-RabbitAuthorizationHeader
    return Invoke-RestMethod -Uri "$script:RabbitManagementUrl/api/queues/%2F/notification.enrollment-events" -Headers $headers
}

function Invoke-RabbitMqShowcase {
    Write-Section "RABBITMQ: durable asynchronous delivery"

    Write-Step "Checking the durable exchange and queue"
    $headers = Get-RabbitAuthorizationHeader
    $exchange = Invoke-RestMethod -Uri "$script:RabbitManagementUrl/api/exchanges/%2F/lms.events" -Headers $headers
    $queueBefore = Get-RabbitQueue
    Assert-Value -Actual ([bool]$exchange.durable) -Expected $true -Description "Exchange lms.events is durable"
    Assert-Value -Actual ([bool]$queueBefore.durable) -Expected $true -Description "Queue notification.enrollment-events is durable"
    if ([int]$queueBefore.consumers -lt 1) {
        throw "Notification queue has no active consumer before the test."
    }
    Write-Pass "Notification consumer is connected"

    Wait-ForPresenter "Press Enter to stop notification-service and queue an event"

    $restoreNotificationService = $true
    $flow = $null
    try {
        Write-Step "Stopping notification-service"
        Invoke-DockerCommand -DockerArguments @("compose", "stop", "notification-service") | ForEach-Object {
            Write-Info "$_"
        }

        Wait-Until -Description "RabbitMQ consumer disconnect" -TimeoutSeconds 30 -Condition {
            try {
                return [int](Get-RabbitQueue).consumers -eq 0
            }
            catch {
                return $false
            }
        }
        Write-Pass "RabbitMQ reports zero consumers"

        Write-Step "Publishing enrollment.created while the consumer is offline"
        $flow = Invoke-DemoEnrollmentFlow -SkipProgress
        Write-Info "Student: $($flow.Student.Username)"
        Write-Info "Enrollment: $($flow.Enrollment.id)"

        Wait-Until -Description "queued RabbitMQ message" -TimeoutSeconds 30 -Condition {
            try {
                return [int](Get-RabbitQueue).messages_ready -ge 1
            }
            catch {
                return $false
            }
        }
        $queued = Get-RabbitQueue
        Write-Pass "Message stayed in the durable queue (ready=$($queued.messages_ready), consumers=$($queued.consumers))"
    }
    finally {
        if ($restoreNotificationService) {
            Write-Step "Starting notification-service"
            Invoke-DockerCommand -DockerArguments @("compose", "start", "notification-service") | ForEach-Object {
                Write-Info "$_"
            }
            Wait-ForHttp -Uri "$script:NotificationUrl/ready" -Description "notification-service after restart" -TimeoutSeconds 60
        }
    }

    Write-Step "Waiting for the restarted consumer to drain the queue"
    Wait-Until -Description "RabbitMQ queue drain" -TimeoutSeconds 45 -Condition {
        try {
            $queue = Get-RabbitQueue
            return [int]$queue.messages_ready -eq 0 -and [int]$queue.consumers -ge 1
        }
        catch {
            return $false
        }
    }
    $queueAfter = Get-RabbitQueue
    Write-Pass "Consumer processed the saved message (ready=$($queueAfter.messages_ready), consumers=$($queueAfter.consumers))"

    if ($null -ne $flow) {
        Wait-Until -Description "notification log" -TimeoutSeconds 30 -Condition {
            $logs = (Invoke-DockerCommand -DockerArguments @(
                "compose", "logs", "--since", "3m", "--no-log-prefix", "notification-service"
            )) -join "`n"
            return $logs -match "notification_simulated" -and $logs -match [regex]::Escape($flow.Student.Username)
        }
        Write-Pass "Notification service logged the simulated notification"
    }

    Open-DemoUrl $script:RabbitManagementUrl
}

$scenarioOrder = @("databases", "crud", "auth", "metrics", "logs", "traces", "rabbitmq")
$selectedScenarios = if ($Scenario -eq "all") {
    $scenarioOrder
}
else {
    @($Scenario)
}

Push-Location $script:ProjectRoot
try {
    Write-Section "COURSEFLOW AUTOMATED SHOWCASE"
    Write-Info "Scenario: $Scenario"
    Write-Info "Project: $script:ProjectRoot"
    Assert-Preflight

    foreach ($selected in $selectedScenarios) {
        switch ($selected) {
            "databases" { Invoke-DatabaseShowcase }
            "crud" { Invoke-CrudShowcase }
            "auth" { Invoke-AuthShowcase }
            "metrics" { Invoke-MetricsShowcase }
            "logs" { Invoke-LogsShowcase }
            "traces" { Invoke-TracesShowcase }
            "rabbitmq" { Invoke-RabbitMqShowcase }
        }

        Wait-ForPresenter "Scenario '$selected' passed. Press Enter to continue"
    }

    Write-Section "SHOWCASE COMPLETE"
    Write-Pass "All selected scenarios passed: $($selectedScenarios -join ', ')"
}
catch {
    Write-Section "SHOWCASE FAILED"
    Write-Fail $_.Exception.Message
    Write-Info "Fix the reported problem and run the same scenario again."
    exit 1
}
finally {
    Pop-Location
}

