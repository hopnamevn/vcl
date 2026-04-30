param(
    [string]$ConfigPath = ".\google-calendar.config.json",
    [string]$TokenPath = ".\google-calendar.token.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (!(Test-Path $ConfigPath)) {
    throw "Missing config file: $ConfigPath. Copy google-calendar.config.example.json -> google-calendar.config.json and fill client_id/client_secret."
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$scope = "https://www.googleapis.com/auth/calendar.events"
$encodedRedirect = [System.Uri]::EscapeDataString($config.redirect_uri)
$encodedScope = [System.Uri]::EscapeDataString($scope)
$encodedClientId = [System.Uri]::EscapeDataString($config.client_id)
$authUrl = "https://accounts.google.com/o/oauth2/v2/auth?client_id=$encodedClientId&redirect_uri=$encodedRedirect&response_type=code&scope=$encodedScope&access_type=offline&prompt=consent"

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($config.redirect_uri)

try {
    $listener.Start()
}
catch {
    $details = $_.Exception.Message
    throw "Cannot start listener at $($config.redirect_uri). Ensure this exact redirect URI exists in Google OAuth client settings and port is free. Details: $details"
}

Write-Host "Opening browser for Google sign-in..."
Start-Process $authUrl | Out-Null
Write-Host "Waiting for authorization callback..."

$context = $listener.GetContext()
$request = $context.Request
$code = $request.QueryString["code"]
$oauthError = $request.QueryString["error"]

$responseText = if ($code) { "Connected successfully. You can close this tab." } else { "Authorization failed: $oauthError" }
$buffer = [System.Text.Encoding]::UTF8.GetBytes($responseText)
$context.Response.ContentLength64 = $buffer.Length
$context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
$context.Response.OutputStream.Close()
$listener.Stop()

if (!$code) {
    throw "Google authorization failed: $oauthError"
}

$tokenResponse = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -ContentType "application/x-www-form-urlencoded" -Body @{
    code = $code
    client_id = $config.client_id
    client_secret = $config.client_secret
    redirect_uri = $config.redirect_uri
    grant_type = "authorization_code"
}

$tokenResponse | ConvertTo-Json -Depth 10 | Set-Content -Path $TokenPath -Encoding UTF8
Write-Host "Saved token to $TokenPath"
