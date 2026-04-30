param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [datetime]$StartAt,

    [string]$Description = "",
    [string]$AttendeeEmail = "",
    [int]$DurationMinutes,
    [int]$ReminderMinutes,
    [string]$ConfigPath = ".\google-calendar.config.json",
    [string]$TokenPath = ".\google-calendar.token.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (!(Test-Path $ConfigPath)) {
    throw "Missing config file: $ConfigPath"
}
if (!(Test-Path $TokenPath)) {
    throw "Missing token file: $TokenPath. Run Connect-GoogleCalendar.ps1 first."
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$token = Get-Content -Raw -Path $TokenPath | ConvertFrom-Json

if (-not $DurationMinutes -or $DurationMinutes -le 0) {
    $DurationMinutes = [int]$config.default_duration_minutes
}
if (-not $ReminderMinutes -or $ReminderMinutes -lt 0) {
    $ReminderMinutes = [int]$config.default_reminder_minutes
}

$refreshResponse = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -ContentType "application/x-www-form-urlencoded" -Body @{
    client_id = $config.client_id
    client_secret = $config.client_secret
    refresh_token = $token.refresh_token
    grant_type = "refresh_token"
}

$accessToken = $refreshResponse.access_token
if (-not $accessToken) {
    throw "Could not refresh access token. Re-run Connect-GoogleCalendar.ps1."
}

$endAt = $StartAt.AddMinutes($DurationMinutes)
$timezone = $config.timezone
$calendarId = $config.calendar_id

$eventPayload = @{
    summary = $Title
    description = $Description
    start = @{
        dateTime = $StartAt.ToString("yyyy-MM-ddTHH:mm:ss")
        timeZone = $timezone
    }
    end = @{
        dateTime = $endAt.ToString("yyyy-MM-ddTHH:mm:ss")
        timeZone = $timezone
    }
    reminders = @{
        useDefault = $false
        overrides = @(
            @{
                method = "popup"
                minutes = $ReminderMinutes
            }
        )
    }
}

if (-not [string]::IsNullOrWhiteSpace($AttendeeEmail)) {
    $eventPayload.attendees = @(
        @{
            email = $AttendeeEmail
        }
    )
}

$encodedCalendarId = [System.Uri]::EscapeDataString($calendarId)
$eventUri = "https://www.googleapis.com/calendar/v3/calendars/$encodedCalendarId/events"

$headers = @{
    Authorization = "Bearer $accessToken"
}

$eventJson = $eventPayload | ConvertTo-Json -Depth 10
$eventBytes = [System.Text.Encoding]::UTF8.GetBytes($eventJson)
$created = Invoke-RestMethod -Method Post -Uri $eventUri -Headers $headers -ContentType "application/json; charset=utf-8" -Body $eventBytes

Write-Host "Reminder created:"
Write-Host "Title: $($created.summary)"
Write-Host "Start: $($created.start.dateTime)"
Write-Host "Link : $($created.htmlLink)"
