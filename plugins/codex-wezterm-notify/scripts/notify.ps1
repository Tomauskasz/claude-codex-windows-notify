param(
    [ValidateSet("TurnComplete", "ApprovalRequested")]
    [string]$Event = "TurnComplete",

    [switch]$Worker,

    [switch]$DryRun,

    [string]$DataBase64
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

function Write-WorkerFailure {
    param([string]$Message)

    $diagnostic = "[$([DateTime]::UtcNow.ToString('o'))] $Message"
    try {
        Add-Content -LiteralPath (Join-Path $env:TEMP "codex-wezterm-notify.log") -Value $diagnostic -Encoding UTF8
    } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show(
            "Codex WezTerm Notify failed. See $env:TEMP\codex-wezterm-notify.log.",
            "Codex notification error",
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

    throw "wezterm.exe was not found. Run Codex inside native Windows WezTerm."
}

function New-NotificationData {
    param(
        $HookData,
        [string]$NotificationEvent
    )

    $expectedHookEvent = if ($NotificationEvent -eq "ApprovalRequested") { "PermissionRequest" } else { "Stop" }
    $actualHookEvent = Get-RequiredString $HookData "hook_event_name"
    if ($actualHookEvent -ne $expectedHookEvent) {
        throw "Expected a $expectedHookEvent hook payload, received '$actualHookEvent'."
    }

    $sourcePaneId = [string]$env:WEZTERM_PANE
    if ([string]::IsNullOrWhiteSpace($sourcePaneId)) {
        throw "WEZTERM_PANE is missing. Run Codex inside native Windows WezTerm."
    }

    $sessionId = Get-RequiredString $HookData "session_id"
    $workingDirectory = Normalize-DisplayPath (Get-RequiredString $HookData "cwd")
    $weztermExecutable = Resolve-WezTermExecutable

    if ($NotificationEvent -eq "ApprovalRequested") {
        $toolName = Get-RequiredString $HookData "tool_name"
        $title = "Codex needs you"
        $message = "Approval requested for $toolName."
        $soundPath = "C:\Windows\Media\Windows Message Nudge.wav"
    } else {
        $title = "Codex finished"
        $message = [string]$HookData.last_assistant_message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "Codex finished without a final response."
        } else {
            $message = $message.Trim()
        }
        $soundPath = "C:\Windows\Media\Windows Notify Calendar.wav"
    }

    return [ordered]@{
        event              = $NotificationEvent
        title              = $title
        message            = Limit-Text $message 1000
        sound_path         = $soundPath
        session_name       = Limit-Text $sessionId 120
        working_directory  = Limit-Text $workingDirectory 500
        source_pane_id     = $sourcePaneId
        wezterm_executable = $weztermExecutable
        wezterm_socket     = [string]$env:WEZTERM_UNIX_SOCKET
    }
}

if ($Worker) {
    if ([string]::IsNullOrWhiteSpace($DataBase64)) {
        throw "DataBase64 is required in worker mode."
    }
    $notificationData = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($DataBase64)
    ) | ConvertFrom-Json
} else {
    $payload = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($payload)) {
        throw "Codex hook payload was empty."
    }

    try {
        $hookData = $payload | ConvertFrom-Json
    } catch {
        throw "Codex hook payload was not valid JSON: $($_.Exception.Message)"
    }

    $notificationData = New-NotificationData $hookData $Event
    if ($DryRun) {
        $notificationData | ConvertTo-Json -Depth 5
        return
    }

    $dataJson = $notificationData | ConvertTo-Json -Compress -Depth 5
    $encodedData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($dataJson))
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        $PSCommandPath + '" -Worker -DataBase64 ' + $encodedData
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexDetachedProcess
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

'@

    [CodexDetachedProcess]::Start((Join-Path $PSHOME "powershell.exe"), $arguments)
    return
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies "System.Windows.Forms.dll" -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public sealed class CodexPopupForm : Form
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

public static class CodexWindowFocus
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

    [DllImport("user32.dll")]
    private static extern void SwitchToThisWindow(IntPtr window, bool altTab);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);

    public static IntPtr[] GetProcessWindows(uint processId)
    {
        List<IntPtr> windows = new List<IntPtr>();
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId == processId && IsWindowVisible(window))
            {
                windows.Add(window);
            }
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

    public static bool ActivateWindow(IntPtr window)
    {
        if (window == IntPtr.Zero)
        {
            return false;
        }

        ShowWindowAsync(window, 9);
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
            if (GetForegroundWindow() != window)
            {
                SwitchToThisWindow(window, true);
            }
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

[CodexWindowFocus]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$Event = [string]$notificationData.event
$title = [string]$notificationData.title
$message = [string]$notificationData.message
$soundPath = [string]$notificationData.sound_path
$sessionName = [string]$notificationData.session_name
$workingDirectory = [string]$notificationData.working_directory
$sourcePaneId = [string]$notificationData.source_pane_id
$weztermCli = [string]$notificationData.wezterm_executable
if ($notificationData.wezterm_socket) {
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
    if (-not $sourcePaneId -or -not $weztermCli) {
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
        [CodexWindowFocus]::GetProcessWindows($_)
    })
    if ($windowHandles.Count -eq 0) {
        return [IntPtr]::Zero
    }

    $exactMatches = @($windowHandles | Where-Object {
        [CodexWindowFocus]::GetWindowTitle($_) -eq [string]$sourcePane.window_title
    })
    if ($exactMatches.Count -eq 1) {
        return [IntPtr]$exactMatches[0]
    }

    $stableSourceTitle = Get-StableWindowTitle ([string]$sourcePane.window_title)
    $stableMatches = @($windowHandles | Where-Object {
        (Get-StableWindowTitle ([CodexWindowFocus]::GetWindowTitle($_))) -eq $stableSourceTitle
    })
    if ($stableMatches.Count -eq 1) {
        return [IntPtr]$stableMatches[0]
    }

    if ($windowHandles.Count -eq 1) {
        return [IntPtr]$windowHandles[0]
    }

    return [IntPtr]::Zero
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
    if (-not [CodexWindowFocus]::ActivateWindow($windowHandle)) {
        throw "Windows refused to focus the WezTerm window for pane $sourcePaneId."
    }
}

