param(
    [string]$NotifyScript = "C:\Users\Tomas\.config\opencode\plugins\claude-codex-windows-notify\scripts\notify.ps1",
    [string]$ProductName = "Codex",
    [string]$Event = "TurnComplete",
    [string]$SessionName = "Codex notification session name display",
    [string]$SessionId = "019fd2c0-4856-7d81-8536-9225d5c08fb3",
    [string]$Cwd = "C:\Users\Tomas\claude-codex-windows-notify",
    [Parameter(Mandatory=$false)]
    [string]$Message = "Reply exactly: completion screenshot.",
    [string]$Output = "C:\Users\Tomas\claude-codex-windows-notify\docs\screenshots\codex-complete.png",
    [int]$DelayMs = 1500
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$hookEvent = switch ($ProductName) {
    "Claude" { "PermissionRequest" }
    default {
        if ($Event -eq "TurnFailed") { "StopFailure" } else { "Stop" }
    }
}

$payload = [ordered]@{
    cwd = $Cwd
    hook_event_name = $hookEvent
    session_id = $SessionId
    session_name = $SessionName
}
if ($PSBoundParameters.ContainsKey('Message') -and -not [string]::IsNullOrWhiteSpace($Message)) {
    $payload["last_assistant_message"] = $Message
}
if ($ProductName -eq "Claude") {
    $payload["tool_name"] = "Bash"
    $payload["tool_input"] = @{ command = "cargo test --workspace" }
}
if ($Event -eq "TurnFailed" -and -not ($payload.Contains("last_assistant_message"))) {
    $payload["error"] = "rate_limit_exceeded"
}
$payload = $payload | ConvertTo-Json -Compress -Depth 4

$payloadJson = $payload | powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $NotifyScript -Event $Event -ProductName $ProductName -DryRun
$encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($payloadJson))

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "powershell.exe"
$psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$NotifyScript`" -Worker -DataBase64 $encoded"
$psi.UseShellExecute = $false
$psi.WindowStyle = "Hidden"
$proc = [System.Diagnostics.Process]::Start($psi)

Add-Type -ReferencedAssemblies "System.Drawing","System.Windows.Forms" -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class PopupSnap {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
}
"@

$workerPid = $proc.Id
Write-Host "Worker PID: $workerPid"

Start-Sleep -Milliseconds $DelayMs

$script:bestHandle = [IntPtr]::Zero
$script:bestClientOrigin = $null
$script:bestClientSize = $null
$script:bestWindowRect = $null
$script:bestArea = 0

$callback = {
    param($h, $l)
    if (-not [PopupSnap]::IsWindowVisible($h)) { return $true }
    $cls = New-Object System.Text.StringBuilder 256
    [PopupSnap]::GetClassName($h, $cls, 256) | Out-Null
    $className = $cls.ToString()
    if ($className -notlike "*WindowsForms*") { return $true }
    $winPid = [uint32]0
    [PopupSnap]::GetWindowThreadProcessId($h, [ref]$winPid) | Out-Null
    if ($winPid -ne $script:workerPid) { return $true }
    $winRect = New-Object PopupSnap+RECT
    [PopupSnap]::GetWindowRect($h, [ref]$winRect) | Out-Null
    $clientRect = New-Object PopupSnap+RECT
    [PopupSnap]::GetClientRect($h, [ref]$clientRect) | Out-Null
    $origin = New-Object PopupSnap+POINT
    [PopupSnap]::ClientToScreen($h, [ref]$origin) | Out-Null
    $cw = $clientRect.Right - $clientRect.Left
    $ch = $clientRect.Bottom - $clientRect.Top
    $ww = $winRect.Right - $winRect.Left
    $wh = $winRect.Bottom - $winRect.Top
    $area = $ww * $wh
    Write-Host ("Candidate hwnd=0x{0:X} pid={1} cls={2} win=({3},{4}) {5}x{6} client=({7},{8}) {9}x{10}" -f $h.ToInt64(), $winPid, $className, $winRect.Left, $winRect.Top, $ww, $wh, $origin.X, $origin.Y, $cw, $ch)
    if ($ww -ge 300 -and $wh -ge 100 -and $area -gt $script:bestArea) {
        $script:bestArea = $area
        $script:bestHandle = $h
        $script:bestClientOrigin = $origin
        $script:bestClientSize = $clientRect
        $script:bestWindowRect = $winRect
    }
    return $true
}
$script:workerPid = $workerPid
$enumProc = [PopupSnap+EnumProc]$callback

# Poll until popup layout settles (form resized to fit measured message)
for ($poll = 0; $poll -lt 40; $poll++) {
    $script:bestHandle = [IntPtr]::Zero
    $script:bestArea = 0
    [PopupSnap]::EnumWindows($enumProc, [IntPtr]::Zero) | Out-Null
    if ($script:bestHandle -ne [IntPtr]::Zero -and $script:bestArea -gt 40000) { break }
    Start-Sleep -Milliseconds 150
}

if ($script:bestHandle -eq [IntPtr]::Zero) {
    Write-Error "Popup window not found"
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(2000)) { $proc.Kill() }
    exit 1
}

$winRect = $script:bestWindowRect
$ww = $winRect.Right - $winRect.Left
$wh = $winRect.Bottom - $winRect.Top

# The form is constructed with cardWidth = 720 (logical). On high-DPI / virtualized displays,
# GetWindowRect returns physical pixels (e.g. 576x115 for a 720x144 logical form).
# PrintWindow renders the unscaled 720px logical surface, so the bitmap must be 720px wide
# to prevent right and bottom edge clipping.
$targetWidth = 720
$scale = if ($ww -gt 0 -and $ww -lt $targetWidth) { [double]$targetWidth / [double]$ww } else { 1.0 }

$width = [int]([Math]::Round($ww * $scale))
$height = [int]([Math]::Round($wh * $scale))
Write-Host "Capturing $width x $height (scale=$scale, raw=$ww x $wh)"
$bmp = New-Object System.Drawing.Bitmap $width, $height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [PopupSnap]::PrintWindow($script:bestHandle, $hdc, 2)
$g.ReleaseHdc($hdc)
if (-not $ok) {
    Write-Host "PrintWindow failed"
}
$directory = Split-Path $Output -Parent
if (-not (Test-Path -LiteralPath $directory)) { New-Item -Path $directory -ItemType Directory -Force | Out-Null }
$bmp.Save($Output, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Host "Saved: $Output"
$proc.CloseMainWindow() | Out-Null
if (-not $proc.WaitForExit(2000)) { $proc.Kill() }
exit 0
