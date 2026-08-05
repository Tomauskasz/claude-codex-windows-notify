param(
    [ValidateSet("TurnComplete", "ApprovalRequested", "AttentionRequested", "TurnFailed")]
    [string]$Event = "TurnComplete",

    [ValidateSet("Codex", "Claude", "OpenCode")]
    [string]$ProductName = "Codex",

    [switch]$Worker,

    [switch]$DryRun,

    [string]$DataBase64
)

$ErrorActionPreference = "Stop"
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8WithoutBom
[Console]::OutputEncoding = $utf8WithoutBom
$OutputEncoding = [Console]::OutputEncoding

# The worker only learns its product once the notification payload is decoded, so a failure before
# that point must not put either product's name on the dialog.
$script:productLabel = if ($Worker) { "" } else { $ProductName }

function Write-WorkerFailure {
    param([string]$Message)

    $logPath = Join-Path $env:TEMP "claude-codex-windows-notify.log"
    $diagnostic = "[$([DateTime]::UtcNow.ToString('o'))] $Message"
    try {
        Add-Content -LiteralPath $logPath -Value $diagnostic -Encoding UTF8
    } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $caption = if ($script:productLabel) { "$($script:productLabel) notification error" } else { "Notification error" }
        $body = if ($script:productLabel) {
            "$($script:productLabel) notifications failed. See $logPath."
        } else {
            "The notification failed. See $logPath."
        }
        [Windows.Forms.MessageBox]::Show(
            $body,
            $caption,
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {}
}

trap {
    if ($Worker) {
        Write-WorkerFailure "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    } else {
        [Console]::Error.WriteLine($_.Exception.Message)
    }
    exit 1
}

function Get-RequiredString {
    param(
        $Object,
        [string]$Name
    )

    $value = if ($Object) { [string]$Object.$Name } else { "" }
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Hook payload field '$Name' must be a non-empty string."
    }
    return $value
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaximumTextElements
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    if ($MaximumTextElements -lt 4) {
        throw "MaximumTextElements must be at least 4."
    }

    $elementStarts = [Globalization.StringInfo]::ParseCombiningCharacters($Text)
    if ($elementStarts.Count -le $MaximumTextElements) {
        return $Text
    }

    $cutIndex = $elementStarts[$MaximumTextElements - 3]
    return $Text.Substring(0, $cutIndex) + "..."
}

function Normalize-DisplayPath {
    param([string]$Path)

    if ($Path.StartsWith("\\?\UNC\", [StringComparison]::OrdinalIgnoreCase)) {
        return "\\" + $Path.Substring(8)
    }
    if ($Path.StartsWith("\\?\", [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring(4)
    }
    return $Path
}

function Get-ClaudeSessionName {
    param([string]$SessionId)

    $configDirectory = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
    $sessionDirectory = Join-Path $configDirectory "sessions"
    if (Test-Path -LiteralPath $sessionDirectory) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sessionDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $record = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction Stop | ConvertFrom-Json
            } catch {
                continue
            }
            if ([string]$record.sessionId -eq $SessionId -and -not [string]::IsNullOrWhiteSpace([string]$record.name)) {
                return [string]$record.name
            }
        }
    }

    $projectsDirectory = Join-Path $configDirectory "projects"
    if (-not (Test-Path -LiteralPath $projectsDirectory)) {
        return ""
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $projectsDirectory -Filter "$SessionId.jsonl" -File -Recurse -ErrorAction SilentlyContinue)) {
        $name = ""
        $title = ""
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ([string]$record.sessionId -ne $SessionId) { continue }
            if ($record.type -eq "agent-name" -and -not [string]::IsNullOrWhiteSpace([string]$record.agentName)) {
                $name = [string]$record.agentName
            }
            if ($record.type -eq "ai-title" -and -not [string]::IsNullOrWhiteSpace([string]$record.aiTitle)) {
                $title = [string]$record.aiTitle
            }
        }
        if ($name) { return $name }
        if ($title) { return $title }
    }
    return ""
}

function Get-CodexSessionName {
    param([string]$SessionId)

    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
    $stateFiles = @(Get-ChildItem -LiteralPath $codexHome -Filter "state_*.sqlite" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -match '^state_(\d+)$' } |
        Sort-Object { [int]$_.BaseName.Substring(6) } -Descending)
    $stateNames = $null
    if ($stateFiles.Count -gt 0) {
        $stateNames = [NotifyCodexState]::ReadThreadNames($stateFiles[0].FullName, $SessionId)
        if ($stateNames -and -not [string]::IsNullOrWhiteSpace($stateNames.Name)) {
            return $stateNames.Name.Trim()
        }
    }

    $indexPath = Join-Path $codexHome "session_index.jsonl"
    if (Test-Path -LiteralPath $indexPath) {
        $name = ""
        foreach ($line in @(Get-Content -LiteralPath $indexPath -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ([string]$record.id -eq $SessionId -and -not [string]::IsNullOrWhiteSpace([string]$record.thread_name)) {
                $name = [string]$record.thread_name
            }
        }
        if ($name) { return $name }
    }

    if ($stateNames -and -not [string]::IsNullOrWhiteSpace($stateNames.Title)) {
        foreach ($line in @($stateNames.Title -split "\r?\n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                return $line.Trim()
            }
        }
    }

    $sessionsDirectory = Join-Path $codexHome "sessions"
    if (-not (Test-Path -LiteralPath $sessionsDirectory)) { return "" }
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionsDirectory -Filter "*-$SessionId.jsonl" -File -Recurse -ErrorAction SilentlyContinue)) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($record.type -ne "event_msg" -or $record.payload.type -ne "user_message") { continue }
            $message = [string]$record.payload.message
            $marker = "<user_message>"
            $markerIndex = $message.IndexOf($marker, [StringComparison]::Ordinal)
            if ($markerIndex -ge 0) { $message = $message.Substring($markerIndex + $marker.Length).Trim() }
            foreach ($messageLine in @($message -split "\r?\n")) {
                if (-not [string]::IsNullOrWhiteSpace($messageLine)) { return $messageLine.Trim() }
            }
        }
    }
    return ""
}

