param(
    [int]$Port = 8088
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$webRoot = Join-Path $root "vcl-web"
$dataDir = Join-Path $root "data"
$tasksPath = Join-Path $dataDir "tasks.json"
$settingsPath = Join-Path $dataDir "settings.json"
$mailConfigPath = Join-Path $dataDir "mail-config.json"
$emailSubjectTemplatePath = Join-Path $dataDir "email-subject-template.txt"
$emailBodyTemplatePath = Join-Path $dataDir "email-body-template.html"
$calendarScript = Join-Path $root "Add-CalendarReminder.ps1"

if (!(Test-Path $webRoot)) { throw "Missing web folder: $webRoot" }
if (!(Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
if (!(Test-Path $tasksPath)) { "[]" | Set-Content -Path $tasksPath -Encoding UTF8 }
if (!(Test-Path $settingsPath)) {
    @{
        groups = @("Sản phẩm","Cá nhân","Đào tạo","Truyền thông","Đầu tư")
        collaborators = @()
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
}
if (!(Test-Path $mailConfigPath)) {
    @{
        enabled = $false
        smtpHost = "smtp.gmail.com"
        smtpPort = 587
        useSsl = $true
        fromEmail = ""
        smtpUser = ""
        smtpPassword = ""
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $mailConfigPath -Encoding UTF8
}

function Read-Tasks {
    $raw = [System.IO.File]::ReadAllText($tasksPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    if ($parsed -isnot [System.Array]) { $parsed = @($parsed) }

    $fixMojibake = {
        param([object]$val)
        if ($null -eq $val) { return $val }
        if (-not ($val -is [string])) { return $val }
        $s = [string]$val
        # Heuristic: common Vietnamese mojibake contains Ã or �
        if ($s -notmatch "[Ã�Â�]") { return $s }
        try {
            $latin1 = [System.Text.Encoding]::GetEncoding(28591) # ISO-8859-1
            $bytes = $latin1.GetBytes($s)
            $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)
            return $fixed
        }
        catch {
            return $s
        }
    }

    $tasks = @()
    foreach ($t in $parsed) {
        if ($null -eq $t) { continue }

        # Normalize tags: sometimes stored as string (older runs)
        if ($null -ne $t.tags) {
            if ($t.tags -is [string]) {
                $t.tags = @($t.tags)
            }
            elseif ($t.tags -isnot [System.Array]) {
                $t.tags = @($t.tags)
            }
        }
        else {
            $t.tags = @()
        }

        foreach ($field in @("title","notes","details","collaboratorName","group")) {
            $fixedVal = & $fixMojibake (Get-Field $t $field)
            Set-Field $t $field $fixedVal
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-Field $t "details" "")) -and -not [string]::IsNullOrWhiteSpace([string](Get-Field $t "notes" ""))) {
            $t.details = [string]$t.notes
        }
        $tasks += $t
    }

    return $tasks
}

function Write-Tasks([object[]]$tasks) {
    $tasks | ConvertTo-Json -Depth 10 | Set-Content -Path $tasksPath -Encoding UTF8
}

function Read-Settings {
    $raw = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{
            groups = @("Sản phẩm","Cá nhân","Đào tạo","Truyền thông","Đầu tư")
            collaborators = @()
        }
    }

    $settings = ($raw | ConvertFrom-Json)

    # Migration for older ASCII placeholders
    if ($settings.groups -is [System.Array]) {
        $map = @{
            "San pham" = "Sản phẩm"
            "Ca nhan" = "Cá nhân"
            "Dao tao" = "Đào tạo"
            "Truyen thong" = "Truyền thông"
            "Dau tu" = "Đầu tư"
        }
        $migrated = @()
        foreach ($g in $settings.groups) {
            $g2 = [string]$g
            if ($map.ContainsKey($g2)) { $migrated += $map[$g2] } else { $migrated += $g2 }
        }
        $settings.groups = $migrated
    }

    return $settings
}

function Write-Settings($settings) {
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
}

function Read-MailConfig {
    $raw = [System.IO.File]::ReadAllText($mailConfigPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{
            enabled = $false
            smtpHost = ""
            smtpPort = 587
            useSsl = $true
            fromEmail = ""
            smtpUser = ""
            smtpPassword = ""
        }
    }
    return ($raw | ConvertFrom-Json)
}

function Send-AssignmentMail($task) {
    $cfg = Read-MailConfig
    if (-not [bool](Get-Field $cfg "enabled" $false)) {
        return @{ sent = $false; reason = "mail_disabled" }
    }

    $to = [string](Get-Field $task "collaboratorEmail" "")
    if ([string]::IsNullOrWhiteSpace($to)) {
        return @{ sent = $false; reason = "missing_collaborator_email" }
    }

    $fromEmail = [string](Get-Field $cfg "fromEmail" "")
    $smtpHost = [string](Get-Field $cfg "smtpHost" "")
    $smtpUser = [string](Get-Field $cfg "smtpUser" "")
    $smtpPassword = [string](Get-Field $cfg "smtpPassword" "")
    $smtpPort = [int](Get-Field $cfg "smtpPort" 587)
    $useSsl = [bool](Get-Field $cfg "useSsl" $true)

    if ([string]::IsNullOrWhiteSpace($fromEmail) -or [string]::IsNullOrWhiteSpace($smtpHost) -or [string]::IsNullOrWhiteSpace($smtpUser) -or [string]::IsNullOrWhiteSpace($smtpPassword)) {
        return @{ sent = $false; reason = "mail_config_incomplete" }
    }

    if (!(Test-Path $emailSubjectTemplatePath) -or !(Test-Path $emailBodyTemplatePath)) {
        return @{ sent = $false; reason = "email_template_missing" }
    }

    $deadline = [string](Get-Field $task "deadline" "")
    $deadlineText = if ([string]::IsNullOrWhiteSpace($deadline)) { "Chua dat" } else { ([datetime]::Parse($deadline).ToString("dd/MM/yyyy HH:mm")) }
    $groupText = [string](Get-Field $task "group" "")
    if ([string]::IsNullOrWhiteSpace($groupText)) { $groupText = "Chua phan nhom" }
    $detailsText = [string](Get-Field $task "details" "")
    if ([string]::IsNullOrWhiteSpace($detailsText)) { $detailsText = "Khong co chi tiet." }
    $collabName = [string](Get-Field $task "collaboratorName" "")
    if ([string]::IsNullOrWhiteSpace($collabName)) { $collabName = "ban" }
    $taskTitle = [string](Get-Field $task "title" "")

    $subjectTemplate = [System.IO.File]::ReadAllText($emailSubjectTemplatePath, [System.Text.Encoding]::UTF8)
    $bodyTemplate = [System.IO.File]::ReadAllText($emailBodyTemplatePath, [System.Text.Encoding]::UTF8)

    $subject = $subjectTemplate.Replace("{TASK_TITLE}", $taskTitle).Trim()
    $body = $bodyTemplate.Replace("{COLLABORATOR_NAME}", $collabName).Replace("{TASK_TITLE}", $taskTitle).Replace("{DETAILS}", $detailsText).Replace("{DEADLINE}", $deadlineText).Replace("{GROUP}", $groupText)

    try {
        $mailMessage = New-Object System.Net.Mail.MailMessage
        $mailMessage.From = $fromEmail
        $mailMessage.To.Add($to)
        $mailMessage.Subject = $subject
        $mailMessage.SubjectEncoding = [System.Text.Encoding]::UTF8
        $mailMessage.Body = ""
        $mailMessage.BodyEncoding = [System.Text.Encoding]::UTF8
        $mailMessage.IsBodyHtml = $true
        $view = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString($body, [System.Text.Encoding]::UTF8, "text/html")
        $mailMessage.AlternateViews.Add($view)

        $smtpClient = New-Object System.Net.Mail.SmtpClient($smtpHost, $smtpPort)
        $smtpClient.EnableSsl = $useSsl
        $smtpClient.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPassword)
        $smtpClient.Send($mailMessage)

        $mailMessage.Dispose()
        $smtpClient.Dispose()
        return @{ sent = $true; reason = "ok" }
    }
    catch {
        return @{ sent = $false; reason = $_.Exception.Message }
    }
}

function Send-Json($response, $statusCode, $payload) {
    $response.StatusCode = $statusCode
    $response.ContentType = "application/json; charset=utf-8"
    $response.ContentEncoding = [System.Text.Encoding]::UTF8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10))
    $response.ContentLength64 = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

