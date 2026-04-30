param(
    [string]$ConfigPath = ".\google-calendar.config.json",
    [string]$TokenPath = ".\google-calendar.token.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (!(Test-Path $ConfigPath)) {
    throw "Missing config file: $ConfigPath"
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$scope = "https://www.googleapis.com/auth/calendar"

$deviceBody = @{
    client_id = $config.client_id
    scope = $scope
}

$deviceResponse = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/device/code" -ContentType "application/x-www-form-urlencoded" -Body $deviceBody

Write-Host "Open this URL in browser:"
Write-Host $deviceResponse.verification_url
Write-Host ""
Write-Host "Enter this code:"
Write-Host $deviceResponse.user_code
Write-Host ""
Write-Host "Waiting for approval..."

try {
    Start-Process $deviceResponse.verification_url | Out-Null
}
catch {
    # Ignore browser launch failures; user can open URL manually.
}

$intervalSec = if ($deviceResponse.interval) { [int]$deviceResponse.interval } else { 5 }
$expiresAt = (Get-Date).AddSeconds([int]$deviceResponse.expires_in)

while ((Get-Date) -lt $expiresAt) {
    Start-Sleep -Seconds $intervalSec

    $tokenBody = @{
        client_id = $config.client_id
        device_code = $deviceResponse.device_code
        grant_type = "urn:ietf:params:oauth:grant-type:device_code"
    }

    if ($config.client_secret) {
        $tokenBody.client_secret = $config.client_secret
    }

    try {
        $tokenResponse = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -ContentType "application/x-www-form-urlencoded" -Body $tokenBody

        if ($tokenResponse.access_token) {
            $tokenResponse | ConvertTo-Json -Depth 10 | Set-Content -Path $TokenPath -Encoding UTF8
            Write-Host "Saved token to $TokenPath"
            exit 0
        }
    }
    catch {
        if ($_.Exception -and $_.Exception.Response -and $_.Exception.Response.StatusCode -and [int]$_.Exception.Response.StatusCode -eq 428) {
            continue
        }

        $raw = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $raw = $_.ErrorDetails.Message
        }
        elseif ($_.Exception -and $_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $raw = $reader.ReadToEnd()
        }

        if ($raw) {
            $oauthErr = $null
            try {
                $oauthErr = $raw | ConvertFrom-Json
            }
            catch {
                throw "Token polling failed: $raw"
            }

            switch ($oauthErr.error) {
                "authorization_pending" { continue }
                "slow_down" { $intervalSec += 5; continue }
                "access_denied" { throw "Authorization denied by user." }
                "expired_token" { throw "Device code expired. Run script again." }
                default { throw "Token polling failed: $raw" }
            }
        }

        throw
    }
}

throw "Timed out waiting for approval. Run script again."