function Resolve-SessionName {
    param([string]$SessionId)

    $name = switch ($ProductName) {
        "Claude" { Get-ClaudeSessionName $SessionId }
        "Codex" { Get-CodexSessionName $SessionId }
        default { "" }
    }

    if ([string]::IsNullOrWhiteSpace($name)) { return $SessionId }
    return $name.Trim()
}

# Session managers and shell infrastructure. Climbing past one of these leaves the terminal
# host behind, so the walk stops before it rather than focusing the desktop or a service host.
$processTreeBoundaryNames = @(
    "[system process]",
    "system",
    "csrss.exe",
    "dllhost.exe",
    "explorer.exe",
    "lsass.exe",
    "runtimebroker.exe",
    "services.exe",
    "sihost.exe",
    "smss.exe",
    "svchost.exe",
    "taskhostw.exe",
    "userinit.exe",
    "wininit.exe",
    "winlogon.exe"
)

# Walks from this process towards the terminal host and returns the candidate ancestors,
# nearest first. The chain must be captured here: the popup worker is detached, so by the time
# the user clicks, its own parent has already exited and the ancestry is no longer walkable.
function Get-HostProcessChain {
    param([int]$MaximumDepth = 12)

    $processes = @{}
    foreach ($row in [NotifyProcessTree]::Snapshot()) {
        $fields = $row.Split([char]"|", 3)
        if ($fields.Count -lt 3) {
            continue
        }
        $processId = 0
        $parentProcessId = 0
        if (-not [int]::TryParse($fields[0], [ref]$processId)) {
            continue
        }
        if (-not [int]::TryParse($fields[1], [ref]$parentProcessId)) {
            continue
        }
        $processes[$processId] = [pscustomobject]@{
            ProcessId       = $processId
            ParentProcessId = $parentProcessId
            Name            = $fields[2]
        }
    }

    $creationTimes = @{}
    function Get-CachedCreationTime {
        param([int]$ProcessId)

        if (-not $creationTimes.ContainsKey($ProcessId)) {
            $creationTimes[$ProcessId] = [NotifyProcessTree]::GetCreationTime($ProcessId)
        }
        return $creationTimes[$ProcessId]
    }

    $chain = @()
    $visited = @{}
    $current = $processes[[int]$PID]
    if (-not $current) {
        return $chain
    }
    $visited[$current.ProcessId] = $true

    while ($chain.Count -lt $MaximumDepth) {
        $parent = $processes[[int]$current.ParentProcessId]
        if (-not $parent) {
            break
        }
        if ($visited.ContainsKey($parent.ProcessId)) {
            break
        }
        if ($processTreeBoundaryNames -contains ([string]$parent.Name).ToLowerInvariant()) {
            break
        }

        # Windows recycles process IDs, so a parent ID can point at an unrelated process that
        # started after its claimed child. Reject that instead of focusing a stranger's window.
        $parentCreation = Get-CachedCreationTime $parent.ProcessId
        $currentCreation = Get-CachedCreationTime $current.ProcessId
        if ($parentCreation -lt 0 -or $currentCreation -lt 0 -or $parentCreation -gt $currentCreation) {
            break
        }

        $visited[$parent.ProcessId] = $true
        $chain += [pscustomobject]@{
            pid  = $parent.ProcessId
            name = $parent.Name
        }
        $current = $parent
    }

    return $chain
}

function Resolve-WezTermExecutable {
    if ($env:WEZTERM_EXECUTABLE_DIR) {
        $candidate = Join-Path $env:WEZTERM_EXECUTABLE_DIR "wezterm.exe"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $command = Get-Command wezterm.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "wezterm.exe was not found. Run $ProductName inside native Windows WezTerm."
}

function Get-HostProcessFamilyHint {
    if (
        [string]$env:TERM_PROGRAM -eq "vscode" -or
        [string]$env:VSCODE_INJECTION -eq "1"
    ) {
        return "vscode"
    }
    return ""
}

function Resolve-NotificationSound {
    param(
        [ValidateSet("TurnComplete", "ApprovalRequested", "AttentionRequested", "TurnFailed")]
        [string]$NotificationEvent
    )

    $soundFile = switch ($NotificationEvent) {
        "TurnComplete" { "complete.wav" }
        { $_ -in "ApprovalRequested", "AttentionRequested" } { "approval.wav" }
        "TurnFailed" { "failure.wav" }
    }
    $localSoundPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path "..\sounds" $soundFile)))
    if (Test-Path -LiteralPath $localSoundPath -PathType Leaf) {
        return $localSoundPath
    }

    $systemSoundPaths = switch ($NotificationEvent) {
        "TurnComplete" {
            @("C:\Windows\Media\Windows Notify Messaging.wav", "C:\Windows\Media\Windows Notify Email.wav")
        }
        { $_ -in "ApprovalRequested", "AttentionRequested" } {
            @("C:\Windows\Media\Windows Proximity Notification.wav", "C:\Windows\Media\Windows Message Nudge.wav")
        }
        "TurnFailed" {
            @("C:\Windows\Media\Windows Background.wav", "C:\Windows\Media\Windows Foreground.wav")
        }
    }
    foreach ($systemSoundPath in $systemSoundPaths) {
        if (Test-Path -LiteralPath $systemSoundPath -PathType Leaf) {
            return $systemSoundPath
        }
    }
    return $systemSoundPaths[0]
}

