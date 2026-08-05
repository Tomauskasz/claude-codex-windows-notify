param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$notifier = Join-Path $root "plugins\claude-codex-windows-notify\scripts\notify.ps1"
$openCodeNotifier = Join-Path $root "plugins\claude-codex-windows-notify\notification.js"
$hooksPath = Join-Path $root "plugins\claude-codex-windows-notify\hooks\hooks.json"
$soundsDirectory = Join-Path $root "plugins\claude-codex-windows-notify\sounds"
$fixtureDirectory = Join-Path $PSScriptRoot "fixtures"
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("claude-codex-windows-notify-tests-" + [guid]::NewGuid())
$originalTermProgram = $env:TERM_PROGRAM
$originalVsCodeInjection = $env:VSCODE_INJECTION

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

function Get-NotifierFocusTypeSource {
    $notifierText = Get-Content -Raw -LiteralPath $notifier
    $match = [regex]::Match(
        $notifierText,
        "(?s)Add-Type -ReferencedAssemblies `"System\.Windows\.Forms\.dll`".*?-TypeDefinition @'\r?\n(?<source>.*?)\r?\n'@"
    )
    if (-not $match.Success) {
        throw "Notifier does not define the window-focus types."
    }
    return $match.Groups["source"].Value
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
        [string]$Event,
        [ValidateSet("Codex", "Claude", "OpenCode")]
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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NotifyTestSqlite
{
    private const int SQLITE_OK = 0;
    private const int SQLITE_OPEN_READWRITE = 0x00000002;
    private const int SQLITE_OPEN_CREATE = 0x00000004;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(IntPtr filename, out IntPtr database, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr database, IntPtr sql, IntPtr callback, IntPtr argument, out IntPtr error);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void sqlite3_free(IntPtr memory);

    private static IntPtr Utf8(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    private static string Quote(string value)
    {
        return "'" + value.Replace("'", "''") + "'";
    }

    public static void Create(string path)
    {
        IntPtr pathPointer = Utf8(path);
        IntPtr database = IntPtr.Zero;
        try
        {
            int result = sqlite3_open_v2(pathPointer, out database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, IntPtr.Zero);
            if (result != SQLITE_OK)
            {
                throw new InvalidOperationException("Could not create the SQLite test fixture (result " + result + ").");
            }

            string sql =
                "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT NOT NULL, name TEXT);" +
                "INSERT INTO threads VALUES (" + Quote("codex-named-session") + ", " + Quote("Database automatic title") + ", NULL);" +
                "INSERT INTO threads VALUES (" + Quote("codex-db-named-session") + ", " + Quote("Old automatic title") + ", " + Quote("Database renamed session") + ");" +
                "INSERT INTO threads VALUES (" + Quote("codex-db-titled-session") + ", " + Quote("Automatically generated session title\nPrompt preview") + ", NULL);";
            IntPtr sqlPointer = Utf8(sql);
            IntPtr error = IntPtr.Zero;
            try
            {
                result = sqlite3_exec(database, sqlPointer, IntPtr.Zero, IntPtr.Zero, out error);
                if (result != SQLITE_OK)
                {
                    string message = error == IntPtr.Zero ? "unknown error" : Marshal.PtrToStringAnsi(error);
                    throw new InvalidOperationException("Could not populate the SQLite test fixture: " + message);
                }
            }
            finally
            {
                if (error != IntPtr.Zero) sqlite3_free(error);
                Marshal.FreeHGlobal(sqlPointer);
            }
        }
        finally
        {
            if (database != IntPtr.Zero) sqlite3_close(database);
            Marshal.FreeHGlobal(pathPointer);
        }
    }
}
'@

try {
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    New-Item -ItemType File -Path (Join-Path $temporaryDirectory "wezterm.exe") | Out-Null
    $env:WEZTERM_EXECUTABLE_DIR = $temporaryDirectory
    $env:WEZTERM_PANE = "42"
    $env:WEZTERM_UNIX_SOCKET = "test-socket"
    $env:TERM_PROGRAM = "vscode"
    $env:VSCODE_INJECTION = "1"

    $codexHome = Join-Path $temporaryDirectory "codex-home"
    $codexRolloutDirectory = Join-Path $codexHome "sessions\2026\08\05"
    $claudeSessionDirectory = Join-Path $temporaryDirectory "claude-home\sessions"
    $claudeProjectDirectory = Join-Path $temporaryDirectory "claude-home\projects\C--work-demo"
    New-Item -ItemType Directory -Path $codexRolloutDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $claudeSessionDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $claudeProjectDirectory -Force | Out-Null
    $env:CODEX_HOME = $codexHome
    $env:CLAUDE_CONFIG_DIR = Join-Path $temporaryDirectory "claude-home"
    [NotifyTestSqlite]::Create((Join-Path $codexHome "state_5.sqlite"))

    $null = [scriptblock]::Create((Get-Content -Raw -LiteralPath $notifier))

    $stopPayload = Get-Content -Raw -LiteralPath (Join-Path $fixtureDirectory "stop.json")
    $stopResult = Invoke-NotifierDryRun $stopPayload "TurnComplete"
    Assert-ProcessSucceeded $stopResult "Stop fixture should succeed."
    $stop = $stopResult.Stdout | ConvertFrom-Json
    Assert-Equal $stop.event "TurnComplete" "Stop event should map to completion."
    Assert-Equal $stop.message "All checks passed." "Supported last_assistant_message should drive the preview."
    Assert-Equal $stop.sound_path ([IO.Path]::GetFullPath((Join-Path $soundsDirectory "complete.wav"))) "Completion notifications should use the local gamified complete sound."
    Assert-Equal $stop.terminal_integration "wezterm" "WezTerm sessions should enable exact-pane integration."
    Assert-Equal $stop.source_pane_id "42" "Originating WezTerm pane should be captured."
    Assert-Equal $stop.host_process_family_hint "vscode" "The VS Code host family hint should be captured."

    $permissionPayload = Get-Content -Raw -LiteralPath (Join-Path $fixtureDirectory "permission-request.json")
    $permissionResult = Invoke-NotifierDryRun $permissionPayload "ApprovalRequested"
    Assert-ProcessSucceeded $permissionResult "PermissionRequest fixture should succeed."
    $permission = $permissionResult.Stdout | ConvertFrom-Json
    Assert-Equal $permission.message "Approval requested for exec_command." "Tool name should appear in approval notifications."
    Assert-Equal $permission.sound_path ([IO.Path]::GetFullPath((Join-Path $soundsDirectory "approval.wav"))) "Approval notifications should use the local gamified approval sound."

    $subagentPermissionPayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "PermissionRequest"
        session_id = "codex-main-session"
        agent_id = "agent-sub-1"
        agent_type = "explore"
        tool_name = "exec_command"
        tool_input = @{ command = "ls" }
    } | ConvertTo-Json -Compress -Depth 5
    $subagentPermissionResult = Invoke-NotifierDryRun $subagentPermissionPayload "ApprovalRequested"
    Assert-ProcessSucceeded $subagentPermissionResult "Subagent PermissionRequest should be ignored."
    $subagentPermission = $subagentPermissionResult.Stdout | ConvertFrom-Json
    Assert-Equal $subagentPermission.skipped $true "Subagent permission requests must not raise a popup."

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

    $backgroundPayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "Notification"
        notification_type = "agent_completed"
        message = "Background agent finished."
        session_id = "claude-main-session"
        title = "Background complete"
    } | ConvertTo-Json -Compress
    $backgroundResult = Invoke-NotifierDryRun $backgroundPayload "BackgroundComplete" "Claude"
    Assert-True ($backgroundResult.ExitCode -ne 0) "BackgroundComplete must not be a supported notification category."
    Assert-True ($backgroundResult.Stderr -match "ValidateSet") "BackgroundComplete rejection should identify the accepted event contract."

    $notificationPayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "Notification"
        message = "Claude is waiting for your answer."
        notification_type = "elicitation_dialog"
        session_id = "claude-test-session"
    } | ConvertTo-Json -Compress
    $attentionResult = Invoke-NotifierDryRun $notificationPayload "AttentionRequested" "Claude"
    Assert-ProcessSucceeded $attentionResult "Claude Notification fixture should succeed."
    $attention = $attentionResult.Stdout | ConvertFrom-Json
    Assert-Equal $attention.title "Claude needs you" "Attention notifications should use the Claude title."
    Assert-Equal $attention.message "Claude is waiting for your answer." "Attention notifications should preserve Claude's message."
    Assert-Equal $attention.sound_path ([IO.Path]::GetFullPath((Join-Path $soundsDirectory "approval.wav"))) "Attention notifications should use the local gamified approval sound."

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
    Assert-Equal $failure.sound_path ([IO.Path]::GetFullPath((Join-Path $soundsDirectory "failure.wav"))) "Failure notifications should use the local gamified failure sound."

    foreach ($soundName in @("complete.wav", "approval.wav", "failure.wav")) {
        $soundPath = Join-Path $soundsDirectory $soundName
        Assert-True (Test-Path -LiteralPath $soundPath -PathType Leaf) "$soundName must be included with the plugin."
        $soundBytes = [IO.File]::ReadAllBytes($soundPath)
        Assert-True ($soundBytes.Length -ge 44) "$soundName must contain a complete WAV header."
        Assert-Equal ([Text.Encoding]::ASCII.GetString($soundBytes, 0, 4)) "RIFF" "$soundName must be a RIFF WAV file."
        Assert-Equal ([Text.Encoding]::ASCII.GetString($soundBytes, 8, 4)) "WAVE" "$soundName must be a WAVE file."
        Assert-Equal ([BitConverter]::ToInt16($soundBytes, 20)) 1 "$soundName must use PCM encoding."
        Assert-Equal ([BitConverter]::ToInt16($soundBytes, 22)) 1 "$soundName must be mono."
        Assert-Equal ([BitConverter]::ToInt32($soundBytes, 24)) 44100 "$soundName must use a 44.1 kHz sample rate."
        Assert-Equal ([BitConverter]::ToInt16($soundBytes, 34)) 16 "$soundName must use 16-bit samples."
        $soundPlayer = New-Object System.Media.SoundPlayer $soundPath
        $soundPlayer.Load()
    }

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
        session_name = "codex-named-session"
    } | ConvertTo-Json -Compress
    $codexNamedResult = Invoke-NotifierDryRun $codexNamedPayload "TurnComplete"
    Assert-ProcessSucceeded $codexNamedResult "Named Codex session should succeed."
    $codexNamed = $codexNamedResult.Stdout | ConvertFrom-Json
    Assert-Equal $codexNamed.session_name "Notifs" "Codex notifications should show the latest session name, not the session ID."

    $codexDatabaseNamedPayload = $codexNamedPayload -replace "codex-named-session", "codex-db-named-session"
    $codexDatabaseNamedResult = Invoke-NotifierDryRun $codexDatabaseNamedPayload "TurnComplete"
    Assert-ProcessSucceeded $codexDatabaseNamedResult "Database-named Codex session should succeed."
    $codexDatabaseNamed = $codexDatabaseNamedResult.Stdout | ConvertFrom-Json
    Assert-Equal $codexDatabaseNamed.session_name "Database renamed session" "Codex notifications should use the current database rename."

    $codexDatabaseTitlePayload = $codexNamedPayload -replace "codex-named-session", "codex-db-titled-session"
    $codexDatabaseTitleResult = Invoke-NotifierDryRun $codexDatabaseTitlePayload "TurnComplete"
    Assert-ProcessSucceeded $codexDatabaseTitleResult "Automatically titled Codex session should succeed."
    $codexDatabaseTitle = $codexDatabaseTitleResult.Stdout | ConvertFrom-Json
    Assert-Equal $codexDatabaseTitle.session_name "Automatically generated session title" "Unnamed Codex sessions should use the current resume-picker title."

    $codexRolloutSessionId = "codex-rollout-session"
    @(
        (@{ type = "session_meta"; payload = @{ session_id = $codexRolloutSessionId } } | ConvertTo-Json -Compress),
        (@{ type = "event_msg"; payload = @{ type = "user_message"; message = "<user_message>Resume picker label" } } | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath (Join-Path $codexRolloutDirectory "rollout-2026-08-05T12-00-00-$codexRolloutSessionId.jsonl") -Encoding UTF8
    $codexRolloutPayload = $codexNamedPayload -replace "codex-named-session", $codexRolloutSessionId
    $codexRolloutResult = Invoke-NotifierDryRun $codexRolloutPayload "TurnComplete"
    Assert-ProcessSucceeded $codexRolloutResult "Codex rollout session should succeed."
    $codexRollout = $codexRolloutResult.Stdout | ConvertFrom-Json
    Assert-Equal $codexRollout.session_name "Resume picker label" "Unnamed Codex sessions should use the resume-picker label."

    $unnamedCodexPayload = $codexNamedPayload -replace "codex-named-session", "codex-unnamed-session"
    $unnamedCodexResult = Invoke-NotifierDryRun $unnamedCodexPayload "TurnComplete"
    Assert-ProcessSucceeded $unnamedCodexResult "Unnamed Codex session should succeed."
    $unnamedCodex = $unnamedCodexResult.Stdout | ConvertFrom-Json
    Assert-Equal $unnamedCodex.session_name "codex-unnamed-session" "Codex sessions without persisted picker metadata should fall back to the session ID."

    Set-Content -LiteralPath (Join-Path $claudeSessionDirectory "4242.json") -Encoding UTF8 -Value (
        @{ pid = 4242; sessionId = "claude-named-session"; name = "tomas-c6"; nameSource = "derived" } | ConvertTo-Json -Compress
    )
    Set-Content -LiteralPath (Join-Path $claudeSessionDirectory "broken.json") -Encoding UTF8 -Value "not-json"
    $claudeNamedPayload = $codexNamedPayload -replace "codex-named-session", "claude-named-session"
    $claudeNamedResult = Invoke-NotifierDryRun $claudeNamedPayload "TurnComplete" "Claude"
    Assert-ProcessSucceeded $claudeNamedResult "Named Claude session should succeed."
    $claudeNamed = $claudeNamedResult.Stdout | ConvertFrom-Json
    Assert-Equal $claudeNamed.session_name "tomas-c6" "Claude notifications should show the session name, not the session ID."

    $claudeTitleSessionId = "claude-titled-session"
    @(
        (@{ type = "ai-title"; sessionId = $claudeTitleSessionId; aiTitle = "Old title" } | ConvertTo-Json -Compress),
        (@{ type = "agent-name"; sessionId = $claudeTitleSessionId; agentName = "Explicit session name" } | ConvertTo-Json -Compress),
        (@{ type = "ai-title"; sessionId = $claudeTitleSessionId; aiTitle = "Latest title" } | ConvertTo-Json -Compress)
    ) | Set-Content -LiteralPath (Join-Path $claudeProjectDirectory "$claudeTitleSessionId.jsonl") -Encoding UTF8
    $claudeTitlePayload = $codexNamedPayload -replace "codex-named-session", $claudeTitleSessionId
    $claudeTitleResult = Invoke-NotifierDryRun $claudeTitlePayload "TurnComplete" "Claude"
    Assert-ProcessSucceeded $claudeTitleResult "Claude transcript title should succeed."
    $claudeTitle = $claudeTitleResult.Stdout | ConvertFrom-Json
    Assert-Equal $claudeTitle.session_name "Explicit session name" "Claude notifications should prefer the latest explicit picker name over AI titles."

    $claudeAiTitleSessionId = "claude-ai-titled-session"
    (@{ type = "ai-title"; sessionId = $claudeAiTitleSessionId; aiTitle = "Claude picker title" } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath (Join-Path $claudeProjectDirectory "$claudeAiTitleSessionId.jsonl") -Encoding UTF8
    $claudeAiTitlePayload = $codexNamedPayload -replace "codex-named-session", $claudeAiTitleSessionId
    $claudeAiTitleResult = Invoke-NotifierDryRun $claudeAiTitlePayload "TurnComplete" "Claude"
    Assert-ProcessSucceeded $claudeAiTitleResult "Claude AI title should succeed."
    $claudeAiTitle = $claudeAiTitleResult.Stdout | ConvertFrom-Json
    Assert-Equal $claudeAiTitle.session_name "Claude picker title" "Claude notifications should use the AI picker title when no explicit name exists."

    $openCodePayload = [ordered]@{
        cwd = "C:\work\demo"
        hook_event_name = "Stop"
        last_assistant_message = "Done."
        session_id = "opencode-session"
        session_name = "OpenCode picker title"
    } | ConvertTo-Json -Compress
    $openCodeResult = Invoke-NotifierDryRun $openCodePayload "TurnComplete" "OpenCode"
    Assert-ProcessSucceeded $openCodeResult "OpenCode session title should succeed."
    $openCode = $openCodeResult.Stdout | ConvertFrom-Json
    Assert-Equal $openCode.session_name "OpenCode picker title" "OpenCode notifications should use the persisted session title."

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

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -ReferencedAssemblies "System.Windows.Forms.dll" -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition (
        Get-NotifierFocusTypeSource
    )
    . ([scriptblock]::Create((Get-NotifierFunctionSource "Get-WorkingDirectoryTitleSegments")))
    . ([scriptblock]::Create((Get-NotifierFunctionSource "Select-HostWindowByWorkingDirectory")))
    . ([scriptblock]::Create((Get-NotifierFunctionSource "Resolve-HostWindowByProcessIds")))
    . ([scriptblock]::Create((Get-NotifierFunctionSource "Get-HostWindowHandle")))
    . ([scriptblock]::Create((Get-NotifierFunctionSource "Get-StableWindowTitle")))
    . ([scriptblock]::Create((Get-NotifierFunctionSource "Get-OriginatingWindowHandle")))

    $weztermMainWindow = $null
    $weztermHelperWindow = $null
    try {
        $weztermMainWindow = New-Object Windows.Forms.Form
        $weztermMainWindow.Text = "current-wezterm-title"
        $weztermMainWindow.Show()
        $weztermHelperWindow = New-Object Windows.Forms.Form
        $weztermHelperWindow.Text = "wezterm-helper"
        $weztermHelperWindow.Owner = $weztermMainWindow
        $weztermHelperWindow.Show()
        [Windows.Forms.Application]::DoEvents()

        function script:Invoke-TestWezTerm {
            param($Command, $Subcommand, $FormatFlag, $Format)
            if ($Command -ne "cli" -or $FormatFlag -ne "--format" -or $Format -ne "json") {
                throw "Unexpected test WezTerm arguments."
            }
            if ($Subcommand -eq "list") {
                return (@{
                    pane_id = 42
                    workspace = "default"
                    window_title = "stale-pane-title"
                } | ConvertTo-Json -Compress)
            }
            if ($Subcommand -eq "list-clients") {
                return (@{
                    focused_pane_id = 42
                    workspace = "default"
                    pid = $PID
                } | ConvertTo-Json -Compress)
            }
            throw "Unexpected test WezTerm command '$Subcommand'."
        }

        $script:terminalIntegration = "wezterm"
        $script:sourcePaneId = "42"
        $script:weztermCli = "Invoke-TestWezTerm"
        Assert-Equal (Get-OriginatingWindowHandle) $weztermMainWindow.Handle (
            "A visible owned helper must not make one WezTerm app window ambiguous."
        )
    } finally {
        if ($weztermHelperWindow) {
            $weztermHelperWindow.Close()
            $weztermHelperWindow.Dispose()
        }
        if ($weztermMainWindow) {
            $weztermMainWindow.Close()
            $weztermMainWindow.Dispose()
        }
        Remove-Item Function:\Invoke-TestWezTerm -ErrorAction SilentlyContinue
    }

    $detachedHost = $null
    $workspaceWindow = $null
    $duplicateWorkspaceWindow = $null
    try {
        $detachedHost = Start-Process -FilePath (Join-Path $PSHOME "powershell.exe") -ArgumentList @(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30"
        ) -WindowStyle Hidden -PassThru
        $workspaceName = "notify-test-" + [guid]::NewGuid().ToString("N")
        $script:workingDirectory = Join-Path "C:\work" $workspaceName
        $script:hostProcessChain = @([pscustomobject]@{ pid = $detachedHost.Id; name = "powershell.exe" })
        $script:hostProcessFamilyHint = "vscode"
        $workspaceWindow = New-Object Windows.Forms.Form
        $workspaceWindow.Text = "$workspaceName - Visual Studio Code"
        $workspaceWindow.Show()
        [Windows.Forms.Application]::DoEvents()
        function script:Get-Process {
            param($Name, $ErrorAction)
            return [pscustomobject]@{ Id = $PID }
        }

        $resolvedHost = Get-HostWindowHandle
        Assert-Equal $resolvedHost $workspaceWindow.Handle (
            "A detached session with windowless ancestry should resolve a unique workspace window."
        )

        $duplicateWorkspaceWindow = New-Object Windows.Forms.Form
        $duplicateWorkspaceWindow.Text = "$workspaceName - Cursor"
        $duplicateWorkspaceWindow.Show()
        [Windows.Forms.Application]::DoEvents()
        Assert-Equal (Get-HostWindowHandle) ([IntPtr]::Zero) (
            "A detached session should not guess when multiple workspace windows match."
        )

        $duplicateWorkspaceWindow.Close()
        $duplicateWorkspaceWindow.Dispose()
        $duplicateWorkspaceWindow = $null

        $script:hostProcessFamilyHint = ""
        Assert-Equal (Get-HostWindowHandle) ([IntPtr]::Zero) (
            "A detached session without a host identity hint should not search unrelated app windows."
        )
    } finally {
        if ($duplicateWorkspaceWindow) {
            $duplicateWorkspaceWindow.Close()
            $duplicateWorkspaceWindow.Dispose()
        }
        if ($workspaceWindow) {
            $workspaceWindow.Close()
            $workspaceWindow.Dispose()
        }
        if ($detachedHost -and -not $detachedHost.HasExited) {
            Stop-Process -Id $detachedHost.Id -Force
        }
        Remove-Item Function:\Get-Process -ErrorAction SilentlyContinue
    }

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

    $backgroundEventReferences = Select-String -LiteralPath $notifier -Pattern "BackgroundComplete"
    Assert-Equal @($backgroundEventReferences).Count 0 "The notifier must not retain a background notification category."

    $openCodeNotifierText = Get-Content -Raw -LiteralPath $openCodeNotifier
    Assert-True ($openCodeNotifierText.Contains("if (info?.parentID || childSessions.has(sessionId)) return;")) "OpenCode must reject child sessions even when idle arrives before session metadata."
    Assert-True (-not $openCodeNotifierText.Contains("0.5.2")) "OpenCode must not resolve a stale, hard-coded Codex cache version."

    $forbiddenInternals = Select-String -LiteralPath $notifier -Pattern "transcript_path|internal_chat_message_metadata_passthrough|last-assistant-message"
    Assert-Equal @($forbiddenInternals).Count 0 "Notifier should not depend on unsupported Codex internals."

    $notifierText = Get-Content -Raw -LiteralPath $notifier
    Assert-True ($notifierText.Contains('player.PlaySync();')) "The audio thread must play the complete short sound before it exits."
    Assert-True ($notifierText.Contains('[NotifySound]::Play($soundPath)')) "The popup shown handler must start the dedicated audio thread."

    # Activation must never change the geometry of a window that is already on screen.
    # SwitchToThisWindow is undocumented and raises and restores unconditionally, so it stays banned
    # outright. A restore is allowed only for a minimized window, which has no on-screen geometry to
    # preserve, and only from the single helper that guards on IsIconic.
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
    $env:TERM_PROGRAM = $originalTermProgram
    $env:VSCODE_INJECTION = $originalVsCodeInjection
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = 0
