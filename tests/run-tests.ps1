param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$notifier = Join-Path $root "plugins\codex-wezterm-notify\scripts\notify.ps1"
$hooksPath = Join-Path $root "plugins\codex-wezterm-notify\hooks\hooks.json"
$fixtureDirectory = Join-Path $PSScriptRoot "fixtures"
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("codex-wezterm-notify-tests-" + [guid]::NewGuid())

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ProcessSucceeded {
    param($Result, [string]$Message)
    if ($Result.ExitCode -ne 0) {
        throw "$Message`nSTDOUT:`n$($Result.Stdout)`nSTDERR:`n$($Result.Stderr)"
    }
}

function Invoke-NotifierDryRun {
    param(
        [string]$Payload,
        [ValidateSet("TurnComplete", "ApprovalRequested")]
        [string]$Event
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = $Payload | & (Join-Path $PSHOME "powershell.exe") `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $notifier -DryRun -Event $Event 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $output
        Stderr = $output
    }
}

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    New-Item -ItemType File -Path (Join-Path $temporaryDirectory "wezterm.exe") | Out-Null
    $env:WEZTERM_EXECUTABLE_DIR = $temporaryDirectory
    $env:WEZTERM_PANE = "42"
    $env:WEZTERM_UNIX_SOCKET = "test-socket"

    $null = [scriptblock]::Create((Get-Content -Raw -LiteralPath $notifier))

    $stopPayload = Get-Content -Raw -LiteralPath (Join-Path $fixtureDirectory "stop.json")
    $stopResult = Invoke-NotifierDryRun $stopPayload "TurnComplete"
    Assert-ProcessSucceeded $stopResult "Stop fixture should succeed."
    $stop = $stopResult.Stdout | ConvertFrom-Json
    Assert-Equal $stop.event "TurnComplete" "Stop event should map to completion."
    Assert-Equal $stop.message "All checks passed." "Supported last_assistant_message should drive the preview."
    Assert-Equal $stop.terminal_integration "wezterm" "WezTerm sessions should enable exact-pane integration."
    Assert-Equal $stop.source_pane_id "42" "Originating WezTerm pane should be captured."

    $permissionPayload = Get-Content -Raw -LiteralPath (Join-Path $fixtureDirectory "permission-request.json")
    $permissionResult = Invoke-NotifierDryRun $permissionPayload "ApprovalRequested"
    Assert-ProcessSucceeded $permissionResult "PermissionRequest fixture should succeed."
    $permission = $permissionResult.Stdout | ConvertFrom-Json
    Assert-Equal $permission.message "Approval requested for exec_command." "Tool name should appear in approval notifications."

    $env:WEZTERM_EXECUTABLE_DIR = $null
    $env:WEZTERM_PANE = $null
    $env:WEZTERM_UNIX_SOCKET = $null
    $genericResult = Invoke-NotifierDryRun $stopPayload "TurnComplete"
    Assert-ProcessSucceeded $genericResult "Stop fixture should succeed outside WezTerm."
    $generic = $genericResult.Stdout | ConvertFrom-Json
    Assert-Equal $generic.event "TurnComplete" "Generic terminal stop event should map to completion."
    Assert-Equal $generic.message "All checks passed." "Generic terminal preview should preserve the Codex message."
    Assert-Equal $generic.session_name "018f-test-session" "Generic terminal notification should preserve the session ID."
    Assert-Equal $generic.working_directory "C:\work\demo" "Generic terminal notification should preserve the working directory."
    Assert-Equal $generic.terminal_integration "none" "Non-WezTerm sessions should not enable terminal focus integration."
    Assert-Equal $generic.source_pane_id "" "Non-WezTerm sessions should not claim a source pane."
    Assert-Equal $generic.wezterm_executable "" "Non-WezTerm sessions should not resolve WezTerm."
    Assert-Equal $generic.wezterm_socket "" "Non-WezTerm sessions should not capture a WezTerm socket."

    $env:WEZTERM_EXECUTABLE_DIR = $temporaryDirectory
    $env:WEZTERM_PANE = "42"
    $env:WEZTERM_UNIX_SOCKET = "test-socket"

    $unicodeMessage = (1..1005 | ForEach-Object { [char]::ConvertFromUtf32(0x1F680) }) -join ""
    $longPayload = [ordered]@{
        cwd = "\\?\UNC\server\share\repo"
        hook_event_name = "Stop"
        last_assistant_message = $unicodeMessage
        session_id = "unicode-test"
    } | ConvertTo-Json -Compress
    $longResult = Invoke-NotifierDryRun $longPayload "TurnComplete"
    Assert-ProcessSucceeded $longResult "Long Unicode response should succeed."
    $long = $longResult.Stdout | ConvertFrom-Json
    Assert-Equal $long.working_directory "\\server\share\repo" "Extended UNC path should be normalized correctly."
    Assert-Equal ([Globalization.StringInfo]::ParseCombiningCharacters($long.message).Count) 1000 "Preview should be capped by text elements."
    Assert-True ($long.message.EndsWith("...")) "Truncated preview should end with an ellipsis marker."
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($longResult.Stdout) -lt 12000) "Detached notification DTO should remain safely below Windows command-line limits."

    $invalidResult = Invoke-NotifierDryRun "not-json" "TurnComplete"
    Assert-True ($invalidResult.ExitCode -ne 0) "Invalid JSON should fail."
    Assert-True ($invalidResult.Stderr -match "not valid JSON") "Invalid JSON should report the root cause."

    $mismatchedPayload = $stopPayload -replace '"Stop"', '"PermissionRequest"'
    $mismatchedResult = Invoke-NotifierDryRun $mismatchedPayload "TurnComplete"
    Assert-True ($mismatchedResult.ExitCode -ne 0) "Mismatched hook type should fail."
    Assert-True ($mismatchedResult.Stderr -match "Expected a Stop hook payload") "Mismatched hook type should report the contract error."

    $hooks = Get-Content -Raw -LiteralPath $hooksPath | ConvertFrom-Json
    Assert-Equal $hooks.hooks.Stop.Count 1 "One Stop hook should be declared."
    Assert-Equal $hooks.hooks.PermissionRequest.Count 1 "One PermissionRequest hook should be declared."
    $hookText = Get-Content -Raw -LiteralPath $hooksPath
    Assert-True ($hookText -match '\$\{PLUGIN_ROOT\}') "Hook commands should resolve scripts through PLUGIN_ROOT."

    $forbiddenInternals = Select-String -LiteralPath $notifier -Pattern "state_5\.sqlite|session_index\.jsonl|transcript_path|internal_chat_message_metadata_passthrough|last-assistant-message"
    Assert-Equal @($forbiddenInternals).Count 0 "Notifier should not depend on internal Codex persistence formats."

    Write-Output "All tests passed."
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = 0