function New-NotificationData {
    param(
        $HookData,
        [string]$NotificationEvent
    )

    $expectedHookEvent = switch ($NotificationEvent) {
        "ApprovalRequested" { "PermissionRequest" }
        "AttentionRequested" { "Notification" }
        "TurnFailed" { "StopFailure" }
        default { "Stop" }
    }
    $actualHookEvent = Get-RequiredString $HookData "hook_event_name"
    if ($actualHookEvent -ne $expectedHookEvent) {
        throw "Expected a $expectedHookEvent hook payload, received '$actualHookEvent'."
    }

    $sessionId = Get-RequiredString $HookData "session_id"
    $workingDirectory = Normalize-DisplayPath (Get-RequiredString $HookData "cwd")
    if (-not [string]::IsNullOrWhiteSpace([string]$HookData.agent_id)) {
        return $null
    }
    if ($actualHookEvent -eq "SubagentStop") {
        return $null
    }
    if ($actualHookEvent -eq "Notification") {
        $notificationType = [string]$HookData.notification_type
        if ($notificationType -in @("agent_needs_input", "agent_completed")) {
            return $null
        }
    }
    $sessionName = [string]$HookData.session_name
    if ($ProductName -ne "OpenCode" -or [string]::IsNullOrWhiteSpace($sessionName)) {
        $sessionName = Resolve-SessionName $sessionId
    }
    $sourcePaneId = [string]$env:WEZTERM_PANE
    $terminalIntegration = if ([string]::IsNullOrWhiteSpace($sourcePaneId)) { "none" } else { "wezterm" }
    $weztermExecutable = if ($terminalIntegration -eq "wezterm") { Resolve-WezTermExecutable } else { "" }
    $weztermSocket = if ($terminalIntegration -eq "wezterm") { [string]$env:WEZTERM_UNIX_SOCKET } else { "" }
    $hostProcessFamilyHint = Get-HostProcessFamilyHint

    switch ($NotificationEvent) {
        "ApprovalRequested" {
            $toolName = Get-RequiredString $HookData "tool_name"
            if ($toolName -eq "AskUserQuestion") {
                $title = "$ProductName has a question"
                $questions = @($HookData.tool_input.questions)
                $message = if ($questions.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$questions[0].question)) {
                    [string]$questions[0].question
                } else {
                    "$ProductName is waiting for your answer."
                }
            } else {
                $title = "$ProductName needs you"
                $message = "Approval requested for $toolName."
            }
        }
        "AttentionRequested" {
            $title = [string]$HookData.title
            if ([string]::IsNullOrWhiteSpace($title)) { $title = "$ProductName needs you" }
            $message = Get-RequiredString $HookData "message"
        }
        "TurnFailed" {
            $title = "$ProductName failed"
            $message = [string]$HookData.last_assistant_message
            if ([string]::IsNullOrWhiteSpace($message)) {
                $errorType = Get-RequiredString $HookData "error"
                $message = "$ProductName stopped because of $errorType."
            }
        }
        default {
            $title = "$ProductName finished"
            $message = [string]$HookData.last_assistant_message
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = "$ProductName finished without a final response."
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($message)) {
        $message = $message.Trim()
    }
    $soundPath = Resolve-NotificationSound $NotificationEvent

    return [ordered]@{
        event                = $NotificationEvent
        product_name         = $ProductName
        session_id           = $sessionId
        title                = $title
        message              = Limit-Text $message 1000
        sound_path           = $soundPath
        session_name         = Limit-Text $sessionName 60
        working_directory    = Limit-Text $workingDirectory 500
        terminal_integration = $terminalIntegration
        source_pane_id       = $sourcePaneId
        wezterm_executable   = $weztermExecutable
        wezterm_socket       = $weztermSocket
        host_process_family_hint = $hostProcessFamilyHint
        host_process_chain   = @(Get-HostProcessChain)
    }
}

if ($Worker) {
    if ([string]::IsNullOrWhiteSpace($DataBase64)) {
        throw "DataBase64 is required in worker mode."
    }
    $notificationData = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($DataBase64)
    ) | ConvertFrom-Json
    $script:productLabel = [string]$notificationData.product_name
} else {
    $payload = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($payload)) {
        throw "$ProductName hook payload was empty."
    }
    $payload = $payload.TrimStart([char]0xFEFF)

    try {
        $hookData = $payload | ConvertFrom-Json
    } catch {
        throw "$ProductName hook payload was not valid JSON: $($_.Exception.Message)"
    }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public sealed class NotifyCodexSessionNames
{
    public string Name { get; private set; }
    public string Title { get; private set; }

    public NotifyCodexSessionNames(string name, string title)
    {
        Name = name ?? "";
        Title = title ?? "";
    }
}

