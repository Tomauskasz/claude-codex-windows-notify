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
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$workerPid = $proc.Id
Write-Host "Worker PID: $workerPid"

Start-Sleep -Milliseconds $DelayMs

$best = $null
$bestArea = 0

$script:bestHandle = [IntPtr]::Zero
$script:bestRect = $null

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
    $rect = New-Object PopupSnap+RECT
    [PopupSnap]::GetWindowRect($h, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $hpx = $rect.Bottom - $rect.Top
    $area = $w * $hpx
    Write-Host ("Candidate hwnd=0x{0:X} pid={1} cls={2} rect={3},{4} {5}x{6}" -f $h.ToInt64(), $winPid, $className, $rect.Left, $rect.Top, $w, $hpx)
    if ($w -ge 300 -and $hpx -ge 100 -and $area -gt $script:bestArea) {
        $script:bestArea = $area
        $script:bestHandle = $h
        $script:bestRect = $rect
    }
    return $true
}
$script:workerPid = $workerPid
$enumProc = [PopupSnap+EnumProc]$callback

[PopupSnap]::EnumWindows($enumProc, [IntPtr]::Zero) | Out-Null

if ($script:bestHandle -eq [IntPtr]::Zero) {
    Write-Error "Popup window not found"
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(2000)) { $proc.Kill() }
    exit 1
}

$rect = $script:bestRect
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
Write-Host "Capturing $width x $height at $($rect.Left),$($rect.Top)"
$bmp = New-Object System.Drawing.Bitmap $width, $height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [PopupSnap]::PrintWindow($script:bestHandle, $hdc, 2)
$g.ReleaseHdc($hdc)
if (-not $ok) {
    Write-Host "PrintWindow failed, falling back to CopyFromScreen"
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size $width, $height))
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