$form = New-Object CodexPopupForm
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

$originatingWindow = Get-OriginatingWindowHandle
$screen = if ($originatingWindow -ne [IntPtr]::Zero) {
    [Windows.Forms.Screen]::FromHandle($originatingWindow).WorkingArea
} else {
    [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
}
$cardWidth = [Math]::Min(720, ($screen.Width - 36))
$form.ClientSize = New-Object Drawing.Size($cardWidth, 140)
$form.Location = New-Object Drawing.Point(
    ($screen.Right - $form.Width - 18),
    ($screen.Bottom - $form.Height - 18)
)

$accentColor = if ($Event -eq "ApprovalRequested") {
    [Drawing.Color]::FromArgb(249, 226, 175)
} else {
    [Drawing.Color]::FromArgb(166, 227, 161)
}

$icon = New-Object Windows.Forms.Label
$icon.AutoSize = $false
$icon.Location = New-Object Drawing.Point(14, 14)
$icon.Size = New-Object Drawing.Size(42, 42)
$icon.BackColor = $accentColor
$icon.ForeColor = [Drawing.Color]::FromArgb(24, 24, 37)
$icon.Font = New-Object Drawing.Font("Segoe UI Symbol", 18, [Drawing.FontStyle]::Bold)
$icon.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$icon.Text = if ($Event -eq "ApprovalRequested") { "!" } else { [char]0x2713 }
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
$messageLabel.AutoSize = $false
$messageLabel.Location = New-Object Drawing.Point(14, 87)
$messageLabel.Font = New-Object Drawing.Font("Segoe UI", 11.25)
$messageLabel.ForeColor = [Drawing.Color]::FromArgb(205, 214, 244)
$messageLabel.AutoEllipsis = $true
$messageLabel.TextAlign = [Drawing.ContentAlignment]::TopLeft
$messageLabel.Text = $message
$messageWidth = $cardWidth - 28
$measurementBounds = New-Object Drawing.Size($messageWidth, 1600)
$measurementFlags = [Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::NoPadding
$measuredMessage = [Windows.Forms.TextRenderer]::MeasureText(
    $message,
    $messageLabel.Font,
    $measurementBounds,
    $measurementFlags
)
$maximumMessageHeight = [Math]::Max(120, [Math]::Min(480, ($screen.Height - 130)))
$messageHeight = [Math]::Max(25, [Math]::Min($maximumMessageHeight, ($measuredMessage.Height + 4)))
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
        Show-OriginatingPane
        $form.Hide()
        $form.Close()
    } catch {
        Write-WorkerFailure $_.Exception.Message
        $timer.Start()
    }
}
$dismissPopup = { $timer.Stop(); $form.Close() }
$hoverOn = { $form.BackColor = [Drawing.Color]::FromArgb(30, 30, 46); $timer.Stop() }
$hoverOff = { $form.BackColor = [Drawing.Color]::FromArgb(24, 24, 37); $timer.Start() }

foreach ($control in @($form, $icon, $titleLabel, $sessionLabel, $workingDirectoryLabel, $messageLabel)) {
    $control.Cursor = [Windows.Forms.Cursors]::Hand
    $control.Add_Click($activatePopup)
    $control.Add_MouseEnter($hoverOn)
    $control.Add_MouseLeave($hoverOff)
}
$closeButton.Add_Click($dismissPopup)
$closeButton.Add_MouseEnter({ $closeButton.ForeColor = $accentColor })
$closeButton.Add_MouseLeave({ $closeButton.ForeColor = [Drawing.Color]::FromArgb(127, 132, 156) })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 20000
$timer.Add_Tick({ $timer.Stop(); $form.Close() })
$timer.Start()

$player = New-Object System.Media.SoundPlayer $soundPath
$player.Play()
$form.Show()
[CodexWindowFocus]::ShowWindowAsync($form.Handle, 4) | Out-Null
$form.Add_FormClosed({ [Windows.Forms.Application]::ExitThread() })
[Windows.Forms.Application]::Run()