public static class NotifyCodexState
{
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const int SQLITE_OPEN_READONLY = 0x00000001;
    private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(IntPtr filename, out IntPtr database, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr database, int milliseconds);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr database, IntPtr sql, int byteCount, out IntPtr statement, out IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr statement, int index, IntPtr value, int byteCount, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr database);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr statement);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr database);

    private static IntPtr Utf8(string value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value + "\0");
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        return pointer;
    }

    private static string Utf8String(IntPtr pointer, int byteCount)
    {
        if (pointer == IntPtr.Zero || byteCount <= 0)
        {
            return "";
        }
        byte[] bytes = new byte[byteCount];
        Marshal.Copy(pointer, bytes, 0, byteCount);
        return Encoding.UTF8.GetString(bytes);
    }

    private static string Utf8String(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
        {
            return "";
        }
        int byteCount = 0;
        while (Marshal.ReadByte(pointer, byteCount) != 0)
        {
            byteCount++;
        }
        return Utf8String(pointer, byteCount);
    }

    private static InvalidOperationException Failure(IntPtr database, string operation, int result)
    {
        string detail = database == IntPtr.Zero ? "database unavailable" : Utf8String(sqlite3_errmsg(database));
        return new InvalidOperationException("Codex session-name lookup could not " + operation +
            " (SQLite result " + result + "): " + detail);
    }

    public static NotifyCodexSessionNames ReadThreadNames(string path, string sessionId)
    {
        IntPtr pathPointer = Utf8(path);
        IntPtr database = IntPtr.Zero;
        try
        {
            int result = sqlite3_open_v2(pathPointer, out database, SQLITE_OPEN_READONLY, IntPtr.Zero);
            if (result != SQLITE_OK)
            {
                throw Failure(database, "open the state database", result);
            }
            sqlite3_busy_timeout(database, 1000);

            IntPtr sqlPointer = Utf8("SELECT name, title FROM threads WHERE id = ?1 LIMIT 1");
            IntPtr statement = IntPtr.Zero;
            try
            {
                IntPtr tail;
                result = sqlite3_prepare_v2(database, sqlPointer, -1, out statement, out tail);
                if (result != SQLITE_OK)
                {
                    throw Failure(database, "prepare the session query", result);
                }

                IntPtr sessionPointer = Utf8(sessionId);
                try
                {
                    result = sqlite3_bind_text(statement, 1, sessionPointer, -1, SQLITE_TRANSIENT);
                }
                finally
                {
                    Marshal.FreeHGlobal(sessionPointer);
                }
                if (result != SQLITE_OK)
                {
                    throw Failure(database, "bind the session ID", result);
                }

                result = sqlite3_step(statement);
                if (result == SQLITE_DONE)
                {
                    return null;
                }
                if (result != SQLITE_ROW)
                {
                    throw Failure(database, "read the session record", result);
                }
                string name = Utf8String(sqlite3_column_text(statement, 0), sqlite3_column_bytes(statement, 0));
                string title = Utf8String(sqlite3_column_text(statement, 1), sqlite3_column_bytes(statement, 1));
                return new NotifyCodexSessionNames(name, title);
            }
            finally
            {
                if (statement != IntPtr.Zero) sqlite3_finalize(statement);
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

public static class NotifyDetachedProcess
{
private const uint CREATE_NO_WINDOW = 0x08000000;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
private struct StartupInfo
{
    public int cb;
    public string reserved;
    public string desktop;
    public string title;
    public int x;
    public int y;
    public int xSize;
    public int ySize;
    public int xCountChars;
    public int yCountChars;
    public int fillAttribute;
    public int flags;
    public short showWindow;
    public short reserved2Size;
    public IntPtr reserved2;
    public IntPtr standardInput;
    public IntPtr standardOutput;
    public IntPtr standardError;
}

[StructLayout(LayoutKind.Sequential)]
private struct ProcessInformation
{
    public IntPtr process;
    public IntPtr thread;
    public int processId;
    public int threadId;
}

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern bool CreateProcess(
    string applicationName,
    StringBuilder commandLine,
    IntPtr processAttributes,
    IntPtr threadAttributes,
    bool inheritHandles,
    uint creationFlags,
    IntPtr environment,
    string currentDirectory,
    ref StartupInfo startupInfo,
    out ProcessInformation processInformation);

[DllImport("kernel32.dll")]
private static extern bool CloseHandle(IntPtr handle);

public static void Start(string executable, string arguments)
{
    StartupInfo startupInfo = new StartupInfo();
    startupInfo.cb = Marshal.SizeOf(startupInfo);
    ProcessInformation processInformation;
    StringBuilder commandLine = new StringBuilder("\"" + executable + "\" " + arguments);

    if (!CreateProcess(
        executable,
        commandLine,
        IntPtr.Zero,
        IntPtr.Zero,
        false,
        CREATE_NO_WINDOW,
        IntPtr.Zero,
        null,
        ref startupInfo,
        out processInformation))
    {
        throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    CloseHandle(processInformation.thread);
    CloseHandle(processInformation.process);
}
}

public static class NotifyProcessTree
{
private const uint TH32CS_SNAPPROCESS = 0x00000002;
private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
private struct ProcessEntry32
{
    public int size;
    public int usage;
    public int processId;
    public IntPtr defaultHeapId;
    public int moduleId;
    public int threadCount;
    public int parentProcessId;
    public int priorityClassBase;
    public int flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string executableFile;
}

[DllImport("kernel32.dll", SetLastError = true)]
private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry32 entry);

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry32 entry);

[DllImport("kernel32.dll", SetLastError = true)]
private static extern bool CloseHandle(IntPtr handle);

[DllImport("kernel32.dll", SetLastError = true)]
private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

[DllImport("kernel32.dll", SetLastError = true)]
private static extern bool GetProcessTimes(
    IntPtr process,
    out long creation,
    out long exit,
    out long kernel,
    out long user);

// Each row is "processId|parentProcessId|executableName".
public static string[] Snapshot()
{
    // CreateToolhelp32Snapshot is documented to fail with ERROR_BAD_LENGTH while the process
    // list is changing under it, and to be worth retrying when it does.
    const int ERROR_BAD_LENGTH = 24;
    IntPtr snapshot = new IntPtr(-1);
    int lastError = 0;
    for (int attempt = 0; attempt < 4; attempt++)
    {
        snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot != new IntPtr(-1))
        {
            break;
        }
        lastError = Marshal.GetLastWin32Error();
        if (lastError != ERROR_BAD_LENGTH)
        {
            break;
        }
    }
    if (snapshot == new IntPtr(-1))
    {
        throw new Win32Exception(lastError);
    }

    try
    {
        List<string> rows = new List<string>();
        ProcessEntry32 entry = new ProcessEntry32();
        entry.size = Marshal.SizeOf(typeof(ProcessEntry32));
        if (Process32FirstW(snapshot, ref entry))
        {
            do
            {
                rows.Add(entry.processId + "|" + entry.parentProcessId + "|" + entry.executableFile);
            }
            while (Process32NextW(snapshot, ref entry));
        }
        return rows.ToArray();
    }
    finally
    {
        CloseHandle(snapshot);
    }
}

// Returns the process creation time as a FILETIME tick count, or -1 when it cannot be read.
public static long GetCreationTime(int processId)
{
    IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
    if (process == IntPtr.Zero)
    {
        return -1;
    }

    try
    {
        long creation;
        long exit;
        long kernel;
        long user;
        if (!GetProcessTimes(process, out creation, out exit, out kernel, out user))
        {
            return -1;
        }
        return creation;
    }
    finally
    {
        CloseHandle(process);
    }
}
}

'@

    $notificationData = New-NotificationData $hookData $Event
    if ($null -eq $notificationData) {
        if ($DryRun) {
            [ordered]@{ skipped = $true; reason = "subagent" } | ConvertTo-Json -Compress
        }
        return
    }
    if ($DryRun) {
        $notificationData | ConvertTo-Json -Depth 5
        return
    }

    $dataJson = $notificationData | ConvertTo-Json -Compress -Depth 5
    $encodedData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dataJson))
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        $PSCommandPath + '" -Worker -DataBase64 ' + $encodedData

    [NotifyDetachedProcess]::Start((Join-Path $PSHOME "powershell.exe"), $arguments)
    return
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies "System.Windows.Forms.dll" -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public sealed class NotifyPopupForm : Form
{
    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_TOOLWINDOW = 0x00000080;
            const int CS_DROPSHADOW = 0x00020000;
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= WS_EX_TOOLWINDOW;
            parameters.ClassStyle |= CS_DROPSHADOW;
            return parameters;
        }
    }
}

