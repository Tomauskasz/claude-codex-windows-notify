param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$notifier = Join-Path $root "plugins\claude-codex-windows-notify\scripts\notify.ps1"
$hooksPath = Join-Path $root "plugins\claude-codex-windows-notify\hooks\hooks.json"
$fixtureDirectory = Join-Path $PSScriptRoot "fixtures"
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("claude-codex-windows-notify-tests-" + [guid]::NewGuid())

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

function Get-NotifierFunctionSource {
    param([string]$Name)

    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($notifier, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        throw "Notifier failed to parse: $($parseErrors[0].Message)"
    }
    $definition = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $definition) {
        throw "Notifier does not define a function named '$Name'."
    }
    return $definition.Extent.Text
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
        [ValidateSet("TurnComplete", "ApprovalRequested", "AttentionRequested", "BackgroundComplete", "TurnFailed")]
        [string]$Event,
        [ValidateSet("Codex", "Claude")]
        [string]$ProductName = "Codex"
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        $notifier + '" -DryRun -Event ' + $Event + ' -ProductName ' + $ProductName
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Redirected streams otherwise decode using the calling console's encoding, so running this
    # suite from a non-UTF-8 shell would mangle the notifier's output and fail the Unicode checks.
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $payloadBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Payload)
    $process.StandardInput.BaseStream.Write($payloadBytes, 0, $payloadBytes.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.BaseStream.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    New-Item -ItemType File -Path (Join-Path $temporaryDirectory "wezterm.exe") | Out-Null
    $env:WEZTERM_EXECUTABLE_DIR = $temporaryDirectory
    $env:WEZTERM_PANE = "42"
    $env:WEZTERM_UNIX_SOCKET = "test-socket"

    $codexHome = Join-Path $temporaryDirectory "codex-home"
    $claudeSessionDirectory = Join-Path $temporaryDirectory "claude-home\sessions"
    New-Item -ItemType Directory -Path $codexHome | Out-Null
    New-Item -ItemType Directory -Path $claudeSessionDirectory -Force | Out-Null
    $env:CODEX_HOME = $codexHome
    $env:CLAUDE_CONFIG_DIR = Join-Path $temporaryDirectory "claude-home"

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

    $questionPayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "PermissionRequest"
        session_id = "claude-test-session"
        tool_name = "AskUserQuestion"
        tool_input = @{
            questions = @(@{ question = "Which approach should I use?" })
        }
    } | ConvertTo-Json -Compress -Depth 5
    $questionResult = Invoke-NotifierDryRun $questionPayload "ApprovalRequested" "Claude"
    Assert-ProcessSucceeded $questionResult "Claude question fixture should succeed."
    $question = $questionResult.Stdout | ConvertFrom-Json
    Assert-Equal $question.title "Claude has a question" "Questions should be distinguished from approvals."
    Assert-Equal $question.message "Which approach should I use?" "Question notifications should preview the first question."

    $unicodePreview = "Shift+Enter $([char]0x2192) newline $([char]0x2014) caf$([char]0x00E9) " +
        (-join @([char]0x65E5, [char]0x672C, [char]0x8A9E)) + " " +
        [char]::ConvertFromUtf32(0x1F680)
    $unicodePayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "Stop"
        last_assistant_message = $unicodePreview
        session_id = "unicode-preview-test"
    } | ConvertTo-Json -Compress
    $unicodeResult = Invoke-NotifierDryRun $unicodePayload "TurnComplete"
    Assert-ProcessSucceeded $unicodeResult "Raw UTF-8 hook payload should parse successfully."
    $unicode = $unicodeResult.Stdout | ConvertFrom-Json
    Assert-Equal $unicode.message $unicodePreview "Notification preview should preserve every Unicode code point."

    $claudeStopResult = Invoke-NotifierDryRun $stopPayload "TurnComplete" "Claude"
    Assert-ProcessSucceeded $claudeStopResult "Claude Stop fixture should succeed."
    $claudeStop = $claudeStopResult.Stdout | ConvertFrom-Json
    Assert-Equal $claudeStop.title "Claude finished" "Product name should drive the completion title."
    Assert-Equal $claudeStop.product_name "Claude" "The payload should name the product so the detached worker can too."
    Assert-Equal $stop.product_name "Codex" "The payload should name the product for Codex sessions as well."

    $notificationPayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "Notification"
        message = "Claude is waiting for your answer."
        notification_type = "agent_needs_input"
        session_id = "claude-test-session"
    } | ConvertTo-Json -Compress
    $attentionResult = Invoke-NotifierDryRun $notificationPayload "AttentionRequested" "Claude"
    Assert-ProcessSucceeded $attentionResult "Claude Notification fixture should succeed."
    $attention = $attentionResult.Stdout | ConvertFrom-Json
    Assert-Equal $attention.title "Claude needs you" "Attention notifications should use the Claude title."
    Assert-Equal $attention.message "Claude is waiting for your answer." "Attention notifications should preserve Claude's message."

    $failurePayload = [ordered]@{
        cwd = "C:\work\demo"
        error = "rate_limit"
        hook_event_name = "StopFailure"
        last_assistant_message = "API Error: Rate limit reached"
        session_id = "claude-test-session"
    } | ConvertTo-Json -Compress
    $failureResult = Invoke-NotifierDryRun $failurePayload "TurnFailed" "Claude"
    Assert-ProcessSucceeded $failureResult "Claude StopFailure fixture should succeed."
    $failure = $failureResult.Stdout | ConvertFrom-Json
    Assert-Equal $failure.title "Claude failed" "Failure notifications should identify Claude."
    Assert-Equal $failure.message "API Error: Rate limit reached" "Failure notifications should preserve the rendered error."

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

    $codexIndexLines = @(
        (@{ id = "codex-other-session"; thread_name = "Unrelated" } | ConvertTo-Json -Compress),
        (@{ id = "codex-named-session"; thread_name = "Stale name" } | ConvertTo-Json -Compress),
        "",
        "not-json",
        (@{ id = "codex-named-session"; thread_name = "Notifs" } | ConvertTo-Json -Compress)
    )
    Set-Content -LiteralPath (Join-Path $codexHome "session_index.jsonl") -Value $codexIndexLines -Encoding UTF8
    $codexNamedPayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "Stop"
        last_assistant_message = "Done."
        session_id = "codex-named-session"
    } | ConvertTo-Json -Compress
    $codexNamedResult = Invoke-NotifierDryRun $codexNamedPayload "TurnComplete"
    Assert-ProcessSucceeded $codexNamedResult "Named Codex session should succeed."
    $codexNamed = $codexNamedResult.Stdout | ConvertFrom-Json
    Assert-Equal $codexNamed.session_name "Notifs" "Codex notifications should show the latest session name, not the session ID."

    $unnamedCodexPayload = $codexNamedPayload -replace "codex-named-session", "codex-unnamed-session"
    $unnamedCodexResult = Invoke-NotifierDryRun $unnamedCodexPayload "TurnComplete"
    Assert-ProcessSucceeded $unnamedCodexResult "Unnamed Codex session should succeed."
    $unnamedCodex = $unnamedCodexResult.Stdout | ConvertFrom-Json
    Assert-Equal $unnamedCodex.session_name "codex-unnamed-session" "Codex sessions without a name should fall back to the session ID."

    Set-Content -LiteralPath (Join-Path $claudeSessionDirectory "4242.json") -Encoding UTF8 -Value (
        @{ pid = 4242; sessionId = "claude-named-session"; name = "tomas-c6"; nameSource = "derived" } | ConvertTo-Json -Compress
    )
    Set-Content -LiteralPath (Join-Path $claudeSessionDirectory "broken.json") -Encoding UTF8 -Value "not-json"
    $claudeNamedPayload = $codexNamedPayload -replace "codex-named-session", "claude-named-session"
    $claudeNamedResult = Invoke-NotifierDryRun $claudeNamedPayload "TurnComplete" "Claude"
    Assert-ProcessSucceeded $claudeNamedResult "Named Claude session should succeed."
    $claudeNamed = $claudeNamedResult.Stdout | ConvertFrom-Json
    Assert-Equal $claudeNamed.session_name "tomas-c6" "Claude notifications should show the session name, not the session ID."

    $unnamedClaudePayload = $codexNamedPayload -replace "codex-named-session", "claude-unknown-session"
    $unnamedClaudeResult = Invoke-NotifierDryRun $unnamedClaudePayload "TurnComplete" "Claude"
    Assert-ProcessSucceeded $unnamedClaudeResult "Unknown Claude session should succeed."
    $unnamedClaude = $unnamedClaudeResult.Stdout | ConvertFrom-Json
    Assert-Equal $unnamedClaude.session_name "claude-unknown-session" "Claude sessions without a name record should fall back to the session ID."

    # The popup worker is detached, so the terminal-host ancestry has to be captured while the hook
    # still has a walkable parent chain. In this test the notifier's parent is the test runner.
    $chain = @($stop.host_process_chain)
    Assert-True ($chain.Count -gt 0) "Hook payload should capture the originating process ancestry."
    Assert-Equal $chain[0].pid $PID "The nearest captured ancestor should be the process that ran the hook."
    Assert-True ($chain.Count -le 12) "Ancestry capture should stay within its depth limit."
    Assert-True (@($chain | Where-Object { [int]$_.pid -le 0 }).Count -eq 0) "Every captured ancestor should have a real process ID."
    Assert-True (@($chain | Where-Object { -not $_.name }).Count -eq 0) "Every captured ancestor should be named."
    $boundaryNames = @("services.exe", "svchost.exe", "wininit.exe", "winlogon.exe", "sihost.exe", "explorer.exe", "csrss.exe")
    $crossedBoundary = @($chain | Where-Object { $boundaryNames -contains ([string]$_.name).ToLowerInvariant() })
    Assert-Equal $crossedBoundary.Count 0 "Ancestry capture should stop before session managers and the shell."
    Assert-True (@($chain | Group-Object { $_.pid } | Where-Object { $_.Count -gt 1 }).Count -eq 0) "Ancestry capture should not repeat a process."
    Assert-True (@($generic.host_process_chain).Count -gt 0) "Ancestry capture should also work outside WezTerm, where it is the only focus route."

    . ([scriptblock]::Create((Get-NotifierFunctionSource "Get-WorkingDirectoryTitleSegments")))
    $repositorySegments = @(Get-WorkingDirectoryTitleSegments "D:\Documents\beamng_driving_agent\src\agents")
    Assert-Equal ($repositorySegments -join ",") "agents,src,beamng_driving_agent,Documents" "Title segments should run from the deepest folder outwards."
    $profileSegments = @(Get-WorkingDirectoryTitleSegments (Join-Path $env:USERPROFILE "claude-codex-windows-notify"))
    Assert-Equal ($profileSegments -join ",") "claude-codex-windows-notify" "Title segments should stop at the user profile instead of matching on 'Users'."
    Assert-Equal @(Get-WorkingDirectoryTitleSegments $env:USERPROFILE).Count 0 "The profile directory itself yields no distinguishing segment."
    Assert-Equal @(Get-WorkingDirectoryTitleSegments "D:\").Count 0 "A drive root yields no distinguishing segment."
    Assert-Equal @(Get-WorkingDirectoryTitleSegments "").Count 0 "A missing working directory yields no segments."
    $uncSegments = @(Get-WorkingDirectoryTitleSegments "\\server\share\repo\pkg")
    Assert-Equal ($uncSegments -join ",") "pkg,repo" "UNC paths should stop at the share root."
    Assert-True (@(Get-WorkingDirectoryTitleSegments "D:\a\b\c\d\e\f\g\h").Count -le 6) "Title segment search should stay bounded."

    $hooks = Get-Content -Raw -LiteralPath $hooksPath | ConvertFrom-Json
    Assert-Equal $hooks.hooks.Stop.Count 1 "One Stop hook should be declared."
    Assert-Equal $hooks.hooks.PermissionRequest.Count 1 "One PermissionRequest hook should be declared."
    $hookText = Get-Content -Raw -LiteralPath $hooksPath
    Assert-True ($hookText -match '\$\{PLUGIN_ROOT\}') "Hook commands should resolve scripts through PLUGIN_ROOT."

    # session_index.jsonl is the only local record of a Codex session name, so the notifier
    # reads it (read-only, best-effort) to label notifications. Everything else stays off limits.
    $forbiddenInternals = Select-String -LiteralPath $notifier -Pattern "state_5\.sqlite|\.sqlite|transcript_path|internal_chat_message_metadata_passthrough|last-assistant-message"
    Assert-Equal @($forbiddenInternals).Count 0 "Notifier should not depend on internal Codex persistence formats."

    # Activation must never change the geometry of a window that is already on screen.
    # SwitchToThisWindow is undocumented and raises and restores unconditionally, so it stays banned
    # outright. A restore is allowed only for a minimized window, which has no on-screen geometry to
    # preserve, and only from the single helper that guards on IsIconic.
    $notifierText = Get-Content -Raw -LiteralPath $notifier
    Assert-Equal ([regex]::Matches($notifierText, "SwitchToThisWindow").Count) 0 "Activation must not use SwitchToThisWindow, which raises and restores unconditionally."

    $restoreCalls = [regex]::Matches($notifierText, "ShowWindowAsync\(\s*window\s*,\s*(9|SW_RESTORE)\s*\)")
    Assert-Equal $restoreCalls.Count 1 "Exactly one restore call should exist, inside the minimized-only helper."

    $helperIndex = $notifierText.IndexOf("private static void RestoreIfMinimized(IntPtr window)")
    $activateIndex = $notifierText.IndexOf("public static bool ActivateWindow(IntPtr window)")
    Assert-True ($helperIndex -ge 0) "The minimized-only restore helper should exist."
    Assert-True ($activateIndex -gt $helperIndex) "ActivateWindow should follow the helper it calls."
    $helperRegion = $notifierText.Substring($helperIndex, $activateIndex - $helperIndex)
    Assert-True ($helperRegion.Contains("IsIconic(window)")) "The restore should be reached only through a minimized check."
    Assert-True ($restoreCalls[0].Index -ge $helperIndex -and $restoreCalls[0].Index -lt $activateIndex) "The only restore should sit inside the minimized-only helper."
    Assert-True ($notifierText.Substring($activateIndex).Contains("RestoreIfMinimized(window);")) "ActivateWindow should restore a minimized window before trying to focus it."

    $showWithoutActivationDeclaration = Select-String -LiteralPath $notifier -Pattern "public static extern bool ShowWindowAsync\(IntPtr window, int command\);"
    Assert-Equal @($showWithoutActivationDeclaration).Count 1 "The popup must retain the ShowWindowAsync declaration used to display without stealing focus."

    Write-Output "All tests passed."
} finally {
    $env:CODEX_HOME = $null
    $env:CLAUDE_CONFIG_DIR = $null
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = 0