function Read-BodyJson($request) {
    $encoding = $request.ContentEncoding
    if ($null -eq $encoding) { $encoding = [System.Text.Encoding]::UTF8 }
    $reader = New-Object System.IO.StreamReader($request.InputStream, $encoding)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Get-Field($obj, [string]$name, $defaultValue = $null) {
    if ($null -eq $obj) { return $defaultValue }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] }
        return $defaultValue
    }
    $prop = $obj.PSObject.Properties[$name]
    if ($null -eq $prop) { return $defaultValue }
    return $prop.Value
}

function Set-Field($obj, [string]$name, $value) {
    $prop = $obj.PSObject.Properties[$name]
    if ($null -eq $prop) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value
    }
    else {
        $obj.$name = $value
    }
}

function Get-MimeType([string]$path) {
    switch ([System.IO.Path]::GetExtension($path).ToLowerInvariant()) {
        ".html" { "text/html; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        default { "text/plain; charset=utf-8" }
    }
}

$listener = New-Object System.Net.HttpListener
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "VCL running at $prefix"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req = $context.Request
        $res = $context.Response
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod.ToUpperInvariant()

        try {
            if ($path -eq "/api/tasks" -and $method -eq "GET") {
                Send-Json $res 200 (Read-Tasks)
                continue
            }

            if ($path -eq "/api/settings" -and $method -eq "GET") {
                Send-Json $res 200 (Read-Settings)
                continue
            }

            if ($path -eq "/api/settings/groups" -and $method -eq "PUT") {
                $body = Read-BodyJson $req
                $groups = @((Get-Field $body "groups" @()))
                $clean = @()
                foreach ($g in $groups) {
                    $name = [string]$g
                    if (-not [string]::IsNullOrWhiteSpace($name)) { $clean += $name.Trim() }
                }
                $settings = Read-Settings
                $settings.groups = $clean
                Write-Settings $settings
                Send-Json $res 200 $settings
                continue
            }

            if ($path -eq "/api/collaborators" -and $method -eq "POST") {
                $body = Read-BodyJson $req
                $name = [string](Get-Field $body "name" "")
                $email = [string](Get-Field $body "email" "")
                if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)) {
                    Send-Json $res 400 @{ error = "name and email are required" }
                    continue
                }

                $settings = Read-Settings
                $current = @($settings.collaborators)
                $exist = $current | Where-Object { $_.email -eq $email } | Select-Object -First 1
                if ($exist) {
                    $exist.name = $name.Trim()
                }
                else {
                    $current += [ordered]@{
                        id = [guid]::NewGuid().ToString()
                        name = $name.Trim()
                        email = $email.Trim()
                    }
                }
                $settings.collaborators = $current
                Write-Settings $settings
                Send-Json $res 200 $settings
                continue
            }

            if ($path -match "^/api/collaborators/([^/]+)$" -and $method -eq "DELETE") {
                $id = $Matches[1]
                $settings = Read-Settings
                $newList = @()
                foreach ($c in @($settings.collaborators)) { if ($c.id -ne $id) { $newList += $c } }
                $settings.collaborators = $newList
                Write-Settings $settings
                Send-Json $res 200 $settings
                continue
            }

            if ($path -eq "/api/tasks" -and $method -eq "POST") {
                $body = Read-BodyJson $req
                $title = Get-Field $body "title" ""
                if ([string]::IsNullOrWhiteSpace($title)) { Send-Json $res 400 @{ error = "title is required" }; continue }

                $tasks = Read-Tasks
                $task = [ordered]@{
                    id = [guid]::NewGuid().ToString()
                    title = [string]$title
                    deadline = (Get-Field $body "deadline" (Get-Date).ToString("o"))
                    group = [string](Get-Field $body "group" "")
                    collaboratorName = [string](Get-Field $body "collaboratorName" "")
                    collaboratorEmail = Get-Field $body "collaboratorEmail"
                    details = (Get-Field $body "details" (Get-Field $body "notes"))
                    notes = Get-Field $body "notes"
                    tags = @((Get-Field $body "tags" @()))
                    reminderType = [string](Get-Field $body "reminderType" "none")
                    status = "todo"
                    createdAt = (Get-Date).ToString("o")
                    updatedAt = (Get-Date).ToString("o")
                }
                # Normalize tags: accept "important" (string) from old data
                if ($task.tags -is [string]) { $task.tags = @($task.tags) }
                if ($null -eq $task.tags) { $task.tags = @() }
                $tasks = @($tasks) + @($task)
                Write-Tasks $tasks
                Send-Json $res 201 @{ task = $task; mail = @{ sent = $false; reason = "manual_send_only" } }
                continue
            }

            if ($path -match "^/api/tasks/([^/]+)$") {
                $taskId = $Matches[1]
                $tasks = @((Read-Tasks))
                $current = $tasks | Where-Object { $_.id -eq $taskId } | Select-Object -First 1
                if (!$current) { Send-Json $res 404 @{ error = "task not found" }; continue }

                if ($method -eq "PUT") {
                    $body = Read-BodyJson $req
                    $oldCollaboratorEmail = [string](Get-Field $current "collaboratorEmail" "")
                    $oldCollaboratorName = [string](Get-Field $current "collaboratorName" "")
                    foreach ($k in @("title","deadline","group","collaboratorName","collaboratorEmail","details","notes","tags","reminderType","status")) {
                        $value = Get-Field $body $k "__MISSING__"
                        if ($value -ne "__MISSING__") { Set-Field $current $k $value }
                    }
                    Set-Field $current "updatedAt" ((Get-Date).ToString("o"))
                    $rebuilt = @()
                    foreach ($t in $tasks) {
                        if ($t.id -eq $taskId) { $rebuilt += $current } else { $rebuilt += $t }
                    }
                    Write-Tasks $rebuilt
                    $mailResult = @{ sent = $false; reason = "manual_send_only" }
                    Send-Json $res 200 @{ task = $current; mail = $mailResult }
                    continue
                }

                if ($method -eq "DELETE") {
                    $newTasks = @()
                    foreach ($t in $tasks) { if ($t.id -ne $taskId) { $newTasks += $t } }
                    Write-Tasks $newTasks
                    Send-Json $res 200 @{ ok = $true }
                    continue
                }
            }

            if ($path -match "^/api/tasks/([^/]+)/calendar-sync$" -and $method -eq "POST") {
                $taskId = $Matches[1]
                $tasks = Read-Tasks
                $task = $tasks | Where-Object { $_.id -eq $taskId } | Select-Object -First 1
                if (!$task) { Send-Json $res 404 @{ error = "task not found" }; continue }
                if (!$task.deadline) { Send-Json $res 400 @{ error = "deadline is required before sync" }; continue }

                $start = [datetime]::Parse($task.deadline).ToString("yyyy-MM-dd HH:mm")
                $desc = [string](Get-Field $task "details" (Get-Field $task "notes" ""))
                $attendeeEmail = [string](Get-Field $task "collaboratorEmail" "")
                $calendarArgs = @(
                    "-ExecutionPolicy", "Bypass",
                    "-File", $calendarScript,
                    "-Title", ([string]$task.title),
                    "-StartAt", $start,
                    "-DurationMinutes", "30",
                    "-ReminderMinutes", "10"
                )
                if (-not [string]::IsNullOrWhiteSpace($desc)) {
                    $calendarArgs += @("-Description", $desc)
                }
                if (-not [string]::IsNullOrWhiteSpace($attendeeEmail)) {
                    $calendarArgs += @("-AttendeeEmail", $attendeeEmail)
                }
                $output = & powershell @calendarArgs 2>&1 | Out-String
                Send-Json $res 200 @{ ok = $true; message = $output }
                continue
            }

            if ($path -match "^/api/tasks/([^/]+)/send-email$" -and $method -eq "POST") {
                $taskId = $Matches[1]
                $tasks = Read-Tasks
                $task = $tasks | Where-Object { $_.id -eq $taskId } | Select-Object -First 1
                if (!$task) { Send-Json $res 404 @{ error = "task not found" }; continue }
                $mailResult = Send-AssignmentMail $task
                if (-not $mailResult.sent) {
                    Send-Json $res 400 @{ ok = $false; mail = $mailResult; error = "Không gửi được email. Kiểm tra cấu hình SMTP hoặc email người phối hợp." }
                    continue
                }
                Send-Json $res 200 @{ ok = $true; mail = $mailResult }
                continue
            }

            if ($path -eq "/" ) { $path = "/index.html" }
            $localPath = Join-Path $webRoot ($path.TrimStart('/').Replace('/', '\'))
            if ((Test-Path $localPath) -and -not (Get-Item $localPath).PSIsContainer) {
                $bytes = [System.IO.File]::ReadAllBytes($localPath)
                $res.StatusCode = 200
                $res.ContentType = Get-MimeType $localPath
                $res.ContentLength64 = $bytes.Length
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                $res.OutputStream.Close()
                continue
            }

            Send-Json $res 404 @{ error = "not found" }
        }
        catch {
            Send-Json $res 500 @{ error = $_.Exception.Message }
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