public static class NotifySound
{
    public static void Play(string path)
    {
        Thread soundThread = new Thread(delegate()
        {
            try
            {
                using (SoundPlayer player = new SoundPlayer(path))
                {
                    player.Load();
                    player.PlaySync();
                }
            }
            catch
            {
                SystemSounds.Asterisk.Play();
            }
        });
        soundThread.IsBackground = true;
        soundThread.Name = "Notification sound";
        soundThread.Start();
    }
}

public static class NotifyWindowFocus
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr window, int command);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr SetFocus(IntPtr window);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint firstThread, uint secondThread, bool attach);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr window, int index);

    private const uint GW_OWNER = 4;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const int SW_RESTORE = 9;

    // Windows a user can actually switch to: visible, unowned, not a tool window, and titled.
    // GUI hosts can own hidden, untitled, tool, or owned helper windows that would otherwise make
    // one real application window look ambiguous.
    public static IntPtr[] GetAppWindows(uint processId)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId != processId || !IsWindowVisible(window))
            {
                return true;
            }
            if (GetWindow(window, GW_OWNER) != IntPtr.Zero)
            {
                return true;
            }
            if ((GetWindowLong(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0)
            {
                return true;
            }
            if (GetWindowTitle(window).Trim().Length == 0)
            {
                return true;
            }
            windows.Add(window);
            return true;
        }, IntPtr.Zero);
        return windows.ToArray();
    }

    public static string GetWindowTitle(IntPtr window)
    {
        StringBuilder title = new StringBuilder(512);
        GetWindowText(window, title, title.Capacity);
        return title.ToString();
    }

    // A minimized window cannot be raised by activation alone: Windows reports the activation as
    // successful while the window stays in the taskbar, so the click appears to do nothing.
    // Restoring is the only way to show it, and is applied ONLY when the window is minimized. A
    // window that is already on screen is never touched, so a normal, maximized, or snapped window
    // keeps its exact geometry. A minimized window has no on-screen geometry to preserve, and
    // Windows returns it to the placement it had before it was minimized.
    private static void RestoreIfMinimized(IntPtr window)
    {
        if (IsIconic(window))
        {
            ShowWindowAsync(window, SW_RESTORE);
        }
    }

    public static bool ActivateWindow(IntPtr window)
    {
        if (window == IntPtr.Zero)
        {
            return false;
        }

        RestoreIfMinimized(window);
        IntPtr foregroundWindow = GetForegroundWindow();
        uint ignoredProcessId;
        uint foregroundThread = GetWindowThreadProcessId(foregroundWindow, out ignoredProcessId);
        uint targetThread = GetWindowThreadProcessId(window, out ignoredProcessId);
        uint currentThread = GetCurrentThreadId();
        bool attachedForeground = foregroundThread != 0 && foregroundThread != currentThread &&
            AttachThreadInput(currentThread, foregroundThread, true);
        bool attachedTarget = targetThread != 0 && targetThread != currentThread && targetThread != foregroundThread &&
            AttachThreadInput(currentThread, targetThread, true);

        try
        {
            BringWindowToTop(window);
            SetForegroundWindow(window);
            SetFocus(window);
            return GetForegroundWindow() == window;
        }
        finally
        {
            if (attachedTarget)
            {
                AttachThreadInput(currentThread, targetThread, false);
            }
            if (attachedForeground)
            {
                AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
    }
}


'@

[NotifyWindowFocus]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$Event = [string]$notificationData.event
$title = [string]$notificationData.title
$message = [string]$notificationData.message
$soundPath = [string]$notificationData.sound_path
$sessionName = [string]$notificationData.session_name
$sessionId = [string]$notificationData.session_id
if ([string]::IsNullOrWhiteSpace($sessionName)) {
    $sessionName = Resolve-SessionName $sessionId
}
$workingDirectory = [string]$notificationData.working_directory
$terminalIntegration = [string]$notificationData.terminal_integration
$sourcePaneId = [string]$notificationData.source_pane_id
$weztermCli = [string]$notificationData.wezterm_executable
$hostProcessFamilyHint = [string]$notificationData.host_process_family_hint
$hostProcessChain = @()
if ($notificationData.host_process_chain) {
    $hostProcessChain = @($notificationData.host_process_chain)
}
if ($terminalIntegration -eq "wezterm" -and $notificationData.wezterm_socket) {
    $env:WEZTERM_UNIX_SOCKET = [string]$notificationData.wezterm_socket
}

function Get-StableWindowTitle {
    param([string]$Title)

    $stableTitle = $Title.Trim()
    while ($stableTitle.Length -gt 0) {
        $firstCharacter = [int][char]$stableTitle[0]
        if ($firstCharacter -lt 0x2800 -or $firstCharacter -gt 0x28FF) {
            break
        }
        $stableTitle = $stableTitle.Substring(1).TrimStart()
    }
    return $stableTitle
}

function Get-OriginatingWindowHandle {
    if ($terminalIntegration -ne "wezterm" -or -not $sourcePaneId -or -not $weztermCli) {
        return [IntPtr]::Zero
    }

    $panes = @(& $weztermCli cli list --format json 2>$null | ConvertFrom-Json | ForEach-Object { $_ })
    $sourcePane = $panes | Where-Object { [string]$_.pane_id -eq [string]$sourcePaneId } | Select-Object -First 1
    if (-not $sourcePane) {
        return [IntPtr]::Zero
    }

    $clients = @(& $weztermCli cli list-clients --format json 2>$null | ConvertFrom-Json | ForEach-Object { $_ })
    $candidateClients = @($clients | Where-Object {
        [string]$_.focused_pane_id -eq [string]$sourcePaneId
    })
    if ($candidateClients.Count -eq 0) {
        $candidateClients = @($clients | Where-Object {
            [string]$_.workspace -eq [string]$sourcePane.workspace
        })
    }
    if ($candidateClients.Count -eq 0) {
        return [IntPtr]::Zero
    }

    $candidateProcessIds = @($candidateClients | ForEach-Object {
        [uint32]$_.pid
    } | Sort-Object -Unique)
    $windowHandles = @($candidateProcessIds | ForEach-Object {
        [NotifyWindowFocus]::GetAppWindows($_)
    })
    if ($windowHandles.Count -eq 0) {
        return [IntPtr]::Zero
    }

    $exactMatches = @($windowHandles | Where-Object {
        [NotifyWindowFocus]::GetWindowTitle($_) -eq [string]$sourcePane.window_title
    })
    if ($exactMatches.Count -eq 1) {
        return [IntPtr]$exactMatches[0]
    }

    $stableSourceTitle = Get-StableWindowTitle ([string]$sourcePane.window_title)
    $stableMatches = @($windowHandles | Where-Object {
        (Get-StableWindowTitle ([NotifyWindowFocus]::GetWindowTitle($_))) -eq $stableSourceTitle
    })
    if ($stableMatches.Count -eq 1) {
        return [IntPtr]$stableMatches[0]
    }

    if ($windowHandles.Count -eq 1) {
        return [IntPtr]$windowHandles[0]
    }

    return [IntPtr]::Zero
}

# Directory names that can plausibly appear in a host window title, deepest first. Editors title
# their windows after the workspace folder, so the leaf of a deeper cwd is tried first and the walk
# stops at the profile directory or drive root to avoid matching on "Users" or a drive letter.
function Get-WorkingDirectoryTitleSegments {
    param([string]$Path)

    $segments = @()
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $segments
    }

    $boundaries = @()
    if ($env:USERPROFILE) {
        $boundaries += $env:USERPROFILE.TrimEnd([char]"\", [char]"/")
    }
    try {
        $boundaries += ([string][IO.Path]::GetPathRoot($Path)).TrimEnd([char]"\", [char]"/")
    } catch {}

    $current = $Path.TrimEnd([char]"\", [char]"/")
    while ($segments.Count -lt 6 -and -not [string]::IsNullOrWhiteSpace($current)) {
        $atBoundary = @($boundaries | Where-Object {
            $_ -and $current.Equals($_, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($atBoundary) {
            break
        }

        $leaf = Split-Path -Leaf $current
        if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf.Length -lt 2 -or $leaf -eq $current) {
            break
        }
        $segments += $leaf

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent.TrimEnd([char]"\", [char]"/")
    }

    return $segments
}

function Select-HostWindowByWorkingDirectory {
    param($Windows)

    foreach ($segment in @(Get-WorkingDirectoryTitleSegments $workingDirectory)) {
        $titleMatches = @($Windows | Where-Object {
            [NotifyWindowFocus]::GetWindowTitle($_).IndexOf($segment, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        if ($titleMatches.Count -eq 1) {
            return [IntPtr]$titleMatches[0]
        }
    }
    return [IntPtr]::Zero
}

function Resolve-HostWindowByProcessIds {
    param($ProcessIds)

    $windows = @($ProcessIds | Sort-Object -Unique | ForEach-Object {
        [NotifyWindowFocus]::GetAppWindows([uint32]$_)
    })
    $windows = @($windows | Sort-Object -Unique)
    return [pscustomobject]@{
        has_windows = $windows.Count -gt 0
        handle      = Select-HostWindowByWorkingDirectory $windows
    }
}

# Prefer normal process ancestry. Detached background sessions can retain their VS Code family
# identity after their ancestry loses the editor, so use that broader hint only when no ancestor
# owns a switchable window.
function Get-HostWindowHandle {
    foreach ($entry in $hostProcessChain) {
        $processId = 0
        if (-not [int]::TryParse([string]$entry.pid, [ref]$processId)) {
            continue
        }

        $windows = @([NotifyWindowFocus]::GetAppWindows([uint32]$processId))
        if ($windows.Count -eq 0) {
            continue
        }
        if ($windows.Count -eq 1) {
            return [IntPtr]$windows[0]
        }

        # One editor instance shares a single pty host across all of its windows, so ancestry
        # cannot say which window holds this terminal. Fall back to the workspace name.
        return (Select-HostWindowByWorkingDirectory $windows)
    }

    if ($hostProcessFamilyHint -eq "vscode") {
        $hintedProcessIds = @(Get-Process -Name @("Code", "Code - Insiders", "Cursor", "VSCodium") `
            -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        $hintedResult = Resolve-HostWindowByProcessIds $hintedProcessIds
        if ($hintedResult.has_windows) {
            return [IntPtr]$hintedResult.handle
        }
    }
    return [IntPtr]::Zero
}

function Show-OriginatingHostWindow {
    if ($hostProcessChain.Count -eq 0) {
        throw "The process ancestry of the originating session is unavailable."
    }

    $windowHandle = Get-HostWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw "The window of the app hosting this session could not be identified unambiguously."
    }
    if (-not [NotifyWindowFocus]::ActivateWindow($windowHandle)) {
        throw "Windows refused to focus the app hosting this session."
    }
}

function Show-OriginatingPane {
    if (-not $sourcePaneId -or -not $weztermCli) {
        throw "The originating WezTerm pane context is unavailable."
    }

    & $weztermCli cli activate-pane --pane-id $sourcePaneId 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "WezTerm could not activate pane $sourcePaneId."
    }

    $windowHandle = Get-OriginatingWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) {
        throw "The WezTerm window for pane $sourcePaneId could not be identified unambiguously."
    }
    if (-not [NotifyWindowFocus]::ActivateWindow($windowHandle)) {
        throw "Windows refused to focus the WezTerm window for pane $sourcePaneId."
    }
}

$form = New-Object NotifyPopupForm
$form.Text = $title
$form.AccessibleName = $title
$form.AccessibleDescription = $message
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.BackColor = [Drawing.Color]::FromArgb(24, 24, 37)
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object Drawing.Size(720, 140)
$form.StartPosition = [Windows.Forms.FormStartPosition]::Manual

$originatingWindow = if ($terminalIntegration -eq "wezterm") {
    Get-OriginatingWindowHandle
} else {
    Get-HostWindowHandle
}
$screen = if ($originatingWindow -ne [IntPtr]::Zero) {
    [Windows.Forms.Screen]::FromHandle($originatingWindow).WorkingArea
} else {
    [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
}
if ($screen.Width -lt 720) {
    $primaryScreen = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($primaryScreen.Width -gt $screen.Width) {
        $screen = $primaryScreen
    }
}
$cardWidth = [Math]::Min(720, ($screen.Width - 36))
$form.ClientSize = New-Object Drawing.Size($cardWidth, 140)
$form.Location = New-Object Drawing.Point(
    ($screen.Right - $form.Width - 18),
    ($screen.Bottom - $form.Height - 18)
)

$accentColor = switch ($Event) {
    { $_ -in "ApprovalRequested", "AttentionRequested" } { [Drawing.Color]::FromArgb(249, 226, 175) }
    "TurnFailed" { [Drawing.Color]::FromArgb(243, 139, 168) }
    default { [Drawing.Color]::FromArgb(166, 227, 161) }
}

$icon = New-Object Windows.Forms.Label
$icon.AutoSize = $false
$icon.Location = New-Object Drawing.Point(14, 14)
$icon.Size = New-Object Drawing.Size(42, 42)
$icon.BackColor = $accentColor
$icon.ForeColor = [Drawing.Color]::FromArgb(24, 24, 37)
$icon.Font = New-Object Drawing.Font("Segoe UI Symbol", 18, [Drawing.FontStyle]::Bold)
$icon.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$icon.Text = switch ($Event) {
    { $_ -in "ApprovalRequested", "AttentionRequested" } { "!" }
    "TurnFailed" { [char]0x00D7 }
    default { [char]0x2713 }
}
$form.Controls.Add($icon)

$titleLabel = New-Object Windows.Forms.Label
$titleLabel.AutoSize = $false
$titleLabel.Location = New-Object Drawing.Point(68, 9)
$titleLabel.Size = New-Object Drawing.Size(($cardWidth - 140), 32)
$titleLabel.Font = New-Object Drawing.Font("Segoe UI Semibold", 14)
$titleLabel.ForeColor = [Drawing.Color]::FromArgb(205, 214, 244)
$titleLabel.Text = $title
$form.Controls.Add($titleLabel)

$sessionLabel = New-Object Windows.Forms.Label
$sessionLabel.AutoSize = $false
$sessionLabel.Location = New-Object Drawing.Point(68, 38)
$sessionLabel.Size = New-Object Drawing.Size(($cardWidth - 140), 22)
$sessionLabel.Font = New-Object Drawing.Font("Segoe UI Semibold", 10.5)
$sessionLabel.ForeColor = [Drawing.Color]::FromArgb(180, 190, 254)
$sessionLabel.AutoEllipsis = $true
$sessionLabel.Text = $sessionName
$form.Controls.Add($sessionLabel)

$workingDirectoryLabel = New-Object Windows.Forms.Label
$workingDirectoryLabel.AutoSize = $false
$workingDirectoryLabel.Location = New-Object Drawing.Point(68, 59)
$workingDirectoryLabel.Size = New-Object Drawing.Size(($cardWidth - 82), 20)
$workingDirectoryLabel.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$workingDirectoryLabel.ForeColor = [Drawing.Color]::FromArgb(147, 153, 178)
$workingDirectoryLabel.AutoEllipsis = $true
$workingDirectoryLabel.Text = $workingDirectory
$form.Controls.Add($workingDirectoryLabel)

$closeButton = New-Object Windows.Forms.Label
$closeButton.AutoSize = $false
$closeButton.Location = New-Object Drawing.Point(($cardWidth - 46), 7)
$closeButton.Size = New-Object Drawing.Size(34, 34)
$closeButton.Font = New-Object Drawing.Font("Segoe UI", 16)
$closeButton.ForeColor = [Drawing.Color]::FromArgb(127, 132, 156)
$closeButton.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$closeButton.Text = [char]0x00D7
$closeButton.Cursor = [Windows.Forms.Cursors]::Hand
$closeButton.AccessibleName = "Dismiss notification"
$form.Controls.Add($closeButton)

$messageLabel = New-Object Windows.Forms.Label
$messageLabel.AutoSize = $true
$messageLabel.Location = New-Object Drawing.Point(14, 87)
$messageLabel.Font = New-Object Drawing.Font("Segoe UI", 11.25)
$messageLabel.ForeColor = [Drawing.Color]::FromArgb(205, 214, 244)
$messageLabel.AutoEllipsis = $true
$messageLabel.TextAlign = [Drawing.ContentAlignment]::TopLeft
$messageLabel.Text = $message
$messageWidth = $cardWidth - 28
$messageLabel.MaximumSize = New-Object Drawing.Size($messageWidth, 1600)
$messageHeight = $messageLabel.GetPreferredSize((New-Object Drawing.Size($messageWidth, 1600))).Height
$maximumMessageHeight = [Math]::Max(120, [Math]::Min(480, ($screen.Height - 130)))
$messageHeight = [Math]::Max(25, [Math]::Min($maximumMessageHeight, $messageHeight + 12))
$messageLabel.Size = New-Object Drawing.Size($messageWidth, $messageHeight)
$form.Controls.Add($messageLabel)

$form.ClientSize = New-Object Drawing.Size($cardWidth, (101 + $messageHeight))

$form.Location = New-Object Drawing.Point(
    ($screen.Right - $form.Width - 18),
    ($screen.Bottom - $form.Height - 18)
)

$cornerDiameter = 18
$cardPath = New-Object Drawing.Drawing2D.GraphicsPath
$cardPath.AddArc(0, 0, $cornerDiameter, $cornerDiameter, 180, 90)
$cardPath.AddArc(($form.Width - $cornerDiameter - 1), 0, $cornerDiameter, $cornerDiameter, 270, 90)
$cardPath.AddArc(($form.Width - $cornerDiameter - 1), ($form.Height - $cornerDiameter - 1), $cornerDiameter, $cornerDiameter, 0, 90)
$cardPath.AddArc(0, ($form.Height - $cornerDiameter - 1), $cornerDiameter, $cornerDiameter, 90, 90)
$cardPath.CloseFigure()
$form.Region = New-Object Drawing.Region($cardPath)

$iconPath = New-Object Drawing.Drawing2D.GraphicsPath
$iconPath.AddEllipse(0, 0, $icon.Width, $icon.Height)
$icon.Region = New-Object Drawing.Region($iconPath)

$form.Add_Paint({
    param($sender, $paintEvent)
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(69, 71, 90), 1)
    $paintEvent.Graphics.DrawPath($pen, $cardPath)
    $pen.Dispose()
})

$activatePopup = {
    $timer.Stop()
    try {
        if ($terminalIntegration -eq "wezterm") {
            Show-OriginatingPane
        } else {
            Show-OriginatingHostWindow
        }
        $form.Hide()
        $form.Close()
    } catch {
        Write-WorkerFailure $_.Exception.Message
        $timer.Start()
    }
}
$dismissPopup = { $timer.Stop(); $form.Close() }
$canFocusOrigin = ($terminalIntegration -eq "wezterm") -or ($hostProcessChain.Count -gt 0)
$primaryClick = if ($canFocusOrigin) { $activatePopup } else { $dismissPopup }
$hoverOn = { $form.BackColor = [Drawing.Color]::FromArgb(30, 30, 46); $timer.Stop() }
$hoverOff = { $form.BackColor = [Drawing.Color]::FromArgb(24, 24, 37); $timer.Start() }

foreach ($control in @($form, $icon, $titleLabel, $sessionLabel, $workingDirectoryLabel, $messageLabel)) {
    $control.Cursor = [Windows.Forms.Cursors]::Hand
    $control.Add_Click($primaryClick)
    $control.Add_MouseEnter($hoverOn)
    $control.Add_MouseLeave($hoverOff)
}
$closeButton.Add_Click($dismissPopup)
$closeButton.Add_MouseEnter({ $closeButton.ForeColor = $accentColor })
$closeButton.Add_MouseLeave({ $closeButton.ForeColor = [Drawing.Color]::FromArgb(127, 132, 156) })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 10000
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
$timer.Start()

$form.Add_Shown({
    if (-not [string]::IsNullOrWhiteSpace($soundPath) -and (Test-Path -LiteralPath $soundPath)) {
        [NotifySound]::Play($soundPath)
    } else {
        [System.Media.SystemSounds]::Asterisk.Play()
    }
})
$form.Show()
[NotifyWindowFocus]::ShowWindowAsync($form.Handle, 4) | Out-Null
$form.Add_FormClosed({ [Windows.Forms.Application]::ExitThread() })
[Windows.Forms.Application]::Run()
