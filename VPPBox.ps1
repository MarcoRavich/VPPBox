#Requires -Version 5.1
<#
VPPBox v0.7.2 - Windows PowerShell 5.1 / PowerShell 7, Windows x64, STA.
#>
[CmdletBinding()]
param(
    [string]$PreviewCliPath = '',
    [ValidateRange(10, 600)][int]$PreviewTimeoutSeconds = 120,
    [ValidateRange(1048576, 17179869184)][long]$PreviewMaxDumpBytes = 2147483648,
    [ValidateRange(0, 30)][double]$PreviewPreMarginSeconds = 2,
    [ValidateRange(0.01, 30)][double]$PreviewPostMarginSeconds = 0.5
)
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'VPPBox requires Windows and WPF.' }
if (-not [Environment]::Is64BitProcess) { throw 'Start VPPBox in 64-bit PowerShell.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Start with powershell.exe -NoProfile -STA -File .\VPPBox.ps1, or pwsh.exe -NoProfile -STA -File .\VPPBox.ps1.'
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
$Script:Root = $PSScriptRoot
if (-not $Script:Root) { $Script:Root = (Get-Location).Path }
$Script:Process = $null; $Script:Timer = $null; $Script:PreviewTimer = $null; $Script:PvTimer = $null
$Script:CommandTimer = $null; $Script:CapsTimer = $null; $Script:CapsJob = $null
$Script:PreviewGeneration = 0; $Script:Restoring = $true; $Script:UiReady = $false; $Script:Closing = $false
$Script:SplitPosition = 0.5; $Script:QueueActive = $false; $Script:QueueIndex = 0; $Script:Encoder = $null
$Script:SuggestedOutput = ''; $Script:CapsCache = @{}; $Script:BrushCache = @{}
$Script:StatusReady = $false
$Script:ThemeSettings = $null; $Script:ThemePalette = $null; $Script:ThemeSettingsPath = ''
$Script:ThemeHwndSource = $null; $Script:ThemeMessageHook = $null; $Script:ThemeCaptionDark = $null
$Script:ThemeRefreshTimer = $null
$Script:CleanupTasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
$Script:StdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('vppbox-' + [guid]::NewGuid().ToString('N') + '.out')
$Script:StderrPath = Join-Path ([IO.Path]::GetTempPath()) ('vppbox-' + [guid]::NewGuid().ToString('N') + '.err')
$Script:BrushConv = New-Object System.Windows.Media.BrushConverter
$Script:Pv = @{ Busy = $false }
$Script:PvCache = @{ SrcKey = ''; Source = $null; PrcKey = ''; Processed = $null }
function Brush([string]$Color) {
    if (-not $Script:BrushCache.ContainsKey($Color)) {
        if ($Script:BrushCache.Count -ge 256) { $Script:BrushCache.Clear() }
        $brush = $Script:BrushConv.ConvertFromInvariantString($Color); $brush.Freeze(); $Script:BrushCache[$Color] = $brush
    }
    return $Script:BrushCache[$Color]
}
# All status transitions go through one setter; notifications cannot turn a busy
# queue green. Readiness is explicit, never guessed from localized message text.
function Set-Status {
    param([string]$Text, [bool]$Ready = $false)
    $Script:StatusReady = $Ready -and -not $Script:QueueActive
    if (-not $lbl_status) { return }
    $lbl_status.Text = $Text
    Set-TextResource $lbl_status $(if ($Script:StatusReady) { 'ReadyBrush' } else { 'ErrorBrush' })
}
function Update-IdleStatus {
    if ($Script:QueueActive -or $Script:Closing) { return }
    if (Get-SelectedEncoder) { Set-Status 'Ready - drop video files into the window' $true }
    else { Set-Status 'No encoder selected - open Settings' }
}
function Fmt-Num([double]$Value) { return $Value.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) }
function Get-VideoControllers {
    try { Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name } }
    catch { try { Get-WmiObject -Class Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name } } catch { } }
}
function Resolve-EncoderExecutable {
    param([string]$Name)
    $local = Join-Path $Script:Root $Name
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    $cwd = Join-Path (Get-Location).Path $Name
    if (Test-Path -LiteralPath $cwd -PathType Leaf) { return $cwd }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Get-SelectedEncoder {
    $item = $cmb_encoder.SelectedItem
    if ($item -and $item.Tag) { return [string]$item.Tag }
    return $null
}


# ------------------------------------------------------------ application theme
# App colors follow Windows by default. No Windows preferences are modified.
# Dynamic resources also cover controls created by Build-AllFilterPanels.
function Set-TextResource($Control, [string]$Key) {
    $Control.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $Key)
}
function New-ThemeSettings {
    return [ordered]@{ Version = 1; Mode = 'System'; Accent = ''; WindowBackground = ''; Surface = ''; Text = '' }
}
function ConvertTo-ThemeSettings($Value) {
    $result = New-ThemeSettings
    if ($null -eq $Value -or ($Value -isnot [System.Collections.IDictionary] -and $Value -isnot [pscustomobject])) { throw 'Invalid theme settings object.' }
    if ($null -ne $Value.Version -and [string]$Value.Version -ne '1') { throw 'Unsupported theme settings version.' }
    if ($Value.Mode) {
        if ([string]$Value.Mode -notin @('System', 'Light', 'Dark')) { throw 'Theme mode must be System, Light or Dark.' }
        foreach ($mode in @('System', 'Light', 'Dark')) { if ($mode -eq [string]$Value.Mode) { $result.Mode = $mode; break } }
    }
    foreach ($key in @('Accent', 'WindowBackground', 'Surface', 'Text')) {
        $color = ([string]$Value.$key).Trim()
        if ($color -and $color -notmatch '^#[0-9A-Fa-f]{6}$') { throw ("Invalid {0} color. Use #RRGGBB or leave the field empty." -f $key) }
        $result[$key] = $color.ToUpperInvariant()
    }
    return $result
}
function Read-ThemeSettings {
    $defaults = New-ThemeSettings
    try {
        if (-not $Script:ThemeSettingsPath -or -not [IO.File]::Exists($Script:ThemeSettingsPath)) { return $defaults }
        if ((Get-Item -LiteralPath $Script:ThemeSettingsPath -ErrorAction Stop).Length -gt 32768) { throw 'Theme settings file is too large.' }
        $data = [IO.File]::ReadAllText($Script:ThemeSettingsPath) | ConvertFrom-Json -ErrorAction Stop
        return (ConvertTo-ThemeSettings $data)
    } catch {
        Add-Log ('Theme preferences could not be loaded; using Windows appearance. ' + $_.Exception.Message)
        return $defaults
    }
}
function Write-ThemeSettings {
    # Write to a sibling file first, then atomically replace the old preferences.
    $temporary = $null
    try {
        if (-not $Script:ThemeSettingsPath) { throw 'The local application data folder is unavailable.' }
        $directory = [IO.Path]::GetDirectoryName($Script:ThemeSettingsPath)
        [void][IO.Directory]::CreateDirectory($directory)
        $temporary = Join-Path $directory ('theme-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $json = $Script:ThemeSettings | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Script:ThemeSettingsPath)) { [IO.File]::Replace($temporary, $Script:ThemeSettingsPath, $null) }
        else { [IO.File]::Move($temporary, $Script:ThemeSettingsPath) }
    } finally {
        if ($temporary -and [IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}
function Mix-ThemeColor([string]$First, [string]$Second, [double]$Amount) {
    $amountClamped = [Math]::Max(0, [Math]::Min(1, $Amount))
    $rgb = for ($i = 1; $i -lt 7; $i += 2) {
        $a = [Convert]::ToInt32($First.Substring($i, 2), 16)
        $b = [Convert]::ToInt32($Second.Substring($i, 2), 16)
        [int][Math]::Round($a + ($b - $a) * $amountClamped)
    }
    return ('#{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2])
}
function Get-ThemeLuminance([string]$Color) {
    $channels = for ($i = 1; $i -lt 7; $i += 2) {
        $value = [Convert]::ToInt32($Color.Substring($i, 2), 16) / 255.0
        if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
    }
    return (0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2])
}
function Get-ThemeContrast([string]$First, [string]$Second) {
    $a = Get-ThemeLuminance $First; $b = Get-ThemeLuminance $Second
    return (([Math]::Max($a, $b) + 0.05) / ([Math]::Min($a, $b) + 0.05))
}
function Get-ThemeInk([string]$Background) {
    if ((Get-ThemeContrast '#FFFFFF' $Background) -gt (Get-ThemeContrast '#000000' $Background)) { return '#FFFFFF' }
    return '#000000'
}
function Get-ReadableThemeColor([string]$Color, [string]$Background) {
    if ((Get-ThemeContrast $Color $Background) -ge 4.5) { return $Color }
    $target = Get-ThemeInk $Background
    for ($i = 1; $i -le 20; $i++) {
        $candidate = Mix-ThemeColor $Color $target ($i / 20.0)
        if ((Get-ThemeContrast $candidate $Background) -ge 4.5) { return $candidate }
    }
    return $target
}
function ConvertTo-ThemeHex($Color) { return ('#{0:X2}{1:X2}{2:X2}' -f $Color.R, $Color.G, $Color.B) }
function Get-SystemAppearance {
    # AppsUseLightTheme is the Windows application preference, not the taskbar mode.
    # Missing values fall back to light. Registry access is read-only.
    $mode = 'Light'
    foreach ($hive in @('HKEY_CURRENT_USER', 'HKEY_LOCAL_MACHINE')) {
        try {
            $value = [Microsoft.Win32.Registry]::GetValue(($hive + '\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'), 'AppsUseLightTheme', $null)
            if ($null -ne $value) { if ([int]$value -eq 0) { $mode = 'Dark' }; break }
        } catch { }
    }
    $accent = '#0078D4'
    try { $accent = ConvertTo-ThemeHex ([Windows.SystemParameters]::WindowGlassColor) } catch { }
    $systemColors = @{}
    foreach ($entry in @(
        @('Window', 'WindowColor'), @('WindowText', 'WindowTextColor'), @('Control', 'ControlColor'),
        @('ControlText', 'ControlTextColor'), @('Highlight', 'HighlightColor'), @('HighlightText', 'HighlightTextColor'),
        @('GrayText', 'GrayTextColor'))) {
        $property = [Windows.SystemColors].GetProperty($entry[1])
        $systemColors[$entry[0]] = ConvertTo-ThemeHex ($property.GetValue($null, $null))
    }
    return @{ Mode = $mode; Accent = $accent; HighContrast = [Windows.SystemParameters]::HighContrast; Colors = $systemColors }
}
function Get-ThemePalette($Settings, $SystemAppearance) {
    $mode = if ($Settings.Mode -eq 'System') { $SystemAppearance.Mode } else { $Settings.Mode }
    $dark = $mode -eq 'Dark'
    $background = if ($dark) { '#202020' } else { '#F3F3F3' }
    $surface = if ($dark) { '#292929' } else { '#FFFFFF' }
    $text = if ($dark) { '#F2F2F2' } else { '#1A1A1A' }
    $accent = [string]$SystemAppearance.Accent
    if ($Settings.Accent) { $accent = $Settings.Accent }
    if ($Settings.WindowBackground) { $background = $Settings.WindowBackground }
    if ($Settings.Surface) { $surface = $Settings.Surface; $text = Get-ThemeInk $surface }
    if ($Settings.Text) { $text = $Settings.Text }
    $p = [ordered]@{
        WindowBackgroundBrush = $background; SurfaceBrush = $surface
        SurfaceAltBrush = (Mix-ThemeColor $surface $text 0.025)
        InputBackgroundBrush = (Mix-ThemeColor $surface $text 0.035)
        ControlBackgroundBrush = (Mix-ThemeColor $surface $text 0.05)
        ButtonBrush = (Mix-ThemeColor $surface $text 0.065)
        HoverBrush = (Mix-ThemeColor $surface $text 0.12)
        PressedBrush = (Mix-ThemeColor $surface $text 0.18)
        BorderBrush = (Mix-ThemeColor $surface $text 0.24)
        StrongBorderBrush = (Mix-ThemeColor $surface $text 0.48)
        TextBrush = $text
        MutedTextBrush = (Get-ReadableThemeColor (Mix-ThemeColor $surface $text 0.68) $surface)
        AccentBrush = $accent; AccentTextBrush = (Get-ReadableThemeColor $accent $surface)
        AccentForegroundBrush = (Get-ThemeInk $accent)
        SelectionBrush = $accent; SelectionTextBrush = (Get-ThemeInk $accent)
        ReadyBrush = (Get-ReadableThemeColor $(if ($dark) { '#81C784' } else { '#237A32' }) $surface)
        ErrorBrush = (Get-ReadableThemeColor $(if ($dark) { '#FF6B6B' } else { '#C42B1C' }) $surface)
        SwitchThumbBrush = $text
        PreviewBackgroundBrush = '#101218'; PreviewTextBrush = '#CBD3E3'; PreviewDividerBrush = '#FFFFFF'
        OverlayBackgroundBrush = '#DD101218'; OverlayAccentBrush = '#DD234E9B'; OverlayTextBrush = '#FFFFFF'
    }
    $description = 'Effective appearance: ' + $mode
    if ($Settings.Mode -eq 'System') { $description += ' (Windows app mode).' } else { $description += ' (manual selection).' }
    if ($SystemAppearance.HighContrast) {
        # Respect the accessibility palette; retain explicit green/red status semantics.
        $c = $SystemAppearance.Colors
        foreach ($key in @('WindowBackgroundBrush', 'SurfaceBrush', 'InputBackgroundBrush')) { $p[$key] = $c.Window }
        foreach ($key in @('SurfaceAltBrush', 'ControlBackgroundBrush', 'ButtonBrush', 'PressedBrush', 'HoverBrush')) { $p[$key] = $c.Control }
        foreach ($key in @('TextBrush', 'MutedTextBrush', 'BorderBrush', 'StrongBorderBrush', 'SwitchThumbBrush')) { $p[$key] = $c.WindowText }
        foreach ($key in @('AccentBrush', 'SelectionBrush')) { $p[$key] = $c.Highlight }
        $p.AccentTextBrush = $c.WindowText
        $p.AccentForegroundBrush = $c.HighlightText; $p.SelectionTextBrush = $c.HighlightText
        $p.ReadyBrush = Get-ReadableThemeColor '#238636' $c.Window
        $p.ErrorBrush = Get-ReadableThemeColor '#D32F2F' $c.Window
        $description = 'Windows high contrast is active. Custom colors are temporarily ignored.'
    }
    return [pscustomobject]@{
        Colors = $p; Description = $description
        DarkCaption = (-not $SystemAppearance.HighContrast -and (Get-ThemeLuminance $p.WindowBackgroundBrush) -lt 0.35)
        LowContrast = ((Get-ThemeContrast $p.TextBrush $p.SurfaceBrush) -lt 4.5 -or (Get-ThemeContrast $p.TextBrush $p.InputBackgroundBrush) -lt 4.5)
    }
}
function Update-ThemeCaption {
    if (-not $Script:ThemeHwndSource -or -not $Script:ThemePalette) { return }
    $dark = [bool]$Script:ThemePalette.DarkCaption
    if ($null -ne $Script:ThemeCaptionDark -and $Script:ThemeCaptionDark -eq $dark) { return }
    $Script:ThemeCaptionDark = $dark
    # Unsupported DWM attributes are ignored; the application theme still works.
    [void][VppBoxTheme072.NativeTheme]::TrySetDarkCaption($Script:ThemeHwndSource.Handle, $dark)
}
function Apply-Theme {
    if (-not $window -or -not $Script:ThemeSettings) { return }
    $palette = Get-ThemePalette $Script:ThemeSettings (Get-SystemAppearance)
    foreach ($key in $palette.Colors.Keys) {
        if (-not $Script:ThemePalette -or $Script:ThemePalette.Colors[$key] -ne $palette.Colors[$key]) {
            $window.Resources[$key] = Brush $palette.Colors[$key]
        }
    }
    $Script:ThemePalette = $palette
    $lbl_theme_effective.Text = $palette.Description
    foreach ($entry in @(@('swatch_theme_accent', 'AccentBrush'), @('swatch_theme_window', 'WindowBackgroundBrush'),
            @('swatch_theme_surface', 'SurfaceBrush'), @('swatch_theme_text', 'TextBrush'))) {
        $control = $window.FindName($entry[0])
        $control.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $entry[1])
        $control.ToolTip = $palette.Colors[$entry[1]]
    }
    Update-ThemeCaption
}
function Sync-ThemeEditor {
    foreach ($item in $cmb_theme_mode.Items) { if ([string]$item.Tag -eq $Script:ThemeSettings.Mode) { $cmb_theme_mode.SelectedItem = $item; break } }
    $txt_theme_accent.Text = $Script:ThemeSettings.Accent
    $txt_theme_window.Text = $Script:ThemeSettings.WindowBackground
    $txt_theme_surface.Text = $Script:ThemeSettings.Surface
    $txt_theme_text.Text = $Script:ThemeSettings.Text
}
function Set-ThemeFeedback([string]$Text, [bool]$ErrorState = $false) {
    $lbl_theme_feedback.Text = $Text
    Set-TextResource $lbl_theme_feedback $(if ($ErrorState) { 'ErrorBrush' } else { 'MutedTextBrush' })
}
function Save-ThemeFromEditor([switch]$Reset) {
    try {
        if ($Reset) { $candidate = New-ThemeSettings }
        else {
            $candidate = ConvertTo-ThemeSettings @{
                Mode = [string]$cmb_theme_mode.SelectedItem.Tag; Accent = $txt_theme_accent.Text
                WindowBackground = $txt_theme_window.Text; Surface = $txt_theme_surface.Text; Text = $txt_theme_text.Text
            }
        }
    } catch { Set-ThemeFeedback $_.Exception.Message $true; return }
    $previous = $Script:ThemeSettings
    try { $Script:ThemeSettings = $candidate; Apply-Theme; Sync-ThemeEditor }
    catch {
        $Script:ThemeSettings = $previous
        try { Apply-Theme } catch { }
        Set-ThemeFeedback 'The theme could not be applied. The previous settings have been restored.' $true
        Add-Log ('Theme update failed: ' + $_.Exception.Message); return
    }
    try {
        Write-ThemeSettings
        if ($Script:ThemePalette.LowContrast) { Set-ThemeFeedback 'Theme saved. Some custom colors have low text contrast; adjust them or reset to system.' $true }
        else { Set-ThemeFeedback 'Theme applied and saved.' }
    } catch {
        Set-ThemeFeedback 'Theme applied for this session only. Preferences could not be saved.' $true
        Add-Log ('Theme preferences could not be saved: ' + $_.Exception.Message)
    }
}
function Connect-ThemeNotifications {
    $Script:ThemeHwndSource = [Windows.Interop.HwndSource]::FromVisual($window)
    if (-not $Script:ThemeHwndSource) { return }
    # Window messages run on the UI dispatcher. Do not use a PowerShell callback on
    # SystemEvents' background thread, which may have no PowerShell runspace.
    $Script:ThemeMessageHook = [Windows.Interop.HwndSourceHook] {
        param([IntPtr]$handle, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
        if (-not $Script:Closing -and $Script:ThemeRefreshTimer -and
            ($message -eq 0x001A -or $message -eq 0x031A -or $message -eq 0x0015 -or $message -eq 0x0320)) {
            $Script:ThemeRefreshTimer.Stop(); $Script:ThemeRefreshTimer.Start()
        }
        return [IntPtr]::Zero
    }
    $Script:ThemeHwndSource.AddHook($Script:ThemeMessageHook)
    Update-ThemeCaption
}
function Disconnect-ThemeNotifications {
    if ($Script:ThemeRefreshTimer) { $Script:ThemeRefreshTimer.Stop() }
    if ($Script:ThemeHwndSource -and $Script:ThemeMessageHook) {
        try { $Script:ThemeHwndSource.RemoveHook($Script:ThemeMessageHook) } catch { }
    }
    $Script:ThemeMessageHook = $null; $Script:ThemeHwndSource = $null
}


# ------------------------------------------------------------ worker support
if (-not ('VppBox07.FrameReader' -as [type])) {
$csSource = @'
// VPPBox: .NET Framework 4.5 / C# 5 compatible support code.
// Y4M/color conventions and HDR display policy follow rigaya/HWEncVppPreview.
// See the MIT notice in the PowerShell header. No WPF objects cross worker threads.
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace VppBox07 {
    public sealed class ProcessResult {
        public int ExitCode;
        public string Output, Error;
        public bool Cancelled, TimedOut;
    }
    // Closing the job kills the CLI AND the encoder processes it created.
    internal sealed class ProcessGroup : IDisposable {
        private IntPtr handle;
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
            public BasicLimits BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint length);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        public ProcessGroup(Process process) {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            var info = new ExtendedLimits();
            info.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(handle, 9, ref info, (uint)Marshal.SizeOf(typeof(ExtendedLimits))) ||
                !AssignProcessToJobObject(handle, process.Handle)) {
                int error = Marshal.GetLastWin32Error(); Dispose();
                throw new System.ComponentModel.Win32Exception(error, "Cannot contain preview process tree in a Windows Job Object.");
            }
        }
        public void Dispose() {
            IntPtr old = Interlocked.Exchange(ref handle, IntPtr.Zero);
            if (old != IntPtr.Zero) CloseHandle(old);
        }
    }
    public sealed class CaptureJob {
        readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        public Task<ProcessResult> Completion { get; private set; }
        CaptureJob() { }
        public static CaptureJob Start(string exe, string arguments, int timeoutSeconds, string dumpPath, long maxDumpBytes) {
            var job = new CaptureJob();
            job.Completion = Task.Run(() => job.Run(exe, arguments, timeoutSeconds, dumpPath, maxDumpBytes));
            return job;
        }
        static string ReadTail(StreamReader reader, int limit) {
            var text = new StringBuilder(); var buffer = new char[4096]; int count;
            while ((count = reader.Read(buffer, 0, buffer.Length)) > 0) {
                text.Append(buffer, 0, count);
                if (text.Length > limit) text.Remove(0, text.Length - limit);
            }
            return text.ToString();
        }
        ProcessResult Run(string exe, string arguments, int seconds, string dumpPath, long maxBytes) {
            var result = new ProcessResult { ExitCode = -1, Output = "", Error = "" };
            Process process = null; ProcessGroup group = null;
            Task<string> output = null, error = null;
            var watch = Stopwatch.StartNew();
            try {
                cancellation.Token.ThrowIfCancellationRequested();
                process = new Process();
                process.StartInfo = new ProcessStartInfo(exe, arguments) {
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false),
                    WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(exe))
                };
                if (!process.Start()) throw new IOException("Process did not start.");
                group = new ProcessGroup(process);
                output = Task.Run(() => ReadTail(process.StandardOutput, 1024 * 1024));
                error = Task.Run(() => ReadTail(process.StandardError, 128 * 1024));
                while (!process.WaitForExit(100)) {
                    cancellation.Token.ThrowIfCancellationRequested();
                    if (watch.Elapsed.TotalSeconds > seconds) { result.TimedOut = true; throw new TimeoutException("Preview/probe deadline exceeded."); }
                    if (!String.IsNullOrEmpty(dumpPath) && File.Exists(dumpPath) && new FileInfo(dumpPath).Length > maxBytes)
                        throw new IOException("Preview dump exceeded its configured size limit. Reduce the preview margins or raise PreviewMaxDumpBytes.");
                }
                result.ExitCode = process.ExitCode;
            }
            catch (OperationCanceledException) { result.Cancelled = true; }
            catch (Exception ex) { result.Error = ex.Message; }
            finally {
                if (group != null) group.Dispose();
                if (process != null) {
                    try { if (!process.HasExited) process.Kill(); process.WaitForExit(2000); } catch { }
                    if (output != null) {
                        try { if (output.Wait(2000)) result.Output = output.Result; } catch { }
                    }
                    if (error != null) {
                        try { if (error.Wait(2000)) result.Error += "\n" + error.Result; } catch { }
                    }
                    process.Dispose();
                }
                // CancellationTokenSource remains alive until this job is collected: Cancel() is race-safe.
            }
            return result;
        }
        public void Cancel() { cancellation.Cancel(); }
    }
    public static class Cleanup {
        public static Task DirectoryAfter(Task task, string path) {
            return (task ?? Task.FromResult(0)).ContinueWith(t => {
                if (t.IsFaulted) { var ignored = t.Exception; }
                if (!String.IsNullOrEmpty(path)) DeleteDirectory(path);
            }, TaskScheduler.Default);
        }
        public static void DeleteDirectory(string path) {
            for (int i = 0; i < 5; ++i) {
                try { if (Directory.Exists(path)) Directory.Delete(path, true); return; }
                catch { Thread.Sleep(100); }
            }
        }
    }
    public sealed class Frame {
        public int Width, Height, BitDepth, SarNum, SarDen;
        public string Chroma, ColorDescription, Warning, Sha256;
        public double? Timestamp;
        public byte[] Bgra;
    }
    public sealed class FrameJob {
        readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        public Task<Frame> Completion { get; private set; }
        FrameJob() { }
        public static FrameJob Start(string path, int index, int width, int height, int depth, string chroma, string hash) {
            var job = new FrameJob();
            job.Completion = Task.Run(() => FrameReader.Read(path, index, width, height, depth, chroma, hash, job.cancellation.Token));
            return job;
        }
        public void Cancel() { cancellation.Cancel(); }
    }
    public static class FrameReader {
        sealed class Header {
            public int W, H, Depth = 8, SarN = 1, SarD = 1, Cw, Ch, Bytes, Size;
            public string Chroma = "420", Tag = "420jpeg", Matrix = "", Range = "", Location = "", Transfer = "", Primaries = "";
        }
        static string Line(Stream input) {
            var text = new StringBuilder(128);
            for (int i = 0; i <= 16384; ++i) {
                int b = input.ReadByte();
                if (b < 0) { if (text.Length == 0) return null; throw new EndOfStreamException("Truncated Y4M header."); }
                if (b == 10) return text.ToString().TrimEnd('\r');
                if (b > 127) throw new FormatException("Non-ASCII Y4M header.");
                text.Append((char)b);
            }
            throw new FormatException("Y4M header is too long.");
        }
        static int Positive(string text) {
            int value;
            if (!Int32.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value) || value <= 0)
                throw new FormatException("Invalid positive Y4M integer: " + text);
            return value;
        }
        static Header Parse(string line) {
            if (line == null || !line.StartsWith("YUV4MPEG2 ", StringComparison.Ordinal)) throw new FormatException("Missing YUV4MPEG2 header.");
            var h = new Header();
            foreach (string t in line.Split(new [] {' '}, StringSplitOptions.RemoveEmptyEntries)) {
                if (t.Length < 2) continue;
                switch (t[0]) {
                    case 'W': h.W = Positive(t.Substring(1)); break;
                    case 'H': h.H = Positive(t.Substring(1)); break;
                    case 'C': h.Tag = t.Substring(1); break;
                    case 'A':
                        var ratio = t.Substring(1).Split(':'); int n, d;
                        if (ratio.Length != 2 || !Int32.TryParse(ratio[0], out n) || !Int32.TryParse(ratio[1], out d) || n < 0 || d < 0)
                            throw new FormatException("Invalid Y4M sample aspect ratio.");
                        if (n > 0 && d > 0) { h.SarN = n; h.SarD = d; }
                        break;
                    case 'X':
                        int eq = t.IndexOf('='); if (eq < 0) break;
                        string val = t.Substring(eq + 1).ToLowerInvariant();
                        switch (t.Substring(0, eq)) {
                            case "XCOLORMATRIX": h.Matrix = val; break;
                            case "XCOLORRANGE": h.Range = val; break;
                            case "XCHROMALOC": h.Location = val; break;
                            case "XTRANSFER": h.Transfer = val; break;
                            case "XCOLORPRIM": h.Primaries = val; break;
                        }
                        break;
                }
            }
            string suffix;
            if (h.Tag.StartsWith("mono", StringComparison.Ordinal)) { h.Chroma = "mono"; suffix = h.Tag.Substring(4); }
            else if (h.Tag.StartsWith("420", StringComparison.Ordinal) || h.Tag.StartsWith("422", StringComparison.Ordinal) || h.Tag.StartsWith("444", StringComparison.Ordinal)) {
                h.Chroma = h.Tag.Substring(0, 3); suffix = h.Tag.Substring(3);
            } else throw new FormatException("Unsupported Y4M chroma: " + h.Tag);
            if (suffix != "" && suffix != "jpeg" && suffix != "mpeg2" && suffix != "paldv") {
                if (suffix.StartsWith("p", StringComparison.Ordinal)) suffix = suffix.Substring(1);
                else if (h.Chroma != "mono") throw new FormatException("Unsupported Y4M color tag: " + h.Tag);
                h.Depth = Positive(suffix);
            }
            if (h.Depth < 8 || h.Depth > 16) throw new FormatException("Unsupported Y4M bit depth.");
            long pixels = (long)h.W * h.H;
            if (h.W <= 0 || h.H <= 0 || pixels > 64L * 1024 * 1024) throw new FormatException("Invalid or excessive frame dimensions (maximum 64 megapixels).");
            h.Bytes = h.Depth > 8 ? 2 : 1;
            h.Cw = h.Chroma == "mono" ? 0 : h.Chroma == "444" ? h.W : (h.W + 1) / 2;
            h.Ch = h.Chroma == "mono" ? 0 : h.Chroma == "420" ? (h.H + 1) / 2 : h.H;
            h.Size = checked((int)((pixels + 2L * h.Cw * h.Ch) * h.Bytes));
            return h;
        }
        public static Frame Read(string path, int index, int width, int height, int depth, string chroma, string hash, CancellationToken token) {
            if (index < 0) throw new ArgumentOutOfRangeException("index");
            Header h; byte[] payload = null; double? timestamp = null;
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.RandomAccess)) {
                h = Parse(Line(input));
                if (h.W != width || h.H != height || h.Depth != depth || h.Chroma != chroma)
                    throw new FormatException("CLI JSON and Y4M format metadata do not match.");
                for (int i = 0; i <= index; ++i) {
                    token.ThrowIfCancellationRequested();
                    string marker = Line(input);
                    if (marker == null || (marker != "FRAME" && !marker.StartsWith("FRAME ", StringComparison.Ordinal)))
                        throw new FormatException("Selected frame is missing from the Y4M dump.");
                    if (input.Length - input.Position < h.Size) throw new EndOfStreamException("Truncated Y4M frame payload.");
                    if (i != index) { input.Seek(h.Size, SeekOrigin.Current); continue; }
                    foreach (string t in marker.Split(' ')) {
                        double value;
                        if (t.StartsWith("Xts=", StringComparison.Ordinal) && Double.TryParse(t.Substring(4), NumberStyles.Float, CultureInfo.InvariantCulture, out value) && !Double.IsNaN(value) && !Double.IsInfinity(value)) timestamp = value;
                    }
                    payload = new byte[h.Size]; int pos = 0;
                    while (pos < payload.Length) {
                        token.ThrowIfCancellationRequested();
                        int count = input.Read(payload, pos, Math.Min(65536, payload.Length - pos));
                        if (count == 0) throw new EndOfStreamException("Truncated Y4M frame.");
                        pos += count;
                    }
                }
            }
            string actualHash;
            using (var sha = SHA256.Create()) actualHash = BitConverter.ToString(sha.ComputeHash(payload)).Replace("-", "").ToLowerInvariant();
            if (String.IsNullOrEmpty(hash) || !String.Equals(actualHash, hash, StringComparison.OrdinalIgnoreCase))
                throw new FormatException("Selected frame SHA-256 does not match the CLI result.");
            var result = new Frame { Width = h.W, Height = h.H, BitDepth = h.Depth, Chroma = h.Chroma,
                SarNum = h.SarN, SarDen = h.SarD, Timestamp = timestamp, Sha256 = actualHash, Warning = "" };
            result.Bgra = Convert(h, payload, result, token);
            return result;
        }
        static int Sample(byte[] data, int index, int bytes) { return bytes == 1 ? data[index] : data[index * 2] | (data[index * 2 + 1] << 8); }
        static byte Clip(double value) { return (byte)Math.Max(0, Math.Min(255, Math.Round(value, MidpointRounding.AwayFromZero))); }
        static void Axis(int coordinate, bool centered, int length, out int a, out int b, out double f) {
            a = coordinate >> 1;
            if (centered) { bool even = (coordinate & 1) == 0; if (even) --a; f = even ? 0.75 : 0.25; }
            else f = (coordinate & 1) == 0 ? 0 : 0.5;
            b = Math.Max(0, Math.Min(a + 1, length - 1)); a = Math.Max(0, Math.Min(a, length - 1));
        }
        static byte[] Convert(Header h, byte[] data, Frame result, CancellationToken token) {
            double kr, kb; string matrix; bool assumed = false;
            switch (h.Matrix) {
                case "bt709": case "709": kr = 0.2126; kb = 0.0722; matrix = "BT.709"; break;
                case "bt601": case "601": case "smpte170m": case "bt470bg": kr = 0.299; kb = 0.114; matrix = "BT.601"; break;
                case "bt2020nc": case "bt2020ncl": case "bt2020-ncl": kr = 0.2627; kb = 0.0593; matrix = "BT.2020 NCL"; break;
                case "smpte240m": case "smpte240": kr = 0.212; kb = 0.087; matrix = "SMPTE 240M"; break;
                default:
                    assumed = true; bool hd = h.W > 1024 || h.H > 576;
                    kr = hd ? 0.2126 : 0.299; kb = hd ? 0.0722 : 0.114; matrix = hd ? "BT.709" : "BT.601"; break;
            }
            bool full = h.Range == "full" || h.Range == "pc" || h.Range == "jpeg";
            string loc = h.Location;
            if (loc != "center" && loc != "left" && loc != "topleft" && loc != "top-left") loc = h.Tag == "420jpeg" ? "center" : "left";
            bool hdr = h.Transfer == "pq" || h.Transfer == "smpte2084" || h.Transfer == "hlg" || h.Transfer == "arib-std-b67";
            bool hlg = h.Transfer == "hlg" || h.Transfer == "arib-std-b67";
            bool bt2020 = h.Primaries == "bt2020" || h.Primaries == "2020";
            result.ColorDescription = matrix + ", " + (full ? "full" : "limited") + ", " + h.Tag + (hdr ? ", HDR -> SDR (203/1000 nits)" : "");
            if (assumed) result.Warning = "Color matrix absent/unsupported: resolution-based fallback " + matrix + ". ";
            if (h.Range != "full" && h.Range != "pc" && h.Range != "jpeg" && h.Range != "limited" && h.Range != "tv" && h.Range != "mpeg") result.Warning += "Color range absent/unsupported: limited assumed. ";
            if (h.Tag == "420paldv") result.Warning += "PAL-DV chroma phase approximated as left, as in the reference viewer. ";
            int luma = h.W * h.H, chromaSize = h.Cw * h.Ch, scale = 1 << (h.Depth - 8), neutral = 128 * scale;
            int black = full ? 0 : 16 * scale;
            double kg = 1 - kr - kb;
            double yf = 255.0 / (full ? (1 << h.Depth) - 1 : 219 * scale);
            double cf = 255.0 / (full ? (1 << h.Depth) - 1 : 224 * scale);
            double red = 2 * (1 - kr) * cf, blue = 2 * (1 - kb) * cf;
            double greenU = 2 * kb * (1 - kb) / kg * cf, greenV = 2 * kr * (1 - kr) / kg * cf;
            byte[] output = new byte[luma * 4];
            var options = new ParallelOptions { CancellationToken = token, MaxDegreeOfParallelism = Math.Max(1, Math.Min(4, Environment.ProcessorCount - 1)) };
            // Expand 4:2:0 chroma once horizontally, sharing it between adjacent luma rows.
            float[] expanded = null; int expandedSize = h.W * h.Ch;
            if (h.Chroma == "420") {
                expanded = new float[expandedSize * 2];
                Parallel.For(0, h.Ch, options, y => {
                    int src = y * h.Cw, dst = y * h.W;
                    for (int x = 0; x < h.W; ++x) {
                        int a, b; double f; Axis(x, loc == "center", h.Cw, out a, out b, out f);
                        int u = Sample(data, luma + src + a, h.Bytes), v = Sample(data, luma + chromaSize + src + a, h.Bytes);
                        expanded[dst + x] = (float)(u + (Sample(data, luma + src + b, h.Bytes) - u) * f - neutral);
                        expanded[expandedSize + dst + x] = (float)(v + (Sample(data, luma + chromaSize + src + b, h.Bytes) - v) * f - neutral);
                    }
                });
            }
            Parallel.For(0, h.H, options, y => {
                int row = y * h.W, cy0 = 0, cy1 = 0; double fy = 0;
                if (expanded != null) Axis(y, loc != "topleft" && loc != "top-left", h.Ch, out cy0, out cy1, out fy);
                for (int x = 0; x < h.W; ++x) {
                    double u = 0, v = 0;
                    if (expanded != null) {
                        int a = cy0 * h.W + x, b = cy1 * h.W + x;
                        u = expanded[a] + (expanded[b] - expanded[a]) * fy;
                        v = expanded[expandedSize + a] + (expanded[expandedSize + b] - expanded[expandedSize + a]) * fy;
                    } else if (h.Chroma == "422") {
                        int a, b; double f; Axis(x, loc == "center", h.Cw, out a, out b, out f); int cr = y * h.Cw;
                        int ua = Sample(data, luma + cr + a, h.Bytes), va = Sample(data, luma + chromaSize + cr + a, h.Bytes);
                        u = ua + (Sample(data, luma + cr + b, h.Bytes) - ua) * f - neutral;
                        v = va + (Sample(data, luma + chromaSize + cr + b, h.Bytes) - va) * f - neutral;
                    } else if (h.Chroma == "444") {
                        u = Sample(data, luma + row + x, h.Bytes) - neutral;
                        v = Sample(data, luma * 2 + row + x, h.Bytes) - neutral;
                    }
                    double yy = (Sample(data, row + x, h.Bytes) - black) * yf;
                    double r = yy + red * v, g = yy - greenU * u - greenV * v, bgr = yy + blue * u;
                    int dest = (row + x) * 4;
                    if (hdr) ToneMap(ref r, ref g, ref bgr, hlg, bt2020);
                    output[dest] = Clip(bgr); output[dest + 1] = Clip(g); output[dest + 2] = Clip(r); output[dest + 3] = 255;
                }
            });
            return output;
        }
        // Same display defaults/policy as HWEncVppPreview: white=203, peak=1000, knee=.75.
        static class HdrTables {
            public static readonly double[] Pq = Table(16384, PqNits);
            public static readonly double[] Hlg = Table(16384, HlgLinear);
            public static readonly double[] Ootf = Table(16384, x => 1000 * Math.Pow(x * x, 0.2));
            public static readonly double[] Gamma = Table(8192, x => 255 * Math.Pow(x * x, 1 / 2.4));
            static double[] Table(int size, Func<double,double> f) { var a = new double[size + 1]; for (int i=0;i<=size;i++) a[i]=f((double)i/size); return a; }
            static double PqNits(double x) {
                double p = Math.Pow(x, 32.0 / 2523);
                return 10000 * Math.Pow(Math.Max(p - 3424.0 / 4096, 0) / (2413.0 / 128 - 2392.0 / 128 * p), 16384.0 / 2610);
            }
            static double HlgLinear(double x) { return x <= .5 ? x*x/3 : (Math.Exp((x-.55991073)/.17883277)+.28466892)/12; }
        }
        static double Lookup(double[] table, double x) {
            double position = Math.Max(0, Math.Min(1, x)) * (table.Length - 1);
            int first = Math.Min((int)position, table.Length - 2);
            return table[first] + (table[first + 1] - table[first]) * (position - first);
        }
        static void ToneMap(ref double r, ref double g, ref double b, bool hlg, bool bt2020) {
            var table = hlg ? HdrTables.Hlg : HdrTables.Pq;
            r = Lookup(table, r/255); g = Lookup(table, g/255); b = Lookup(table, b/255);
            double norm = 1.0 / 203;
            if (hlg) norm *= Lookup(HdrTables.Ootf, Math.Sqrt(Math.Max(0, Math.Min(1, .2627*r+.6780*g+.0593*b))));
            r *= norm; g *= norm; b *= norm;
            double maximum = Math.Max(r, Math.Max(g,b)), peak = 1000.0 / 203;
            if (maximum > .75) {
                double delta = maximum - .75;
                double mapped = maximum >= peak ? 1 : .75 + delta / (1 + (4 - 1/(peak-.75)) * delta);
                double ratio = mapped/maximum; r *= ratio; g *= ratio; b *= ratio;
            }
            if (bt2020) {
                double rr = 1.6604910021*r-.5876411388*g-.0728498633*b;
                double gg = -.1245504745*r+1.1328998971*g-.0083494226*b;
                double bb = -.0181507634*r-.1005788980*g+1.1187296614*b;
                r=rr;g=gg;b=bb;
            }
            r = Lookup(HdrTables.Gamma, Math.Sqrt(Math.Max(0,Math.Min(1,r))));
            g = Lookup(HdrTables.Gamma, Math.Sqrt(Math.Max(0,Math.Min(1,g))));
            b = Lookup(HdrTables.Gamma, Math.Sqrt(Math.Max(0,Math.Min(1,b))));
        }
    }
    public sealed class LogTail {
        long offset;
        readonly Decoder decoder = new UTF8Encoding(false, false).GetDecoder();
        readonly byte[] bytes = new byte[65536];
        readonly char[] chars = new char[65537];
        string pending = "";
        public string[] Read(string path, bool flush) {
            var lines = new List<string>();
            if (!File.Exists(path)) return lines.ToArray();
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (file.Length < offset) { offset=0; decoder.Reset(); pending=""; }
                file.Position=offset; int budget=flush ? Int32.MaxValue : 262144;
                while (budget>0) {
                    int count=file.Read(bytes,0,Math.Min(bytes.Length,budget)); if(count==0) break;
                    offset=file.Position; budget-=count;
                    int n=decoder.GetChars(bytes,0,count,chars,0,false);
                    string text=pending+new string(chars,0,n); int start=0;
                    for(int i=0;i<text.Length;i++) if(text[i]=='\r'||text[i]=='\n') { if(i>start) lines.Add(text.Substring(start,i-start)); start=i+1; }
                    pending=text.Substring(start);
                    if(pending.Length>65536) { lines.Add(pending);pending=""; }
                }
            }
            if(flush && pending.Length>0) { lines.Add(pending);pending=""; }
            return lines.ToArray();
        }
    }
}
'@
    Add-Type -TypeDefinition $csSource -Language CSharp -ErrorAction Stop
}

# The optional DWM helper is separate from the unchanged preview worker types.
if (-not ('VppBoxTheme072.NativeTheme' -as [type])) {
$themeSource = @'
// VPPBox theme interop: optional native title-bar integration only.
using System;
using System.Runtime.InteropServices;
namespace VppBoxTheme072 {
    public static class NativeTheme {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
        public static bool TrySetDarkCaption(IntPtr window, bool dark) {
            if (window == IntPtr.Zero) return false;
            try {
                int enabled = dark ? 1 : 0;
                return DwmSetWindowAttribute(window, 20, ref enabled, sizeof(int)) >= 0;
            } catch (DllNotFoundException) { return false; }
              catch (EntryPointNotFoundException) { return false; }
        }
    }
}
'@
    Add-Type -TypeDefinition $themeSource -Language CSharp -ErrorAction Stop
}

# ------------------------------------------------------------ VPP filter catalog (syntax per rigaya option list)
# Params types: slider | combo | flag | text.  Type='bare' => "--opt value".  Type='plain' => "--opt <free text>".
$Script:FilterDefs = [ordered]@{
  deinterlace = @{ Title='Deinterlace (GPU)'; Opt='--vpp-deinterlace'; Group='Deinterlace & cadence'; Type='bare'; BareLabel='Mode'
    Tip='Hardware deinterlacer. "bob" doubles the frame rate and keeps full motion; "adaptive" is the usual choice.'
    Choices=@('normal','adaptive','bob'); Default='adaptive' }
  yadif = @{ Title='Yadif'; Opt='--vpp-yadif'; Group='Deinterlace & cadence'
    Tip='Good-quality deinterlacer. Use bff for DV/PAL-DV camcorders, tff for most broadcast HD. bob_* gives double frame rate.'
    Params=@(@{Key='mode';Label='Mode';Type='combo';Choices=@('auto','tff','bff','bob','bob_tff','bob_bff');Default='auto'}) }
  bwdif = @{ Title='Bwdif'; Opt='--vpp-bwdif'; Group='Deinterlace & cadence'; Type='plain'
    Tip='Yadif-derived deinterlacer with better edge handling. Optional parameters, e.g. mode=bob (empty = defaults).' }
  nnedi = @{ Title='NNEDI'; Opt='--vpp-nnedi'; Group='Deinterlace & cadence'; Type='plain'
    Tip='Neural-net edge-directed deinterlacer (slow, very clean). Optional parameters, e.g. field=bob,nns=32.' }
  rtgmc = @{ Title='RTGMC (QTGMC-style)'; Opt='--vpp-rtgmc'; Group='Deinterlace & cadence'; Type='plain'
    Tip='GPU port of QTGMC-style motion-compensated deinterlacing (where your build has it). Optional parameters; empty = defaults.' }
  afs = @{ Title='Auto Field Shift'; Opt='--vpp-afs'; Group='Deinterlace & cadence'
    Tip='Scene-adaptive deinterlace / inverse telecine; presets target anime and telecined film.'
    Params=@(@{Key='preset';Label='Preset';Type='combo';Choices=@('default','triple','double','anime','cinema','min_afterimg','24fps','30fps');Default='default'}
             @{Key='drop';Label='Drop dupes';Type='flag'}
             @{Key='smooth';Label='Smooth';Type='flag'}) }
  decimate = @{ Title='Decimate'; Opt='--vpp-decimate'; Group='Deinterlace & cadence'
    Tip='Drops the most similar frame in each cycle (IVTC clean-up, 30 -> 24 fps with cycle 5).'
    Params=@(@{Key='cycle';Label='Cycle';Type='slider';Min=2;Max=10;Step=1;Default=5;Fmt='0'}) }
  selectevery = @{ Title='Select every Nth'; Opt='--vpp-select-every'; Group='Deinterlace & cadence'; Type='bareint'
    Tip='Keeps one frame in N. Simple frame-rate reduction, e.g. after a bob deinterlace.'; Min=2; Max=8; Default=2 }
  knn = @{ Title='KNN denoise'; Opt='--vpp-knn'; Group='Denoise'
    Tip='K-nearest-neighbour denoiser: flat areas are smoothed, edges stay. Good general noise filter.'
    Params=@(@{Key='radius';Label='Radius';Type='slider';Min=1;Max=5;Step=1;Default=3;Fmt='0'}
             @{Key='strength';Label='Strength';Type='slider';Min=0;Max=1;Step=0.01;Default=0.08;Fmt='0.00'}
             @{Key='lerp';Label='Lerp';Type='slider';Min=0;Max=1;Step=0.01;Default=0.2;Fmt='0.00'}
             @{Key='th_lerp';Label='Lerp threshold';Type='slider';Min=0;Max=1;Step=0.01;Default=0.8;Fmt='0.00'}) }
  pmd = @{ Title='PMD denoise'; Opt='--vpp-pmd'; Group='Denoise'
    Tip='Anisotropic-diffusion denoiser; removes luma noise on low-light footage without flattening texture.'
    Params=@(@{Key='apply_count';Label='Passes';Type='slider';Min=1;Max=16;Step=1;Default=2;Fmt='0'}
             @{Key='strength';Label='Strength';Type='slider';Min=0;Max=100;Step=1;Default=100;Fmt='0'}
             @{Key='threshold';Label='Threshold';Type='slider';Min=0;Max=255;Step=1;Default=100;Fmt='0'}) }
  hqdn3d = @{ Title='HQDN3D'; Opt='--vpp-hqdn3d'; Group='Denoise'; Type='plain'
    Tip='Classic temporal+spatial denoiser, very fast. Optional parameters, e.g. strength=4 (empty = defaults).' }
  nlmeans = @{ Title='NL-Means'; Opt='--vpp-nlmeans'; Group='Denoise'; Type='plain'
    Tip='Non-local-means denoiser: best quality, heavier. Optional parameters, e.g. sigma=0.005.' }
  smooth = @{ Title='Smooth (QP based)'; Opt='--vpp-smooth'; Group='Denoise'
    Tip='Quality/QP based smoothing - gentle, encoder-friendly denoise.'
    Params=@(@{Key='quality';Label='Quality';Type='slider';Min=1;Max=6;Step=1;Default=3;Fmt='0'}
             @{Key='qp';Label='QP';Type='slider';Min=0;Max=100;Step=1;Default=20;Fmt='0'}) }
  gauss = @{ Title='Gaussian blur'; Opt='--vpp-gauss'; Group='Denoise'; Type='bare'; BareLabel='Size'
    Tip='Light blur: tames noise before sharpening. 3 = subtle, 7 = strong.'; Choices=@('3','5','7'); Default='3' }
  deblock = @{ Title='Deblock'; Opt='--vpp-deblock'; Group='Denoise'; Type='plain'
    Tip='Removes blocking from heavily compressed sources. Optional parameters, e.g. strength=2.' }
  unsharp = @{ Title='Unsharp mask'; Opt='--vpp-unsharp'; Group='Sharpen & edges'
    Tip='Restores edge contrast lost to denoising or resizing. Threshold keeps noise from being sharpened.'
    Params=@(@{Key='radius';Label='Radius';Type='slider';Min=1;Max=9;Step=1;Default=3;Fmt='0'}
             @{Key='weight';Label='Weight';Type='slider';Min=0;Max=10;Step=0.05;Default=0.5;Fmt='0.00'}
             @{Key='threshold';Label='Threshold';Type='slider';Min=0;Max=255;Step=1;Default=10;Fmt='0'}) }
  edgelevel = @{ Title='Edge level'; Opt='--vpp-edgelevel'; Group='Sharpen & edges'
    Tip='Local edge enhancement with little halo; good after a mild blur of tape footage.'
    Params=@(@{Key='strength';Label='Strength';Type='slider';Min=-31;Max=31;Step=1;Default=5;Fmt='0'}
             @{Key='threshold';Label='Threshold';Type='slider';Min=0;Max=255;Step=1;Default=20;Fmt='0'}
             @{Key='black';Label='Black';Type='slider';Min=0;Max=31;Step=1;Default=0;Fmt='0'}
             @{Key='white';Label='White';Type='slider';Min=0;Max=31;Step=1;Default=0;Fmt='0'}) }
  cas = @{ Title='CAS (contrast adaptive)'; Opt='--vpp-cas'; Group='Sharpen & edges'; Type='plain'
    Tip='AMD contrast-adaptive sharpening. Optional parameters, e.g. strength=0.5.' }
  warpsharp = @{ Title='Warp sharp'; Opt='--vpp-warpsharp'; Group='Sharpen & edges'
    Tip='Thins and sharpens lines (soft upscaled video, anime).'
    Params=@(@{Key='blur';Label='Blur';Type='slider';Min=1;Max=8;Step=1;Default=2;Fmt='0'}
             @{Key='depth';Label='Depth';Type='slider';Min=1;Max=128;Step=0.5;Default=16;Fmt='0.#'}
             @{Key='chroma';Label='Chroma too';Type='flag'}) }
  tweak = @{ Title='Color tweak'; Opt='--vpp-tweak'; Group='Color & banding'
    Tip='Brightness/contrast/gamma/saturation/hue - lift dark or faded footage.'
    Params=@(@{Key='brightness';Label='Brightness';Type='slider';Min=-1;Max=1;Step=0.01;Default=0;Fmt='0.00'}
             @{Key='contrast';Label='Contrast';Type='slider';Min=-2;Max=2;Step=0.01;Default=1;Fmt='0.00'}
             @{Key='gamma';Label='Gamma';Type='slider';Min=0.1;Max=10;Step=0.01;Default=1;Fmt='0.00'}
             @{Key='saturation';Label='Saturation';Type='slider';Min=0;Max=3;Step=0.01;Default=1;Fmt='0.00'}
             @{Key='hue';Label='Hue';Type='slider';Min=-180;Max=180;Step=1;Default=0;Fmt='0'}) }
  deband = @{ Title='Deband'; Opt='--vpp-deband'; Group='Color & banding'
    Tip='Removes banding steps in gradients (web/compressed sources); dither hides the repair.'
    Params=@(@{Key='range';Label='Range';Type='slider';Min=0;Max=127;Step=1;Default=15;Fmt='0'}
             @{Key='thre';Label='Threshold';Type='slider';Min=0;Max=31;Step=1;Default=15;Fmt='0'}
             @{Key='dither';Label='Dither';Type='slider';Min=0;Max=31;Step=1;Default=15;Fmt='0'}) }
  transform = @{ Title='Flip / transpose'; Opt='--vpp-transform'; Group='Geometry & size'; NeedsParam=$true
    Tip='Mirror or transpose the picture. Tick at least one option.'
    Params=@(@{Key='flip_x';Label='Flip horizontal';Type='flag'}
             @{Key='flip_y';Label='Flip vertical';Type='flag'}
             @{Key='transpose';Label='Transpose';Type='flag'}) }
  rotate = @{ Title='Rotate'; Opt='--vpp-rotate'; Group='Geometry & size'; Type='bare'; BareLabel='Angle'
    Tip='Rotate by 90, 180 or 270 degrees (phones filmed sideways).'; Choices=@('90','180','270'); Default='90' }
  resize = @{ Title='Resize'; Opt='--output-res'; Group='Geometry & size'; Type='resize'
    Tip='GPU resize. Pick the algorithm; empty width/height keep the source size.'
    Params=@(@{Key='w';Label='Width';Type='text'}
             @{Key='h';Label='Height';Type='text'}
             @{Key='algo';Label='Algorithm';Type='combo';Choices=@('default','bilinear','bicubic','spline36','lanczos3','lanczos4');Default='default'}) }
}
$Script:FilterOrder = @($Script:FilterDefs.Keys)
$Script:Ctrl = @{}

function Get-FilterArgsCore([switch]$IncludeResize) {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($id in $Script:FilterOrder) {
        $def = $Script:FilterDefs[$id]
        $on = $Script:Ctrl[$id + '|on']
        if (-not $on -or -not $on.IsChecked) { continue }
        switch ($def.Type) {
            'resize' {
                if (-not $IncludeResize) { break }
                $w = 0; $h = 0
                [void][int]::TryParse($Script:Ctrl[$id + '|w'].Text, [ref]$w)
                [void][int]::TryParse($Script:Ctrl[$id + '|h'].Text, [ref]$h)
                $algo = [string]$Script:Ctrl[$id + '|algo'].SelectedItem
                if ($algo -and $algo -ne 'default') { $list.Add('--vpp-resize'); $list.Add($algo) }
                if ($w -gt 0 -and $h -gt 0) { $list.Add('--output-res'); $list.Add(('{0}x{1}' -f $w, $h)) }
            }
            'bare'    { $list.Add($def.Opt); $list.Add([string]$Script:Ctrl[$id + '|value'].SelectedItem) }
            'bareint' { $list.Add($def.Opt); $list.Add([string][int]$Script:Ctrl[$id + '|value'].Value) }
            'plain'   { $list.Add($def.Opt); $t = $Script:Ctrl[$id + '|extra'].Text.Trim(); if ($t) { $list.Add($t) } }
            default {
                $pairs = New-Object System.Collections.Generic.List[string]
                foreach ($p in $def.Params) {
                    $c = $Script:Ctrl[$id + '|' + $p.Key]
                    switch ($p.Type) {
                        'slider' { $v = if ($p.Fmt -eq '0') { [string][int]$c.Value } else { Fmt-Num $c.Value }; $pairs.Add(('{0}={1}' -f $p.Key, $v)) }
                        'combo'  { $pairs.Add(('{0}={1}' -f $p.Key, [string]$c.SelectedItem)) }
                        'flag'   { if ($c.IsChecked) { $pairs.Add(('{0}=true' -f $p.Key)) } }
                    }
                }
                if ($pairs.Count -gt 0) { $list.Add($def.Opt); $list.Add(($pairs -join ',')) }
                elseif (-not $def.NeedsParam) { $list.Add($def.Opt) }
            }
        }
    }
    return $list.ToArray()
}

# ------------------------------------------------------------ command lines
# NOTE: callers always wrap results in @(...). Functions must NOT use "return ,$array" (that nests the array inside @()).
function Quote-Argument([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $e = $Value -replace '(\\*)"', '$1$1\"'
    $e = $e -replace '(\\+)$', '$1$1'
    return '"' + $e + '"'
}
function Command-LineText([string[]]$Parts) {
    $quoted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in $Parts) { $quoted.Add((Quote-Argument $part)) }
    return [string]::Join(' ', $quoted.ToArray())
}

function Get-Bitrate { $b = 0; if ([int]::TryParse($txt_bitrate.Text.Trim(), [ref]$b) -and $b -gt 0) { return $b }; return 8000 }

# Hardware decoding is opt-in. Use the same choice for encoding and preview.
function Get-DecoderArgument {
    if ($tgl_avhw.IsChecked -eq $true) { return '--avhw' }
    return '--avsw'
}

function Get-EncoderArguments([string]$InputPath, [string]$OutputPath) {
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add((Get-DecoderArgument))
    $a.Add('--codec'); $a.Add(@('h264','hevc','av1')[[Math]::Max(0, $cmb_codec.SelectedIndex)])
    switch ($cmb_mode.SelectedIndex) {
        1 { $a.Add('--vbr'); $a.Add([string](Get-Bitrate)) }
        2 { $a.Add('--cbr'); $a.Add([string](Get-Bitrate)) }
        default { $a.Add('--cqp'); $a.Add([string][int]$sl_quality.Value) }
    }
    $ts = $txt_trim_start.Text.Trim()
    if ($ts -match '^(\d+:)?\d+:\d+(\.\d+)?$') { $a.Add('--seek'); $a.Add($ts) }
    $fr = 0
    if ([int]::TryParse($txt_trim_frames.Text.Trim(), [ref]$fr) -and $fr -gt 0) { $a.Add('--frames'); $a.Add([string]$fr) }
    foreach ($x in @(Get-FilterArgsCore -IncludeResize)) { $a.Add($x) }
    if ($chk_audio.IsChecked) { $a.Add('--audio-copy') }
    $a.Add('-i'); $a.Add($InputPath); $a.Add('-o'); $a.Add($OutputPath)
    return $a.ToArray()
}

function Update-CommandPreview {
    if ($Script:Restoring -or $Script:Closing) { return }
    if ($Script:CommandTimer) { $Script:CommandTimer.Stop(); $Script:CommandTimer.Start() }
    else { Render-CommandPreview }
}
function Render-CommandPreview {
    if (-not $txt_command -or $Script:Restoring) { return }
    $exe = Get-SelectedEncoder; if (-not $exe) { $exe = 'NVEncC64.exe' }
    $inp = if ($txt_input.Text.Trim()) { $txt_input.Text.Trim() } else { 'INPUT.mkv' }
    $out = if ($txt_output.Text.Trim()) { $txt_output.Text.Trim() } else { 'OUTPUT.mp4' }
    $encArgs = @(Get-EncoderArguments $inp $out)
    $txt_command.Text = Command-LineText (@($exe) + $encArgs)
}

function Add-Log([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text) -or -not $txt_log) { return }
    if ($Text.Length -gt 65536) { $Text = $Text.Substring($Text.Length - 65536) }
    if ($txt_log.Text.Length -gt 250000) { $txt_log.Text = $txt_log.Text.Substring($txt_log.Text.Length - 180000) }
    $txt_log.AppendText($Text.TrimEnd() + "`r`n")
    if ($popup_settings.IsOpen -and $settings_tabs.SelectedIndex -eq 1) { $txt_log.ScrollToEnd() }
}
function Tail-LogFile([string]$Path, $Reader, [bool]$Flush) {
    if (-not $Reader) { return }
    try { $lines = $Reader.Read($Path, $Flush) } catch { return }
    $text = New-Object Text.StringBuilder
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '\[(\d+(?:\.\d+)?)%\]')
        if ($m.Success) {
            $pb_progress.Value = [Math]::Min(100, [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture))
            Set-Status ($line.Substring(0, [Math]::Min(140, $line.Length)))
        } else { [void]$text.AppendLine($line) }
    }
    if ($text.Length -gt 0) { Add-Log $text.ToString() }
}

# ------------------------------------------------------------ filter UI (no closures: state lives in .Tag)
function Add-Label($panel, [string]$text) {
    $lab = New-Object System.Windows.Controls.TextBlock
    $lab.Text = $text; $lab.Width = 110; $lab.VerticalAlignment = 'Center'; $lab.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MutedTextBrush')
    [void]$panel.Children.Add($lab)
}
function Update-SliderLabel($sl, $val, [string]$fmt) {
    if ($fmt -eq '0') { $val.Text = [string][int]$sl.Value } else { $val.Text = (Fmt-Num $sl.Value) }
}
function New-ComboControl($choices, [string]$default) {
    $cb = New-Object System.Windows.Controls.ComboBox
    foreach ($c in $choices) { [void]$cb.Items.Add([string]$c) }
    $cb.SelectedItem = [string]$default; $cb.MinWidth = 110
    $cb.Add_SelectionChanged({ Update-CommandPreview; Schedule-Preview })
    return $cb
}
function New-SliderControl($panel, $min, $max, $step, $default, [string]$fmt) {
    $sl = New-Object System.Windows.Controls.Slider
    $sl.Minimum = [double]$min; $sl.Maximum = [double]$max; $sl.Value = [double]$default
    $sl.VerticalAlignment = 'Center'; $sl.Margin = '4,0'
    if ($step -ge 1) { $sl.TickFrequency = [double]$step; $sl.IsSnapToTickEnabled = $true }
    $val = New-Object System.Windows.Controls.TextBlock
    $val.Width = 52; $val.TextAlignment = 'Right'; $val.VerticalAlignment = 'Center'; $val.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush'); $val.FontFamily = 'Consolas'
    $sl.Tag = @{ Lbl = $val; Fmt = $fmt }
    [Windows.Controls.DockPanel]::SetDock($val, 'Right'); [void]$panel.Children.Add($val); [void]$panel.Children.Add($sl)
    Update-SliderLabel $sl $val $fmt
    $sl.Add_ValueChanged({ param($s, $e) Update-SliderLabel $s $s.Tag.Lbl $s.Tag.Fmt; Update-CommandPreview; Schedule-Preview })
    return $sl
}

function Build-FilterPanel([string]$id, $def, $hostPanel) {
    $exp = New-Object System.Windows.Controls.Expander; $exp.IsExpanded = $false; $exp.Margin = '0,0,0,2'
    $head = New-Object System.Windows.Controls.StackPanel; $head.Orientation = 'Horizontal'
    $chk = New-Object System.Windows.Controls.CheckBox; $chk.Content = $def.Title; $chk.FontWeight = 'SemiBold'; $chk.VerticalAlignment = 'Center'
    $chk.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'TextBrush')
    [void]$head.Children.Add($chk)
    $ot = New-Object System.Windows.Controls.TextBlock; $ot.Text = $def.Opt; $ot.FontFamily = 'Consolas'; $ot.FontSize = 11
    $ot.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'AccentTextBrush'); $ot.VerticalAlignment = 'Center'; $ot.Margin = '8,0,0,0'
    [void]$head.Children.Add($ot)
    $exp.Header = $head; $exp.ToolTip = $def.Tip
    $body = New-Object System.Windows.Controls.StackPanel
    $tip = New-Object System.Windows.Controls.TextBlock
    $tip.Text = $def.Tip; $tip.TextWrapping = 'Wrap'; $tip.FontStyle = 'Italic'; $tip.FontSize = 11; $tip.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MutedTextBrush'); $tip.Margin = '10,2,8,6'
    [void]$body.Children.Add($tip)

    $type = [string]$def.Type
    if ($type -eq 'bare') {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '8,2,8,6'
        Add-Label $row $def.BareLabel
        $cb = New-ComboControl $def.Choices $def.Default
        [void]$row.Children.Add($cb); $Script:Ctrl[$id + '|value'] = $cb; [void]$body.Children.Add($row)
    }
    elseif ($type -eq 'bareint') {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '8,2,8,6'
        Add-Label $row 'N'
        $sl = New-SliderControl $row $def.Min $def.Max 1 $def.Default '0'
        $Script:Ctrl[$id + '|value'] = $sl; [void]$body.Children.Add($row)
    }
    elseif ($type -eq 'plain') {
        $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '8,2,8,6'
        Add-Label $row 'Parameters'
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.ToolTip = 'Optional, as accepted by the encoder (key=value,key=value). Empty = defaults.'
        $tb.Add_TextChanged({ Update-CommandPreview; Schedule-Preview })
        [void]$row.Children.Add($tb); $Script:Ctrl[$id + '|extra'] = $tb; [void]$body.Children.Add($row)
    }
    else {
        foreach ($p in $def.Params) {
            if ($p.Type -eq 'flag') {
                $fc = New-Object System.Windows.Controls.CheckBox; $fc.Content = $p.Label; $fc.Margin = '10,2,8,2'; $fc.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'MutedTextBrush')
                $fc.Add_Checked({ Update-CommandPreview; Schedule-Preview }); $fc.Add_Unchecked({ Update-CommandPreview; Schedule-Preview })
                [void]$body.Children.Add($fc); $Script:Ctrl[$id + '|' + $p.Key] = $fc
                continue
            }
            $row = New-Object System.Windows.Controls.DockPanel; $row.Margin = '8,2,8,2'
            Add-Label $row $p.Label
            switch ($p.Type) {
                'combo'  { $c = New-ComboControl $p.Choices $p.Default; [void]$row.Children.Add($c) }
                'text'   { $c = New-Object System.Windows.Controls.TextBox
                           $c.Add_TextChanged({ Update-CommandPreview; Schedule-Preview }); [void]$row.Children.Add($c) }
                default  { $c = New-SliderControl $row $p.Min $p.Max $p.Step $p.Default $p.Fmt }
            }
            $Script:Ctrl[$id + '|' + $p.Key] = $c
            [void]$body.Children.Add($row)
        }
    }
    $exp.Content = $body
    [void]$hostPanel.Children.Add($exp)
    $Script:Ctrl[$id + '|on'] = $chk; $Script:Ctrl[$id + '|panel'] = $exp
    $chk.Add_Checked({ Update-CommandPreview; Schedule-Preview }); $chk.Add_Unchecked({ Update-CommandPreview; Schedule-Preview })
}

function Build-AllFilterPanels($panelHost) {
    $groups = [ordered]@{}
    foreach ($id in $Script:FilterOrder) {
        $g = $Script:FilterDefs[$id].Group
        if (-not $groups.Contains($g)) { $groups[$g] = New-Object System.Collections.Generic.List[string] }
        $groups[$g].Add($id)
    }
    foreach ($g in $groups.Keys) {
        $box = New-Object System.Windows.Controls.Border
        $box.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'SurfaceAltBrush'); $box.CornerRadius = 8; $box.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'BorderBrush'); $box.BorderThickness = 1
        $box.Padding = 10; $box.Margin = '0,0,0,10'
        $sp = New-Object System.Windows.Controls.StackPanel
        $gt = New-Object System.Windows.Controls.TextBlock
        $gt.Text = $g.ToUpper(); $gt.FontSize = 12.5; $gt.FontWeight = 'Bold'; $gt.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'AccentTextBrush'); $gt.Margin = '0,0,0,6'
        [void]$sp.Children.Add($gt)
        foreach ($id in $groups[$g]) { Build-FilterPanel $id $Script:FilterDefs[$id] $sp }
        $box.Child = $sp
        [void]$panelHost.Children.Add($box)
    }
}

# ------------------------------------------------------------ non-blocking encoder capability discovery
function Apply-EncoderFeatures($Features) {
    $saved = $Script:Restoring; $Script:Restoring = $true
    try {
        foreach ($id in $Script:FilterOrder) {
            $def = $Script:FilterDefs[$id]
            $chk = $Script:Ctrl[$id + '|on']; $exp = $Script:Ctrl[$id + '|panel']
            $ok = $Features.Count -eq 0 -or $def.Type -eq 'resize' -or $Features.ContainsKey($def.Opt.TrimStart('-').ToLowerInvariant())
            $chk.IsEnabled = $ok; $exp.Opacity = if ($ok) { 1.0 } else { 0.4 }
            if (-not $ok) { $chk.IsChecked = $false; $exp.IsExpanded = $false }
        }
    } finally { $Script:Restoring = $saved }
    Update-CommandPreview
}
function Update-EncoderCapabilities {
    if ($Script:CapsJob) { $Script:CapsJob.Cancel(); $Script:CapsJob = $null }
    $exe = Get-SelectedEncoder
    if (-not $exe) { return }
    try {
        $key = Get-FileIdentity $exe
        if ($Script:CapsCache.ContainsKey($key)) { Apply-EncoderFeatures $Script:CapsCache[$key]; return }
        $Script:CapsKey = $key; $Script:CapsExe = $exe
        $Script:CapsJob = [VppBox07.CaptureJob]::Start($exe, '--help', 10, $null, 0)
        $Script:CapsTimer.Start()
    } catch { Add-Log ('Cannot read encoder capabilities: ' + $_.Exception.Message) }
}
function Poll-EncoderCapabilities {
    if (-not $Script:CapsJob -or -not $Script:CapsJob.Completion.IsCompleted) { return }
    $Script:CapsTimer.Stop()
    try {
        $result = $Script:CapsJob.Completion.GetAwaiter().GetResult(); $Script:CapsJob = $null
        if ($result.Cancelled -or (Get-SelectedEncoder) -ne $Script:CapsExe) { return }
        $features = @{}
        if ($result.ExitCode -eq 0) {
            foreach ($m in [regex]::Matches(($result.Output + "`n" + $result.Error), '(?<!\S)--(vpp-[a-zA-Z0-9\-]+)\b')) { $features[$m.Groups[1].Value.ToLowerInvariant()] = $true }
        }
        if ($features.Count -lt 5) {
            $features = @{}
            Add-Log 'Encoder capabilities could not be verified; filters remain available and the encoder will validate them.'
        } else { $Script:CapsCache[$Script:CapsKey] = $features }
        Apply-EncoderFeatures $features
        Schedule-Preview
    } catch { Add-Log ('Capability probe failed: ' + $_.Exception.Message) }
}

# ------------------------------------------------------------ preview: official CLI JSON + selected Y4M frame
function Resolve-PreviewCli {
    $manual = $txt_preview_cli.Text.Trim().Trim('"')
    if ($manual) {
        if ([IO.File]::Exists($manual)) { return [IO.Path]::GetFullPath($manual) }
        throw 'The configured HWEncVppPreview.Cli.exe does not exist. Open Settings > ENCODER.'
    }
    $folders = New-Object 'System.Collections.Generic.List[string]'
    $folders.Add($Script:Root)
    $encoder = Get-SelectedEncoder
    if ($encoder) { $folders.Add([IO.Path]::GetDirectoryName($encoder)) }
    foreach ($folder in $folders) {
        foreach ($sub in @('', 'HWEncVppPreview', 'preview-cli')) {
            $base = if ($sub) { Join-Path $folder $sub } else { $folder }
            $path = Join-Path $base 'HWEncVppPreview.Cli.exe'
            if ([IO.File]::Exists($path)) { return [IO.Path]::GetFullPath($path) }
        }
    }
    $command = Get-Command 'HWEncVppPreview.Cli.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    throw 'Preview requires HWEncVppPreview.Cli.exe (not HWEncVppPreview.exe). Select it in Settings > ENCODER, or place its published files in preview-cli beside this script. Encoding does not require the CLI.'
}
function ConvertTo-PreviewSeconds([string]$Text) {
    $t = $Text.Trim(); $value = 0.0
    $m = [regex]::Match($t, '^(?:(?<h>\d+):)?(?<m>\d+):(?<s>\d{1,2}(?:\.\d+)?)$')
    if ($m.Success) {
        $minutes = [double]::Parse($m.Groups['m'].Value, [Globalization.CultureInfo]::InvariantCulture)
        $seconds = [double]::Parse($m.Groups['s'].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($seconds -ge 60 -or ($m.Groups['h'].Success -and $minutes -ge 60)) { throw 'Invalid time: minutes/seconds must be below 60 in HH:MM:SS.' }
        $hours = if ($m.Groups['h'].Success) { [double]::Parse($m.Groups['h'].Value, [Globalization.CultureInfo]::InvariantCulture) } else { 0 }
        $value = $hours * 3600 + $minutes * 60 + $seconds
    } elseif ($t -notmatch '^\d+(?:\.\d+)?$' -or -not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        throw 'Time must be HH:MM:SS.mmm, MM:SS.mmm or seconds (decimal point).'
    }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt [TimeSpan]::MaxValue.TotalSeconds) { throw 'Preview time is out of range.' }
    return $value
}
function Get-FileIdentity([string]$Path) {
    $info = Get-Item -LiteralPath $Path -ErrorAction Stop
    return ('{0}|{1}|{2}' -f $info.FullName, $info.Length, $info.LastWriteTimeUtc.Ticks)
}
function Clear-PreviewDisplay([string]$Message) {
    $img_original.Source = $null; $img_processed.Source = $null
    $divider.Visibility = 'Collapsed'; $labels.Visibility = 'Collapsed'
    $txt_preview_placeholder.Text = $Message; $txt_preview_placeholder.Visibility = 'Visible'
}
function Schedule-Preview {
    if ($Script:Restoring -or -not $Script:UiReady -or $Script:Closing) { return }
    $Script:PreviewGeneration++
    if ($Script:Pv.Busy) { Cancel-Preview }
    Clear-PreviewDisplay 'Preview pending...'
    if ($Script:QueueActive) { $lbl_preview_status.Text = 'Preview paused while encoding'; return }
    $lbl_preview_status.Text = 'Waiting for edits to settle...'
    $Script:PreviewTimer.Stop(); $Script:PreviewTimer.Start()
}
function Remove-PvFiles($State) {
    if (-not $State -or -not $State.Directory) { return }
    $task = if ($State.FrameJob) { $State.FrameJob.Completion } elseif ($State.Job) { $State.Job.Completion } else { $null }
    for ($i = $Script:CleanupTasks.Count - 1; $i -ge 0; $i--) { if ($Script:CleanupTasks[$i].IsCompleted) { $Script:CleanupTasks.RemoveAt($i) } }
    $Script:CleanupTasks.Add([VppBox07.Cleanup]::DirectoryAfter($task, [string]$State.Directory))
    $State.Directory = $null
}
function Cancel-Preview {
    $pv = $Script:Pv
    if ($Script:PvTimer) { $Script:PvTimer.Stop() }
    if ($pv.Job) { $pv.Job.Cancel() }
    if ($pv.FrameJob) { $pv.FrameJob.Cancel() }
    Remove-PvFiles $pv
    $Script:Pv = @{ Busy = $false }
    $btn_preview.IsEnabled = $true
}
function Stop-Preview([string]$Message) {
    $pv = $Script:Pv
    $Script:PvTimer.Stop(); Remove-PvFiles $pv
    $Script:Pv = @{ Busy = $false }; $btn_preview.IsEnabled = $true
    if ($Message) {
        Clear-PreviewDisplay 'Preview unavailable. Open Settings > PROCESSING LOG for details.'
        $lbl_preview_status.Text = 'Preview failed - see processing log'; $lbl_preview_status.ToolTip = $Message
        Add-Log $Message
    }
}
function Start-PvAttempt {
    $pv = $Script:Pv
    $pv.Directory = Join-Path ([IO.Path]::GetTempPath()) ('vppbox-preview-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($pv.Directory)
    $pv.Out = Join-Path $pv.Directory 'segment.y4m'
    $a = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in @('--enc', $pv.Exe, '--input', $pv.Input, '--time', $pv.Time, '--mode', 'auto',
        '--input-args', $pv.Decoder, '--pre-margin', (Fmt-Num $PreviewPreMarginSeconds), '--post-margin', (Fmt-Num $PreviewPostMarginSeconds),
        '--watchdog-seconds', '30', '--dump-y4m', $pv.Out)) { $a.Add([string]$part) }
    if ($pv.Stage -eq 'vpp') { $a.Add('--vpp'); $a.Add((Command-LineText $pv.Filters)) }
    $pv.Cmd = Command-LineText (@($pv.Cli) + $a.ToArray())
    $pv.Meta = $null; $pv.FrameJob = $null
    $lbl_preview_status.Text = if ($pv.Stage -eq 'src') { 'Selecting source frame...' } else { 'Applying filters and selecting output frame...' }
    $pv.Job = [VppBox07.CaptureJob]::Start($pv.Cli, (Command-LineText $a.ToArray()), $PreviewTimeoutSeconds, $pv.Out, $PreviewMaxDumpBytes)
    $Script:PvTimer.Start()
}
function Complete-Preview {
    $pv = $Script:Pv
    if ($pv.Gen -ne $Script:PreviewGeneration) { Cancel-Preview; return }
    $source = $pv.Source; $processed = if ($pv.Processed) { $pv.Processed } else { $source }
    $img_original.Source = $source.Bitmap; $img_processed.Source = $processed.Bitmap
    $txt_preview_placeholder.Visibility = 'Collapsed'
    $lbl_preview_status.Text = '{0}s | {1} | {2}' -f $pv.Time, $pv.Decoder.TrimStart('-'), $processed.Description
    $lbl_preview_status.ToolTip = ('Source: index {0}, Xts={1}; processed: index {2}, Xts={3}. Requested time: {4}s.' -f
        $source.Meta.selectedIndex, $source.Meta.selectedXts, $processed.Meta.selectedIndex, $processed.Meta.selectedXts, $pv.Time)
    Update-Comparison
    Stop-Preview ''
}
function Poll-Preview {
    $pv = $Script:Pv
    if (-not $pv.Busy) { return }
    if ($pv.Gen -ne $Script:PreviewGeneration) { Cancel-Preview; return }
    try {
        if ($pv.FrameJob) {
            if (-not $pv.FrameJob.Completion.IsCompleted) { return }
            $frame = $pv.FrameJob.Completion.GetAwaiter().GetResult()
            $sar = [double]$frame.SarNum / $frame.SarDen
            $bitmap = [Windows.Media.Imaging.BitmapSource]::Create($frame.Width, $frame.Height, (96.0 / $sar), 96,
                [Windows.Media.PixelFormats]::Bgra32, $null, $frame.Bgra, $frame.Width * 4)
            $bitmap.Freeze()
            $entry = @{ Bitmap = $bitmap; Meta = $pv.Meta; Description = $frame.ColorDescription }
            if ($frame.Warning) { Add-Log ('Preview ' + $pv.Stage + ': ' + $frame.Warning) }
            if (-not $pv.Meta.trustedAbsolute) { Add-Log ('Preview ' + $pv.Stage + ': CLI used a relative/legacy timestamp clock (absolute timestamp alignment is not guaranteed).') }
            Remove-PvFiles $pv; $pv.FrameJob = $null; $pv.Job = $null
            if ($pv.Stage -eq 'src') {
                $pv.Source = $entry; $entry.Decoder = $pv.Decoder
                $Script:PvCache.SrcKey = $pv.SrcKey; $Script:PvCache.Source = $entry
                $Script:PvCache.PrcKey = ''; $Script:PvCache.Processed = $null
                if ($pv.Filters.Count -gt 0) { $pv.Stage = 'vpp'; Start-PvAttempt; return }
            } else {
                $pv.Processed = $entry
                $Script:PvCache.PrcKey = $pv.PrcKey; $Script:PvCache.Processed = $entry
            }
            Complete-Preview; return
        }
        if (-not $pv.Job -or -not $pv.Job.Completion.IsCompleted) { return }
        $result = $pv.Job.Completion.GetAwaiter().GetResult()
        if ($result.Cancelled) { Cancel-Preview; return }
        $meta = $null
        try { $meta = $result.Output.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { }
        if ($result.ExitCode -ne 0 -or -not $meta -or $meta.error -or $meta.rc -ne 0 -or $meta.timedOut) {
            $detail = 'CLI exit={0}; rc={1}; {2}; {3}; {4}' -f $result.ExitCode, $meta.rc, $meta.error, $meta.stderrTail, $result.Error
            if ($pv.Stage -eq 'src' -and $pv.Decoder -eq '--avhw' -and -not $result.TimedOut -and -not $meta.timedOut) {
                Add-Log ('Hardware preview failed; retrying source and processed frames with --avsw. Encoding still uses the selected decoder; switch Hardware decoder OFF in Settings to use --avsw for encoding too. ' + $detail)
                Remove-PvFiles $pv; $pv.Decoder = '--avsw'; Start-PvAttempt; return
            }
            throw $detail
        }
        if ($null -eq $meta.selectedIndex -or [int]$meta.selectedIndex -lt 0 -or [int]$meta.selectedIndex -ge [int]$meta.frameCount) { throw 'CLI did not return a valid selectedIndex.' }
        if ($meta.targetNotReached) { throw 'The CLI reports targetNotReached. No potentially incorrect before/after frame is displayed.' }
        if (-not [IO.File]::Exists($pv.Out)) { throw 'CLI did not create the Y4M dump.' }
        if ((Get-Item -LiteralPath $pv.Out).Length -gt $PreviewMaxDumpBytes) { throw 'Preview Y4M dump exceeds PreviewMaxDumpBytes.' }
        $pv.Meta = $meta
        $lbl_preview_status.Text = 'Converting selected frame for display...'
        $pv.FrameJob = [VppBox07.FrameJob]::Start($pv.Out, [int]$meta.selectedIndex, [int]$meta.width, [int]$meta.height,
            [int]$meta.bitDepth, [string]$meta.chroma, [string]$meta.sha256)
    } catch {
        Stop-Preview ('Preview ' + $pv.Stage + ' failed: ' + $_.Exception.Message + "`r`nCommand: " + $pv.Cmd)
    }
}
function Start-PreviewRender {
    if ($Script:Closing -or $Script:QueueActive) { return }
    $Script:PreviewTimer.Stop()
    if ($Script:CapsJob -and -not $Script:CapsJob.Completion.IsCompleted) {
        $lbl_preview_status.Text = 'Waiting for encoder capabilities...'; $Script:PreviewTimer.Start(); return
    }
    if ($Script:Pv.Busy) { Cancel-Preview }
    try {
        $inputPath = $txt_input.Text.Trim().Trim('"')
        if (-not [IO.File]::Exists($inputPath)) { Clear-PreviewDisplay 'Choose a valid source video.'; $lbl_preview_status.Text = 'Choose a valid source video'; return }
        $inputPath = [IO.Path]::GetFullPath($inputPath)
        $exe = Get-SelectedEncoder
        if (-not $exe) { throw 'No encoder selected. Open Settings > ENCODER.' }
        $cli = Resolve-PreviewCli
        $time = (ConvertTo-PreviewSeconds $txt_preview_time.Text).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        $filters = @(Get-FilterArgsCore -IncludeResize)
        $decoder = Get-DecoderArgument
        $keyParts = @((Get-FileIdentity $inputPath), (Get-FileIdentity $exe), (Get-FileIdentity $cli), $time,
            $decoder, $PreviewPreMarginSeconds, $PreviewPostMarginSeconds)
        $srcKey = ConvertTo-Json -InputObject $keyParts -Compress
        $prcKey = $srcKey + "`n" + (Command-LineText $filters)
        $pv = @{ Busy = $true; Gen = $Script:PreviewGeneration; Exe = $exe; Cli = $cli; Input = $inputPath; Time = $time;
            Filters = $filters; SrcKey = $srcKey; PrcKey = $prcKey; Stage = 'src'; Source = $null; Processed = $null;
            Decoder = $decoder; Directory = $null; Job = $null; FrameJob = $null }
        $Script:Pv = $pv
        if ($Script:PvCache.SrcKey -eq $srcKey -and $Script:PvCache.Source) {
            $pv.Source = $Script:PvCache.Source; $pv.Decoder = $pv.Source.Decoder
            if ($filters.Count -eq 0) { Complete-Preview; return }
            if ($Script:PvCache.PrcKey -eq $prcKey -and $Script:PvCache.Processed) { $pv.Processed = $Script:PvCache.Processed; Complete-Preview; return }
            $pv.Stage = 'vpp'
        }
        Clear-PreviewDisplay 'Building before / after preview...'
        Start-PvAttempt
    } catch { Stop-Preview $_.Exception.Message }
}

# ------------------------------------------------------------ always-split comparison; clip the layer, not the Image
function Get-PreviewBounds {
    $gw = [double]$preview_grid.ActualWidth; $gh = [double]$preview_grid.ActualHeight
    $rw = 0.0; $rh = 0.0
    foreach ($bmp in @($img_original.Source, $img_processed.Source)) {
        if (-not $bmp -or $bmp.Width -le 0 -or $bmp.Height -le 0) { continue }
        $scale = [Math]::Min($gw / $bmp.Width, $gh / $bmp.Height)
        $rw = [Math]::Max($rw, $bmp.Width * $scale); $rh = [Math]::Max($rh, $bmp.Height * $scale)
    }
    return @{ GW = $gw; GH = $gh; W = $rw; H = $rh; Ox = ($gw - $rw) / 2; Oy = ($gh - $rh) / 2 }
}
function Update-Comparison {
    if (-not $preview_grid -or $preview_grid.ActualWidth -le 0 -or $preview_grid.ActualHeight -le 0) { return }
    if (-not $img_original.Source -or -not $img_processed.Source) { $divider.Visibility = 'Collapsed'; $labels.Visibility = 'Collapsed'; return }
    $b = Get-PreviewBounds
    $x = $b.Ox + $b.W * $Script:SplitPosition
    $clip_original.Rect = New-Object System.Windows.Rect(0, 0, $x, $b.GH)
    $divider.Height = $b.H; $divider.Margin = New-Object System.Windows.Thickness(($x - 1.5), $b.Oy, 0, 0)
    $labels.Margin = New-Object System.Windows.Thickness($b.Ox, $b.Oy, $b.Ox, $b.Oy)
    $divider.Visibility = 'Visible'; $labels.Visibility = 'Visible'
}
function Set-SplitFromMouse($Point) {
    $b = Get-PreviewBounds
    if ($b.W -le 0) { return }
    $Script:SplitPosition = [Math]::Max(0.0, [Math]::Min(1.0, ($Point.X - $b.Ox) / $b.W))
    Update-Comparison
}

# ------------------------------------------------------------ presets
$Script:PresetFile = Join-Path $Script:Root 'vppbox-presets.json'
$Script:BuiltinPresets = [ordered]@{
  'No VPP' = @{}
  'VHS / analog capture' = @{
    yadif  = @{On=$true; Values=@{mode='auto'}}
    knn    = @{On=$true; Values=@{radius=3; strength=0.10; lerp=0.2; th_lerp=0.8}}
    deband = @{On=$true; Values=@{range=15; thre=16; dither=12}}
    tweak  = @{On=$true; Values=@{saturation=1.05; contrast=1.03}}
  }
  'DV / HDV camcorder (BFF)' = @{
    yadif     = @{On=$true; Values=@{mode='bff'}}
    edgelevel = @{On=$true; Values=@{strength=4; threshold=20}}
  }
  'DVD / broadcast' = @{
    unsharp = @{On=$true; Values=@{radius=3; weight=0.35; threshold=10}}
    deband  = @{On=$true; Values=@{range=23; thre=16; dither=12}}
  }
  'Anime' = @{
    deband  = @{On=$true; Values=@{range=23; thre=20; dither=15}}
    unsharp = @{On=$true; Values=@{radius=3; weight=0.30; threshold=8}}
  }
  'Low-light / noisy' = @{
    pmd = @{On=$true; Values=@{apply_count=4; strength=80; threshold=90}}
    knn = @{On=$true; Values=@{radius=4; strength=0.15}}
  }
  'Upscale to 4K' = @{
    resize  = @{On=$true; Values=@{w='3840'; h='2160'; algo='lanczos3'}}
    unsharp = @{On=$true; Values=@{radius=3; weight=0.30; threshold=10}}
  }
}

function Get-SettingsSnapshot {
    $s = [ordered]@{}
    foreach ($id in $Script:FilterOrder) {
        $def = $Script:FilterDefs[$id]; $vals = [ordered]@{}; $type = [string]$def.Type
        if ($type -eq 'bare')        { $vals['value'] = [string]$Script:Ctrl[$id + '|value'].SelectedItem }
        elseif ($type -eq 'bareint') { $vals['value'] = [int]$Script:Ctrl[$id + '|value'].Value }
        elseif ($type -eq 'plain')   { $vals['extra'] = $Script:Ctrl[$id + '|extra'].Text }
        else {
            foreach ($p in $def.Params) {
                $c = $Script:Ctrl[$id + '|' + $p.Key]
                switch ($p.Type) {
                    'slider' { $vals[$p.Key] = [Math]::Round($c.Value, 3) }
                    'combo'  { $vals[$p.Key] = [string]$c.SelectedItem }
                    'flag'   { $vals[$p.Key] = [bool]$c.IsChecked }
                    'text'   { $vals[$p.Key] = [string]$c.Text }
                }
            }
        }
        $s[$id] = [ordered]@{ On = [bool]$Script:Ctrl[$id + '|on'].IsChecked; Values = $vals }
    }
    return $s
}

function Restore-Settings($preset) {
    $Script:Restoring = $true
    try {
        foreach ($id in $Script:FilterOrder) {
            $Script:Ctrl[$id + '|on'].IsChecked = $false
            if (-not $preset.Contains($id)) { continue }
            $entry = $preset[$id]; $def = $Script:FilterDefs[$id]; $type = [string]$def.Type
            if ($type -eq 'bare')        { if ($entry.Values.Contains('value')) { $Script:Ctrl[$id + '|value'].SelectedItem = [string]$entry.Values['value'] } }
            elseif ($type -eq 'bareint') { if ($entry.Values.Contains('value')) { $Script:Ctrl[$id + '|value'].Value = [double]$entry.Values['value'] } }
            elseif ($type -eq 'plain')   { if ($entry.Values.Contains('extra')) { $Script:Ctrl[$id + '|extra'].Text = [string]$entry.Values['extra'] } }
            else {
                foreach ($key in @($entry.Values.Keys)) {
                    $c = $Script:Ctrl[$id + '|' + $key]; if (-not $c) { continue }
                    $pdef = $def.Params | Where-Object { $_.Key -eq $key } | Select-Object -First 1
                    if (-not $pdef) { continue }
                    switch ($pdef.Type) {
                        'slider' { $c.Value = [double]$entry.Values[$key] }
                        'combo'  { $c.SelectedItem = [string]$entry.Values[$key] }
                        'flag'   { $c.IsChecked = [bool]$entry.Values[$key] }
                        'text'   { $c.Text = [string]$entry.Values[$key] }
                    }
                }
            }
            if ($entry.On -and $Script:Ctrl[$id + '|on'].IsEnabled) { $Script:Ctrl[$id + '|on'].IsChecked = $true }
        }
    } finally { $Script:Restoring = $false }
    Update-CommandPreview
    Schedule-Preview
}

$Script:UserPresets = [ordered]@{}
function Load-UserPresets {
    $Script:UserPresets = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Script:PresetFile)) { return }
    try {
        $data = Get-Content -LiteralPath $Script:PresetFile -Raw | ConvertFrom-Json
        foreach ($item in @($data)) {
            $ht = @{}
            foreach ($prop in $item.Settings.PSObject.Properties) {
                $sub = @{ On = [bool]$prop.Value.On; Values = @{} }
                foreach ($vp in $prop.Value.Values.PSObject.Properties) { $sub.Values[$vp.Name] = $vp.Value }
                $ht[$prop.Name] = $sub
            }
            $Script:UserPresets[[string]$item.Name] = $ht
        }
    } catch { }
}
function Save-UserPresets {
    $out = @()
    foreach ($name in $Script:UserPresets.Keys) { $out += [pscustomobject]@{ Name = $name; Settings = $Script:UserPresets[$name] } }
    ConvertTo-Json -InputObject @($out) -Depth 8 | Set-Content -LiteralPath $Script:PresetFile -Encoding UTF8 -ErrorAction Stop
}
function Refresh-PresetCombo {
    $Script:Restoring = $true
    $cmb_preset.Items.Clear()
    foreach ($name in $Script:BuiltinPresets.Keys) { [void]$cmb_preset.Items.Add([string]$name) }
    foreach ($name in $Script:UserPresets.Keys)    { [void]$cmb_preset.Items.Add('* ' + $name) }
    if ($cmb_preset.Items.Count -gt 0) { $cmb_preset.SelectedIndex = 0 }
    $Script:Restoring = $false
}


# ------------------------------------------------------------ queue (immutable per-run command snapshots)
function Suggest-Output {
    $inp = $txt_input.Text.Trim(); if (-not $inp) { return }
    if ($txt_output.Text.Trim() -and $txt_output.Text -ne $Script:SuggestedOutput) { return }
    try {
        $Script:SuggestedOutput = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($inp))) ([IO.Path]::GetFileNameWithoutExtension($inp) + '_vpp.mp4')
        $txt_output.Text = $Script:SuggestedOutput
    } catch { }
}
function Add-QueueFiles($Files) {
    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $lst_queue.Items) { [void]$known.Add([string]$item) }
    foreach ($file in $Files) {
        if (-not [IO.File]::Exists([string]$file)) { continue }
        $path = [IO.Path]::GetFullPath([string]$file)
        if ($known.Add($path)) { [void]$lst_queue.Items.Add($path) }
    }
    if (-not $txt_input.Text -and $lst_queue.Items.Count -gt 0) { $lst_queue.SelectedIndex = 0 }
    Update-CommandPreview
}
function Browse-Videos {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = 'Add videos to the queue'; $dialog.Multiselect = $true
        $dialog.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.webm;*.vob;*.mpg;*.mpeg;*.mxf;*.dv|All files|*.*'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-QueueFiles $dialog.FileNames }
    } finally { $dialog.Dispose() }
}
function Browse-Output {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $dialog.Title = 'Choose a new output video'; $dialog.Filter = 'MP4|*.mp4|Matroska|*.mkv|MPEG-TS|*.ts|All files|*.*'
        $dialog.FileName = if ($txt_output.Text) { [IO.Path]::GetFileName($txt_output.Text) } else { 'output.mp4' }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txt_output.Text = $dialog.FileName; Update-CommandPreview }
    } finally { $dialog.Dispose() }
}
function Start-Queue {
    if ($Script:QueueActive) { return }
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $lst_queue.Items) { $items.Add([string]$item) }
    if ($items.Count -eq 0 -and [IO.File]::Exists($txt_input.Text.Trim())) { $items.Add([IO.Path]::GetFullPath($txt_input.Text.Trim())) }
    try {
        if ($items.Count -eq 0) { throw 'Add a valid source video.' }
        if ($cmb_mode.SelectedIndex -ne 0) {
            $bitrate = 0
            if (-not [int]::TryParse($txt_bitrate.Text.Trim(), [ref]$bitrate) -or $bitrate -le 0) { throw 'Bitrate must be a positive integer (kbps).' }
        }
        if ($txt_trim_start.Text.Trim()) {
            if ($txt_trim_start.Text.Trim() -notmatch '^(\d+:)?\d+:\d+(\.\d+)?$') { throw 'Trim start must be HH:MM:SS.mmm or MM:SS.mmm.' }
            $null = ConvertTo-PreviewSeconds $txt_trim_start.Text
        }
        if ($txt_trim_frames.Text.Trim()) {
            $frames = 0
            if (-not [int]::TryParse($txt_trim_frames.Text.Trim(), [ref]$frames) -or $frames -le 0) { throw 'Max frames must be a positive integer, or empty.' }
        }
        Suggest-Output
        if (-not $txt_output.Text.Trim()) { throw 'Choose an output video.' }
        $encoder = Get-SelectedEncoder
        if (-not $encoder) { throw 'No encoder selected. Open Settings > ENCODER.' }
        $jobs = New-Object 'System.Collections.Generic.List[object]'
        $destinations = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $sources = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($inputPath in $items) { [void]$sources.Add([IO.Path]::GetFullPath($inputPath)) }
        $chosen = [IO.Path]::GetFullPath($txt_output.Text.Trim()); $folder = [IO.Path]::GetDirectoryName($chosen)
        if (-not [IO.Directory]::Exists($folder)) { throw 'The output directory does not exist.' }
        $ext = [IO.Path]::GetExtension($chosen); if (-not $ext) { $ext = '.mp4' }
        foreach ($inputPath in $items) {
            if (-not [IO.File]::Exists($inputPath)) { throw ('Input not found: ' + $inputPath) }
            $outputPath = if ($items.Count -eq 1) { $chosen } else { Join-Path $folder ([IO.Path]::GetFileNameWithoutExtension($inputPath) + '_vpp' + $ext) }
            if ($sources.Contains($outputPath)) { throw ('Output would overwrite a source: ' + $outputPath) }
            if (-not $destinations.Add($outputPath)) { throw ('Duplicate destination in queue: ' + $outputPath) }
            if ([IO.File]::Exists($outputPath)) { throw ('Output already exists. Choose a new destination: ' + $outputPath) }
            $jobs.Add(@{ Input = $inputPath; Output = $outputPath; Arguments = @(Get-EncoderArguments $inputPath $outputPath) })
        }
        $Script:QueueJobs = $jobs; $Script:QueueIndex = 0; $Script:Encoder = $encoder; $Script:QueueFailures = 0; $Script:QueueActive = $true
        Set-Status 'Preparing encoding queue...'
        $Script:PreviewTimer.Stop(); Cancel-Preview
        $lbl_preview_status.Text = 'Preview paused while encoding'
        $btn_start.IsEnabled = $false; $btn_stop.IsEnabled = $true; $btn_preview.IsEnabled = $false
        $pb_progress.Value = 0
        Add-Log ('Starting queue: ' + $jobs.Count + ' item(s); settings frozen for this run.')
        Start-NextEncode
    } catch {
        Set-Status ('Cannot start queue: ' + $_.Exception.Message)
        Add-Log $lbl_status.Text
        [void][Windows.MessageBox]::Show($_.Exception.Message, 'Cannot start queue', 'OK', 'Warning')
    }
}
function Start-NextEncode {
    while ($Script:QueueIndex -lt $Script:QueueJobs.Count) {
        $job = $Script:QueueJobs[$Script:QueueIndex]
        try {
            if (-not [IO.File]::Exists($job.Input)) { throw ('Input no longer exists: ' + $job.Input) }
            if ([IO.File]::Exists($job.Output)) { throw ('Output now exists; refusing to overwrite: ' + $job.Output) }
            $Script:OutTail = New-Object VppBox07.LogTail; $Script:ErrTail = New-Object VppBox07.LogTail
            $pb_progress.Value = 0
            Set-Status ('Encoding {0}/{1}: {2}' -f ($Script:QueueIndex + 1), $Script:QueueJobs.Count, [IO.Path]::GetFileName($job.Input))
            Add-Log $lbl_status.Text
            Add-Log (Command-LineText (@($Script:Encoder) + $job.Arguments))
            $Script:Process = Start-Process -FilePath $Script:Encoder -ArgumentList (Command-LineText $job.Arguments) -NoNewWindow -PassThru `
                -RedirectStandardOutput $Script:StdoutPath -RedirectStandardError $Script:StderrPath
            $null = $Script:Process.Handle
            $Script:Timer.Start(); return
        } catch { Add-Log ('Cannot start encoder: ' + $_.Exception.Message); $Script:QueueFailures++; $Script:QueueIndex++ }
    }
    $Script:Timer.Stop(); $Script:QueueActive = $false
    $btn_start.IsEnabled = $true; $btn_stop.IsEnabled = $false; $btn_preview.IsEnabled = $true
    if ($Script:QueueFailures -gt 0) { Set-Status ('Queue finished with {0} failure(s)' -f $Script:QueueFailures) }
    else { Set-Status 'Queue complete - ready' $true }
    $pb_progress.Value = if ($Script:QueueFailures -eq 0) { 100 } else { 0 }
    Add-Log $lbl_status.Text
    Schedule-Preview
}
function Stop-Queue {
    if ($Script:Timer) { $Script:Timer.Stop() }
    if ($Script:Process) {
        try { if (-not $Script:Process.HasExited) { $Script:Process.Kill(); [void]$Script:Process.WaitForExit(2000) } } catch { }
        $Script:Process.Dispose(); $Script:Process = $null
    }
    $Script:QueueActive = $false; $btn_start.IsEnabled = $true; $btn_stop.IsEnabled = $false; $btn_preview.IsEnabled = $true
    Set-Status 'Stopped'; Add-Log 'Queue stopped. Any partial output was left in place.'
}


# ------------------------------------------------------------ XAML
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="VPPBox v0.7.2 - rigaya HWEnc"
 Width="1320" Height="800" MinWidth="900" MinHeight="520" AllowDrop="True" WindowStartupLocation="CenterScreen"
 Background="{DynamicResource WindowBackgroundBrush}" Foreground="{DynamicResource TextBrush}" FontFamily="Segoe UI" FontSize="13">
<Window.Resources>
  <SolidColorBrush x:Key="WindowBackgroundBrush" Color="#F3F3F3"/>
  <SolidColorBrush x:Key="SurfaceBrush" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="SurfaceAltBrush" Color="#F9F9F9"/>
  <SolidColorBrush x:Key="InputBackgroundBrush" Color="#F7F7F7"/>
  <SolidColorBrush x:Key="ControlBackgroundBrush" Color="#F4F4F4"/>
  <SolidColorBrush x:Key="ButtonBrush" Color="#F0F0F0"/>
  <SolidColorBrush x:Key="HoverBrush" Color="#E4E4E4"/>
  <SolidColorBrush x:Key="PressedBrush" Color="#D6D6D6"/>
  <SolidColorBrush x:Key="BorderBrush" Color="#C8C8C8"/>
  <SolidColorBrush x:Key="StrongBorderBrush" Color="#919191"/>
  <SolidColorBrush x:Key="TextBrush" Color="#1A1A1A"/>
  <SolidColorBrush x:Key="MutedTextBrush" Color="#636363"/>
  <SolidColorBrush x:Key="AccentBrush" Color="#0078D4"/>
  <SolidColorBrush x:Key="AccentTextBrush" Color="#0068B8"/>
  <SolidColorBrush x:Key="AccentForegroundBrush" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="SelectionBrush" Color="#0078D4"/>
  <SolidColorBrush x:Key="SelectionTextBrush" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="ReadyBrush" Color="#237A32"/>
  <SolidColorBrush x:Key="ErrorBrush" Color="#C42B1C"/>
  <SolidColorBrush x:Key="SwitchThumbBrush" Color="#1A1A1A"/>
  <SolidColorBrush x:Key="PreviewBackgroundBrush" Color="#101218"/>
  <SolidColorBrush x:Key="PreviewTextBrush" Color="#CBD3E3"/>
  <SolidColorBrush x:Key="PreviewDividerBrush" Color="#FFFFFF"/>
  <SolidColorBrush x:Key="OverlayBackgroundBrush" Color="#DD101218"/>
  <SolidColorBrush x:Key="OverlayAccentBrush" Color="#DD234E9B"/>
  <SolidColorBrush x:Key="OverlayTextBrush" Color="#FFFFFF"/>
  <Style x:Key="ThemeFocusVisual" TargetType="Control">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Control">
      <Rectangle Margin="1" Stroke="{DynamicResource AccentTextBrush}" StrokeDashArray="1 2" StrokeThickness="1" IsHitTestVisible="False"/>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type Button}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource ButtonBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrongBorderBrush}"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Button}">
      <Border Name="ButtonChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonChrome" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.88"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonChrome" Property="Opacity" Value="0.70"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DecoderToggleStyle" TargetType="{x:Type ToggleButton}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrongBorderBrush}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Margin" Value="2,6,2,3"/><Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ToggleButton}">
      <Grid Background="{TemplateBinding Background}">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Name="SwitchTrack" Width="42" Height="24" CornerRadius="12" Background="{DynamicResource ButtonBrush}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" VerticalAlignment="Center">
          <Ellipse Name="SwitchThumb" Width="16" Height="16" Fill="{DynamicResource SwitchThumbBrush}" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="3,0"/>
        </Border>
        <ContentPresenter Grid.Column="1" Margin="10,0,0,0" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="True"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="SwitchTrack" Property="Background" Value="{DynamicResource AccentBrush}"/><Setter TargetName="SwitchThumb" Property="Fill" Value="{DynamicResource AccentForegroundBrush}"/><Setter TargetName="SwitchThumb" Property="HorizontalAlignment" Value="Right"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SwitchTrack" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="SwitchTrack" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type TextBox}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource InputBackgroundBrush}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/><Setter Property="SelectionBrush" Value="{DynamicResource SelectionBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrongBorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="7,5"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type TextBox}">
      <Border Name="TextChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
        <ScrollViewer Name="PART_ContentHost" Focusable="False" Margin="{TemplateBinding Padding}"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="TextChrome" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ComboBox}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource ControlBackgroundBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrongBorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="7,5"/>
    <Setter Property="ScrollViewer.CanContentScroll" Value="True"/><Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ComboBox}">
      <Grid>
        <ToggleButton Name="ComboToggle" Focusable="False" ClickMode="Press" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
          <ToggleButton.Template><ControlTemplate TargetType="{x:Type ToggleButton}">
            <Border Name="ComboChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
              <Path Data="M 0,0 L 4,4 L 8,0" Stroke="{DynamicResource TextBrush}" StrokeThickness="1.5" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="8"/>
            </Border>
            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ComboChrome" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger></ControlTemplate.Triggers>
          </ControlTemplate></ToggleButton.Template>
        </ToggleButton>
        <ContentPresenter Margin="7,5,28,5" IsHitTestVisible="False" VerticalAlignment="Center" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
        <Popup Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
          <Border MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}" Background="{DynamicResource ControlBackgroundBrush}" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" Padding="2">
            <ScrollViewer CanContentScroll="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
          </Border>
        </Popup>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="ComboToggle" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ComboBoxItem}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource ControlBackgroundBrush}"/><Setter Property="Padding" Value="7,5"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ComboBoxItem}">
      <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="2"><ContentPresenter/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource SelectionBrush}"/><Setter Property="Foreground" Value="{DynamicResource SelectionTextBrush}"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource SelectionBrush}"/><Setter Property="Foreground" Value="{DynamicResource SelectionTextBrush}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ListBox}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource InputBackgroundBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrongBorderBrush}"/>
  </Style>
  <Style TargetType="{x:Type ListBoxItem}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="6,3"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ListBoxItem}">
      <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource HoverBrush}"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource SelectionBrush}"/><Setter Property="Foreground" Value="{DynamicResource SelectionTextBrush}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type CheckBox}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Margin" Value="2,3"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type CheckBox}">
      <Grid Background="Transparent"><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Name="CheckChrome" Width="16" Height="16" Background="{DynamicResource InputBackgroundBrush}" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" CornerRadius="3" VerticalAlignment="Center">
          <Path Name="CheckMark" Data="M 2,6 L 5,9 L 11,2" Stroke="{DynamicResource AccentForegroundBrush}" StrokeThickness="2" Visibility="Collapsed"/>
        </Border>
        <ContentPresenter Grid.Column="1" Margin="7,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckChrome" Property="Background" Value="{DynamicResource AccentBrush}"/><Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CheckChrome" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="CheckChrome" Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ExpanderHeaderStyle" TargetType="{x:Type ToggleButton}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ToggleButton}">
      <Grid Background="Transparent"><Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Path Name="ExpanderArrow" Data="M 0,0 L 5,5 L 0,10" Stroke="{DynamicResource TextBrush}" StrokeThickness="1.5" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/>
        <ContentPresenter Grid.Column="1" VerticalAlignment="Center" RecognizesAccessKey="True"/>
      </Grid>
      <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="ExpanderArrow" Property="RenderTransform"><Setter.Value><RotateTransform Angle="90"/></Setter.Value></Setter></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type Expander}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Expander}">
      <StackPanel>
        <ToggleButton Style="{StaticResource ExpanderHeaderStyle}" Content="{TemplateBinding Header}" ContentTemplate="{TemplateBinding HeaderTemplate}" IsChecked="{Binding IsExpanded, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
        <ContentPresenter Name="ExpandedContent" Visibility="Collapsed"/>
      </StackPanel>
      <ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="ExpandedContent" Property="Visibility" Value="Visible"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="SliderTrackButton" TargetType="{x:Type RepeatButton}">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type RepeatButton}"><Border Background="Transparent"><Border Height="4" Background="{TemplateBinding Background}" CornerRadius="2" VerticalAlignment="Center"/></Border></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type Slider}">
    <Setter Property="Height" Value="24"/><Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Slider}">
      <Grid Margin="0,2">
        <Track Name="PART_Track" Orientation="{TemplateBinding Orientation}" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{Binding Value, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" IsDirectionReversed="{TemplateBinding IsDirectionReversed}">
          <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource SliderTrackButton}" Command="{x:Static Slider.DecreaseLarge}" Background="{DynamicResource AccentBrush}"/></Track.DecreaseRepeatButton>
          <Track.Thumb><Thumb Width="16" Height="16"><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Ellipse Fill="{DynamicResource AccentBrush}" Stroke="{DynamicResource StrongBorderBrush}" StrokeThickness="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource SliderTrackButton}" Command="{x:Static Slider.IncreaseLarge}" Background="{DynamicResource StrongBorderBrush}"/></Track.IncreaseRepeatButton>
        </Track>
      </Grid>
      <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="ScrollTrackButton" TargetType="{x:Type RepeatButton}">
    <Setter Property="Focusable" Value="False"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type RepeatButton}"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ScrollBar}">
    <Setter Property="Width" Value="12"/><Setter Property="Background" Value="{DynamicResource SurfaceAltBrush}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ScrollBar}">
      <Grid Background="{TemplateBinding Background}">
        <Track Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{Binding Value, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ViewportSize="{TemplateBinding ViewportSize}">
          <Track.DecreaseRepeatButton><RepeatButton Name="ScrollDecrease" Style="{StaticResource ScrollTrackButton}" Command="{x:Static ScrollBar.PageUpCommand}"/></Track.DecreaseRepeatButton>
          <Track.Thumb><Thumb MinHeight="10" MinWidth="10"><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Border Margin="2" Background="{DynamicResource StrongBorderBrush}" CornerRadius="3"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          <Track.IncreaseRepeatButton><RepeatButton Name="ScrollIncrease" Style="{StaticResource ScrollTrackButton}" Command="{x:Static ScrollBar.PageDownCommand}"/></Track.IncreaseRepeatButton>
        </Track>
      </Grid>
      <ControlTemplate.Triggers><Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="12"/><Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
        <Setter TargetName="ScrollDecrease" Property="Command" Value="{x:Static ScrollBar.PageLeftCommand}"/><Setter TargetName="ScrollIncrease" Property="Command" Value="{x:Static ScrollBar.PageRightCommand}"/>
      </Trigger></ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type TabControl}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type TabControl}">
      <Grid KeyboardNavigation.TabNavigation="Local"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <TabPanel IsItemsHost="True" Margin="0,0,0,6" KeyboardNavigation.TabIndex="1"/>
        <Border Grid.Row="1" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
          <ContentPresenter Name="PART_SelectedContentHost" ContentSource="SelectedContent" Margin="{TemplateBinding Padding}"/>
        </Border>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type TabItem}">
    <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource ButtonBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="Padding" Value="10,7"/><Setter Property="Margin" Value="0,0,5,0"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource ThemeFocusVisual}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type TabItem}">
      <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}"><ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource SelectionBrush}"/><Setter Property="Foreground" Value="{DynamicResource SelectionTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource AccentTextBrush}"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ProgressBar}">
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ProgressBar}">
      <Grid><Border Name="PART_Track" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="4"/>
        <Border Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="4"/>
      </Grid>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type Separator}"><Setter Property="Background" Value="{DynamicResource BorderBrush}"/><Setter Property="Margin" Value="0,8"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Separator}"><Border Height="1" Background="{TemplateBinding Background}"/></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ToolTip}">
    <Setter Property="Background" Value="{DynamicResource ControlBackgroundBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource StrongBorderBrush}"/><Setter Property="Padding" Value="8"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ToolTip}"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}" CornerRadius="4"><ContentPresenter/></Border></ControlTemplate></Setter.Value></Setter>
  </Style>
</Window.Resources>
<Grid Margin="12">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border x:Name="header_bar" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" Padding="10,3" CornerRadius="8" Margin="0,0,0,6">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="2*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="lbl_gpu" Text="Detecting..." FontSize="12" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center" Margin="0,0,12,0" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
      <TextBlock x:Name="lbl_status" Grid.Column="1" Text="Initializing..." FontSize="12" Foreground="{DynamicResource ErrorBrush}" VerticalAlignment="Center" TextAlignment="Right" Margin="0,0,12,0" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
      <Button x:Name="btn_settings" Grid.Column="2" Content="&#x2699;" FontFamily="Segoe UI Symbol" FontSize="19" Height="28" MinWidth="30" Margin="0" Padding="7,0" ToolTip="Settings" AutomationProperties.Name="Settings"/>
    </Grid>
  </Border>
  <Grid Grid.Row="1">
    <Grid.ColumnDefinitions><ColumnDefinition Width="1.75*" MinWidth="420"/><ColumnDefinition Width="6"/><ColumnDefinition Width="1*" MinWidth="340"/></Grid.ColumnDefinitions>
    <Grid x:Name="left_workspace">
      <Grid.RowDefinitions><RowDefinition x:Name="row_preview" Height="3*"/><RowDefinition Height="8"/><RowDefinition x:Name="row_command" Height="1*"/></Grid.RowDefinitions>
      <Border Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="12">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid Margin="0,0,0,8">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock Text="BEFORE / AFTER PREVIEW" FontSize="12" FontWeight="Bold" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
            <TextBox x:Name="txt_preview_time" Grid.Column="1" Text="00:00:01.000" Width="110" VerticalAlignment="Center" ToolTip="HH:MM:SS.mmm, MM:SS.mmm or seconds"/>
            <Button x:Name="btn_preview" Grid.Column="2" Content="Refresh"/>
          </Grid>
          <Border Grid.Row="1" Background="{DynamicResource PreviewBackgroundBrush}" CornerRadius="6" ClipToBounds="True">
            <Grid x:Name="preview_grid" Background="Transparent" Cursor="SizeWE" ClipToBounds="True" ToolTip="Drag inside the image to move the comparison divider.">
              <Image x:Name="img_processed" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
              <Grid x:Name="original_layer">
                <Grid.Clip><RectangleGeometry x:Name="clip_original"/></Grid.Clip>
                <Image x:Name="img_original" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
              </Grid>
              <Border x:Name="divider" Width="3" Background="{DynamicResource PreviewDividerBrush}" HorizontalAlignment="Left" VerticalAlignment="Top" IsHitTestVisible="False" Opacity="0.85" Visibility="Collapsed"/>
              <Grid x:Name="labels" IsHitTestVisible="False" Visibility="Collapsed">
                <TextBlock Text="Source" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10" Padding="7,3" Background="{DynamicResource OverlayBackgroundBrush}" Foreground="{DynamicResource OverlayTextBrush}"/>
                <TextBlock Text="VPP processed" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="10" Padding="7,3" Background="{DynamicResource OverlayAccentBrush}" Foreground="{DynamicResource OverlayTextBrush}"/>
              </Grid>
              <TextBlock x:Name="txt_preview_placeholder" Text="Choose a video and a time. Preview uses HWEncVppPreview.Cli; configure its path in Settings. Drag inside the image to compare before and after."
                 TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{DynamicResource PreviewTextBrush}" IsHitTestVisible="False" MaxWidth="380" Margin="14"/>
            </Grid>
          </Border>
          <TextBlock x:Name="lbl_preview_status" Grid.Row="2" Text="Choose a source and time" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="0,7,0,0" TextTrimming="CharacterEllipsis"/>
        </Grid>
      </Border>
      <Border Grid.Row="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="10">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel LastChildFill="True" Margin="0,0,0,5"><Button x:Name="btn_copy" Content="Copy command" DockPanel.Dock="Right"/><TextBlock Text="COMMAND PREVIEW" FontSize="12" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}" VerticalAlignment="Center"/></DockPanel>
          <TextBox x:Name="txt_command" Grid.Row="1" IsReadOnly="True" IsUndoEnabled="False" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Foreground="{DynamicResource TextBrush}"/>
        </Grid>
      </Border>
    </Grid>
    <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" Background="{DynamicResource BorderBrush}"/>
    <Border Grid.Column="2" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="14">
      <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel>
          <TextBlock Text="PRESETS" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
          <DockPanel Margin="0,6,0,10"><Button x:Name="btn_save_preset" Content="Save..." DockPanel.Dock="Right" MinWidth="62"/><ComboBox x:Name="cmb_preset"/></DockPanel>
          <TextBlock Text="SOURCE AND OUTPUT" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
          <TextBlock Text="Input video" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="0,6,0,0"/>
          <DockPanel Margin="0,4,0,8"><Button x:Name="btn_input" Content="Browse..." DockPanel.Dock="Right"/><TextBox x:Name="txt_input"/></DockPanel>
          <TextBlock Text="Output video" FontSize="11" Foreground="{DynamicResource MutedTextBrush}"/>
          <DockPanel Margin="0,4,0,8"><Button x:Name="btn_output" Content="Browse..." DockPanel.Dock="Right"/><TextBox x:Name="txt_output"/></DockPanel>
          <Separator/>
          <TextBlock Text="VIDEO ENCODING" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}" Margin="0,0,0,6"/>
          <TextBlock Text="Codec" FontSize="11" Foreground="{DynamicResource MutedTextBrush}"/>
          <ComboBox x:Name="cmb_codec" SelectedIndex="1" Margin="0,4,0,8">
            <ComboBoxItem Content="H.264 / AVC"/><ComboBoxItem Content="HEVC / H.265"/><ComboBoxItem Content="AV1"/>
          </ComboBox>
          <DockPanel Margin="0,2,0,6">
            <TextBlock Text="Rate mode" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center" Width="80"/>
            <ComboBox x:Name="cmb_mode" SelectedIndex="0"><ComboBoxItem Content="CQP (quality)"/><ComboBoxItem Content="VBR (bitrate)"/><ComboBoxItem Content="CBR (bitrate)"/></ComboBox>
          </DockPanel>
          <Grid Margin="0,0,0,8">
            <StackPanel x:Name="pnl_cqp">
              <DockPanel>
                <TextBlock x:Name="lbl_quality" Text="20" Width="32" TextAlignment="Right" VerticalAlignment="Center" FontFamily="Consolas" DockPanel.Dock="Right"/>
                <TextBlock Text="CQP quality (lower = better)" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" VerticalAlignment="Center"/>
              </DockPanel>
              <Slider x:Name="sl_quality" Minimum="1" Maximum="51" Value="20" TickFrequency="1" IsSnapToTickEnabled="True"/>
            </StackPanel>
            <StackPanel x:Name="pnl_bitrate" Visibility="Collapsed">
              <TextBlock Text="Bitrate (kbps)" FontSize="11" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="txt_bitrate" Text="8000"/>
            </StackPanel>
          </Grid>
          <CheckBox x:Name="chk_audio" Content="Copy audio streams" IsChecked="True"/>
          <Separator/>
          <TextBlock Text="TRIM (optional)" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
          <DockPanel Margin="0,6,0,10">
            <StackPanel Width="150" Margin="0,0,8,0"><TextBlock Text="Start at (seek)" FontSize="11" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="txt_trim_start" ToolTip="Empty = start. Format HH:MM:SS.mmm"/></StackPanel>
            <StackPanel><TextBlock Text="Max frames (empty = all)" FontSize="11" Foreground="{DynamicResource MutedTextBrush}"/><TextBox x:Name="txt_trim_frames"/></StackPanel>
          </DockPanel>
          <Separator/>
          <TextBlock Text="VPP FILTERS" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
          <TextBlock Text="Filters missing from your encoder build are greyed out (read asynchronously from --help)." FontSize="11" Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap" Margin="0,2,0,8"/>
          <StackPanel x:Name="sp_filters"/>
          <Separator/>
<Border Background="{DynamicResource SurfaceAltBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="10">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="150"/></Grid.RowDefinitions>
    <TextBlock Text="VIDEO QUEUE" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
    <WrapPanel Grid.Row="1" Margin="0,4,0,4"><Button x:Name="btn_add" Content="+ Add videos"/><Button x:Name="btn_remove" Content="Remove"/><Button x:Name="btn_clear" Content="Clear"/></WrapPanel>
    <ListBox x:Name="lst_queue" Grid.Row="2" Background="{DynamicResource InputBackgroundBrush}" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" SelectionMode="Extended"
       ScrollViewer.CanContentScroll="True" VirtualizingStackPanel.IsVirtualizing="True" VirtualizingStackPanel.VirtualizationMode="Recycling"/>
  </Grid>
</Border>
      </StackPanel></ScrollViewer>
    </Border>
  </Grid>
  <DockPanel Grid.Row="2" Margin="0,6,0,0">
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_stop" Content="Stop" IsEnabled="False" MinWidth="90"/><Button x:Name="btn_start" Content="Go" MinWidth="120" Background="{DynamicResource AccentBrush}" Foreground="{DynamicResource AccentForegroundBrush}" FontWeight="Bold"/></StackPanel>
    <ProgressBar x:Name="pb_progress" Minimum="0" Maximum="100" Height="10" Margin="0,0,12,0" VerticalAlignment="Center" Background="{DynamicResource InputBackgroundBrush}" Foreground="{DynamicResource AccentBrush}" BorderBrush="{DynamicResource StrongBorderBrush}"/>
  </DockPanel>
  <Popup x:Name="popup_settings" Placement="Bottom" PlacementTarget="{Binding ElementName=btn_settings}" StaysOpen="False" AllowsTransparency="True" PopupAnimation="Fade">
    <Border Width="670" x:Name="settings_content" TextElement.Foreground="{DynamicResource TextBrush}" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource AccentBrush}" BorderThickness="1" CornerRadius="8" Padding="14">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,10">
          <Button x:Name="btn_settings_close" Content="Close" DockPanel.Dock="Right"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="SETTINGS" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
            <TextBlock Text="VPPBox v0.7.2 / rigaya HWEnc" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="0,3,0,0"/>
          </StackPanel>
        </DockPanel>
        <TabControl x:Name="settings_tabs" Grid.Row="1" Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource StrongBorderBrush}">
          <TabItem Header="ENCODER">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="12"><StackPanel>
          <TextBlock Text="ENCODER" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
          <TextBlock Text="Detected encoder (or pick one manually)" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="0,6,0,0"/>
          <DockPanel Margin="0,4,0,8"><Button x:Name="btn_enc_browse" Content="Browse..." DockPanel.Dock="Right"/><ComboBox x:Name="cmb_encoder"/></DockPanel>

          <ToggleButton x:Name="tgl_avhw" Style="{StaticResource DecoderToggleStyle}" Content="Hardware decoder (--avhw)" IsChecked="False" IsThreeState="False" HorizontalAlignment="Left"
              ToolTip="OFF (default): --avsw. ON: --avhw. Applies to preview and encoding." AutomationProperties.Name="Hardware decoder"/>
          <TextBlock x:Name="lbl_decoder_mode" FontSize="11" Foreground="{DynamicResource MutedTextBrush}" Margin="54,0,0,4" TextWrapping="Wrap">
            <TextBlock.Style><Style TargetType="{x:Type TextBlock}">
              <Setter Property="Text" Value="OFF: software decoding (--avsw), default"/>
              <Style.Triggers><DataTrigger Binding="{Binding IsChecked, ElementName=tgl_avhw}" Value="True"><Setter Property="Text" Value="ON: hardware decoding (--avhw)"/></DataTrigger></Style.Triggers>
            </Style></TextBlock.Style>
          </TextBlock>

              <Separator/>
              <TextBlock Text="PREVIEW BACKEND" Foreground="{DynamicResource AccentTextBrush}" FontWeight="Bold"/>
              <TextBlock Text="HWEncVppPreview.Cli.exe (not the graphical HWEncVppPreview.exe)" Foreground="{DynamicResource MutedTextBrush}" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,4"/>
              <DockPanel><Button x:Name="btn_cli_browse" Content="Browse..." DockPanel.Dock="Right"/><TextBox x:Name="txt_preview_cli" ToolTip="Empty: auto-detect beside the script/encoder, in preview-cli, or on PATH."/></DockPanel>
              <TextBlock Text="Leave empty for automatic discovery. Only preview requires the CLI; video encoding still uses the selected rigaya encoder directly." Foreground="{DynamicResource MutedTextBrush}" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
            </StackPanel></ScrollViewer>
          </TabItem>
          <TabItem Header="PROCESSING LOG">
            <Grid Margin="10">
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <DockPanel Margin="0,0,0,6"><StackPanel Orientation="Horizontal" DockPanel.Dock="Right"><Button x:Name="btn_log_copy" Content="Copy"/><Button x:Name="btn_log_clear" Content="Clear"/></StackPanel><TextBlock Text="PROCESSING LOG" Foreground="{DynamicResource AccentTextBrush}" VerticalAlignment="Center"/></DockPanel>
              <TextBox x:Name="txt_log" Grid.Row="1" IsReadOnly="True" IsUndoEnabled="False" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11.5" Foreground="{DynamicResource TextBrush}"/>
            </Grid>
          </TabItem>
          <TabItem Header="THEME">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="12"><StackPanel>
              <TextBlock Text="APPEARANCE" FontSize="12.5" FontWeight="Bold" Foreground="{DynamicResource AccentTextBrush}"/>
              <TextBlock Text="Follow Windows app mode by default, or choose a fixed appearance." Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap" Margin="0,6,0,8"/>
              <ComboBox x:Name="cmb_theme_mode" SelectedIndex="0" AutomationProperties.Name="Application theme">
                <ComboBoxItem Content="System (default)" Tag="System"/><ComboBoxItem Content="Light" Tag="Light"/><ComboBoxItem Content="Dark" Tag="Dark"/>
              </ComboBox>
              <TextBlock x:Name="lbl_theme_effective" Text="Reading Windows appearance..." Foreground="{DynamicResource MutedTextBrush}" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,2"/>
              <Separator/>
              <TextBlock Text="CUSTOM COLORS (optional)" Foreground="{DynamicResource AccentTextBrush}" FontWeight="Bold"/>
              <TextBlock Text="Use #RRGGBB, or leave a field empty for automatic colors. An empty accent uses the Windows accent. Swatches show the currently applied colors." Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap" FontSize="11" Margin="0,6,0,10"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="140"/><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <TextBlock Text="Accent" VerticalAlignment="Center"/>
                <TextBox x:Name="txt_theme_accent" Grid.Column="1" MaxLength="7" Margin="0,3,8,3" ToolTip="Accent color in #RRGGBB format. Empty = Windows accent." AutomationProperties.Name="Accent color"/>
                <Border x:Name="swatch_theme_accent" Grid.Column="2" Width="26" Height="26" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" CornerRadius="4"/>
                <TextBlock Grid.Row="1" Text="Window background" VerticalAlignment="Center"/>
                <TextBox x:Name="txt_theme_window" Grid.Row="1" Grid.Column="1" MaxLength="7" Margin="0,3,8,3" ToolTip="Window background in #RRGGBB format. Empty = automatic." AutomationProperties.Name="Window background color"/>
                <Border x:Name="swatch_theme_window" Grid.Row="1" Grid.Column="2" Width="26" Height="26" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" CornerRadius="4"/>
                <TextBlock Grid.Row="2" Text="Panel background" VerticalAlignment="Center"/>
                <TextBox x:Name="txt_theme_surface" Grid.Row="2" Grid.Column="1" MaxLength="7" Margin="0,3,8,3" ToolTip="Panel background in #RRGGBB format. Empty = automatic." AutomationProperties.Name="Panel background color"/>
                <Border x:Name="swatch_theme_surface" Grid.Row="2" Grid.Column="2" Width="26" Height="26" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" CornerRadius="4"/>
                <TextBlock Grid.Row="3" Text="Text" VerticalAlignment="Center"/>
                <TextBox x:Name="txt_theme_text" Grid.Row="3" Grid.Column="1" MaxLength="7" Margin="0,3,8,3" ToolTip="Text color in #RRGGBB format. Empty = automatic." AutomationProperties.Name="Text color"/>
                <Border x:Name="swatch_theme_text" Grid.Row="3" Grid.Column="2" Width="26" Height="26" BorderBrush="{DynamicResource StrongBorderBrush}" BorderThickness="1" CornerRadius="4"/>
              </Grid>
              <TextBlock Text="Click Apply to update and save the theme. Video pixels are not changed. The status remains green when ready and red otherwise." Foreground="{DynamicResource MutedTextBrush}" TextWrapping="Wrap" FontSize="11" Margin="0,10,0,6"/>
              <WrapPanel HorizontalAlignment="Right"><Button x:Name="btn_theme_reset" Content="Reset to system"/><Button x:Name="btn_theme_apply" Content="Apply" MinWidth="90"/></WrapPanel>
              <TextBlock x:Name="lbl_theme_feedback" Text="Theme preferences are saved separately from video presets." Foreground="{DynamicResource MutedTextBrush}" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
            </StackPanel></ScrollViewer>
          </TabItem>
        </TabControl>
      </Grid>
    </Border>
  </Popup>
</Grid>
</Window>
'@

# ------------------------------------------------------------ materialize and resolve named controls
$reader = New-Object System.Xml.XmlNodeReader $xaml
try { $window = [Windows.Markup.XamlReader]::Load($reader) }
finally { $reader.Close() }
$ns = New-Object Xml.XmlNamespaceManager($xaml.NameTable)
$ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
foreach ($attribute in $xaml.SelectNodes('//@x:Name', $ns)) {
    $name = $attribute.Value; $control = $window.FindName($name)
    if ($null -eq $control) { throw "XAML control not found: $name" }
    Set-Variable -Name $name -Value $control -Scope Script
}
# Explicitly share resources with the settings popup's separate presentation source.
$settings_content.Resources.MergedDictionaries.Add($window.Resources)
$localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ($localData) { $Script:ThemeSettingsPath = Join-Path (Join-Path $localData 'VPPBox') 'theme.json' }
$Script:ThemeSettings = Read-ThemeSettings
Sync-ThemeEditor
Apply-Theme
$wa = [System.Windows.SystemParameters]::WorkArea
$maxH = [Math]::Floor([Math]::Min([System.Windows.SystemParameters]::PrimaryScreenHeight * 0.9, $wa.Height))
$maxW = [Math]::Floor([Math]::Min([System.Windows.SystemParameters]::PrimaryScreenWidth * 0.95, $wa.Width))
$window.MinHeight = [Math]::Min(520, $maxH); $window.MinWidth = [Math]::Min(900, $maxW)
$window.Height = [Math]::Min(880, $maxH); $window.Width = [Math]::Min(1320, $maxW)
$txt_preview_cli.Text = $PreviewCliPath
Build-AllFilterPanels $sp_filters
Load-UserPresets
Refresh-PresetCombo
$Script:Restoring = $true
function Add-EncoderItem([string]$Exe, [string]$GpuLabel, $Path) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    if ($Path) { $item.Content = "$Exe - $GpuLabel"; $item.Tag = [string]$Path }
    else       { $item.Content = "$Exe - $GpuLabel (not found)"; $item.Tag = $null; $item.IsEnabled = $false }
    [void]$cmb_encoder.Items.Add($item)
    return $item
}

$gpuNames = @(Get-VideoControllers)
$listedExe = @{}
foreach ($gpu in $gpuNames) {
    $exe = if ($gpu -match 'NVIDIA|GeForce|Quadro|RTX|GTX|Tesla') { 'NVEncC64.exe' }
           elseif ($gpu -match 'AMD|Radeon|FirePro') { 'VCEEncC64.exe' }
           elseif ($gpu -match 'Intel') { 'QSVEncC64.exe' }
           else { $null }
    if ($exe -and -not $listedExe.ContainsKey($exe)) {
        $listedExe[$exe] = $true
        [void](Add-EncoderItem $exe $gpu (Resolve-EncoderExecutable $exe))
    }
}
foreach ($exe in @('NVEncC64.exe', 'VCEEncC64.exe', 'QSVEncC64.exe')) {
    if (-not $listedExe.ContainsKey($exe)) {
        $p = Resolve-EncoderExecutable $exe
        if ($p) { $listedExe[$exe] = $true; [void](Add-EncoderItem $exe 'no matching GPU detected' $p) }
    }
}
for ($i = 0; $i -lt $cmb_encoder.Items.Count; $i++) { if ($cmb_encoder.Items[$i].Tag) { $cmb_encoder.SelectedIndex = $i; break } }

Add-Log ('Script folder: ' + $Script:Root)
if ($gpuNames.Count -gt 0) { Add-Log ('GPU(s): ' + ($gpuNames -join ' | ')); $lbl_gpu.Text = 'GPU: ' + $gpuNames[0] }
else { Add-Log 'GPU detection: WMI/CIM returned no video controllers.'; $lbl_gpu.Text = 'GPU: unknown' }
$foundCount = 0
foreach ($it in $cmb_encoder.Items) { if ($it.Tag) { $foundCount++; Add-Log ('Encoder found: ' + $it.Tag) } }
if ($foundCount -gt 0) { $lbl_gpu.Text += ('  |  ' + $foundCount + ' encoder(s) found') }
else {
    Add-Log 'No encoder found. Looked for NVEncC64.exe / VCEEncC64.exe / QSVEncC64.exe in the script folder, the current folder and PATH. Open Settings > ENCODER to browse for an encoder.'
    $lbl_gpu.Text += '  |  no encoder found - open Settings'
}

# ------------------------------------------------------------ events
$btn_settings.Add_Click({
    $settings_content.Width = [Math]::Max(320, [Math]::Min(670, $window.ActualWidth - 40))
    $settings_content.Height = [Math]::Max(280, [Math]::Min(650, $window.ActualHeight - 100))
    $popup_settings.IsOpen = -not $popup_settings.IsOpen
})
$btn_settings_close.Add_Click({ $popup_settings.IsOpen = $false })
$btn_theme_apply.Add_Click({ Save-ThemeFromEditor })
$btn_theme_reset.Add_Click({ Save-ThemeFromEditor -Reset })
$window.Add_SourceInitialized({ Connect-ThemeNotifications })
$window.Add_Activated({
    if (-not $Script:Closing -and $Script:ThemeRefreshTimer) { $Script:ThemeRefreshTimer.Stop(); $Script:ThemeRefreshTimer.Start() }
})
$btn_log_clear.Add_Click({ $txt_log.Clear() })
$btn_log_copy.Add_Click({ try { [Windows.Clipboard]::SetText($txt_log.Text) } catch { Add-Log $_.Exception.Message } })
$btn_cli_browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = 'Select HWEncVppPreview.Cli.exe'; $dialog.Filter = 'Preview CLI|HWEncVppPreview.Cli.exe|Executables|*.exe'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txt_preview_cli.Text = $dialog.FileName }
    } finally { $dialog.Dispose() }
})
$btn_enc_browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = 'Select a rigaya encoder executable'; $dialog.Filter = 'rigaya encoders|NVEncC64.exe;QSVEncC64.exe;VCEEncC64.exe|Executables|*.exe'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $existing = $null
            foreach ($item in $cmb_encoder.Items) { if ($item.Tag -eq $dialog.FileName) { $existing = $item; break } }
            if (-not $existing) { $existing = Add-EncoderItem ([IO.Path]::GetFileName($dialog.FileName)) 'manual selection' $dialog.FileName }
            $cmb_encoder.SelectedItem = $existing
        }
    } finally { $dialog.Dispose() }
})
$cmb_mode.Add_SelectionChanged({
    $pnl_cqp.Visibility = if ($cmb_mode.SelectedIndex -eq 0) { 'Visible' } else { 'Collapsed' }
    $pnl_bitrate.Visibility = if ($cmb_mode.SelectedIndex -eq 0) { 'Collapsed' } else { 'Visible' }
    Update-CommandPreview
})
$preview_grid.Add_MouseLeftButtonDown({ param($sender, $eventArgs)
    if (-not $img_original.Source -or -not $img_processed.Source) { return }
    [void]$sender.CaptureMouse(); Set-SplitFromMouse ($eventArgs.GetPosition($sender)); $eventArgs.Handled = $true
})
$preview_grid.Add_MouseMove({ param($sender, $eventArgs)
    if ($sender.IsMouseCaptured -and $eventArgs.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { Set-SplitFromMouse ($eventArgs.GetPosition($sender)) }
})
$preview_grid.Add_MouseLeftButtonUp({ param($sender, $eventArgs) if ($sender.IsMouseCaptured) { $sender.ReleaseMouseCapture(); $eventArgs.Handled = $true } })
$preview_grid.Add_SizeChanged({ Update-Comparison })
$window.Add_PreviewKeyDown({ param($sender, $eventArgs)
    if ($eventArgs.Key -eq [Windows.Input.Key]::Escape) { $popup_settings.IsOpen = $false; if ($preview_grid.IsMouseCaptured) { $preview_grid.ReleaseMouseCapture() } }
})
$window.Add_PreviewDragOver({ param($sender, $eventArgs)
    $eventArgs.Effects = if ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None }
    $eventArgs.Handled = $true
})
$window.Add_PreviewDrop({ param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { Add-QueueFiles ($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop)) }
    $eventArgs.Handled = $true
})
$btn_input.Add_Click({ Browse-Videos }); $btn_add.Add_Click({ Browse-Videos }); $btn_output.Add_Click({ Browse-Output })
$btn_start.Add_Click({ Start-Queue }); $btn_stop.Add_Click({ Stop-Queue; Schedule-Preview })
$btn_copy.Add_Click({
    try {
        Render-CommandPreview; [Windows.Clipboard]::SetText($txt_command.Text)
        Add-Log 'Command copied.'
        if (-not $Script:QueueActive) { Set-Status 'Command copied.' $Script:StatusReady }
    } catch {
        Add-Log ('Cannot copy command: ' + $_.Exception.Message)
        if (-not $Script:QueueActive) { Set-Status ('Cannot copy command: ' + $_.Exception.Message) }
    }
})
$btn_remove.Add_Click({ foreach ($item in @($lst_queue.SelectedItems)) { [void]$lst_queue.Items.Remove($item) }; Update-CommandPreview })
$btn_clear.Add_Click({ $lst_queue.Items.Clear(); Update-CommandPreview })
$lst_queue.Add_SelectionChanged({ if ($lst_queue.SelectedItem) { $txt_input.Text = [string]$lst_queue.SelectedItem } })
$cmb_preset.Add_SelectionChanged({
    if ($Script:Restoring) { return }
    $name = [string]$cmb_preset.SelectedItem
    if (-not $name) { return }
    if ($name.StartsWith('* ')) { $key = $name.Substring(2); if ($Script:UserPresets.Contains($key)) { Restore-Settings $Script:UserPresets[$key] } }
    elseif ($Script:BuiltinPresets.Contains($name)) { Restore-Settings $Script:BuiltinPresets[$name] }
})
$btn_save_preset.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Preset name:', 'Save preset', '')
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim(); $snapshot = Get-SettingsSnapshot; $settings = @{}
    foreach ($key in $snapshot.Keys) {
        $entry = @{ On = $snapshot[$key].On; Values = @{} }
        foreach ($field in $snapshot[$key].Values.Keys) { $entry.Values[$field] = $snapshot[$key].Values[$field] }
        $settings[$key] = $entry
    }
    $Script:UserPresets[$name] = $settings
    try {
        Save-UserPresets; Refresh-PresetCombo
        $Script:Restoring = $true; $cmb_preset.SelectedItem = '* ' + $name; $Script:Restoring = $false
        Add-Log ("Preset '$name' saved.")
        if (-not $Script:QueueActive) { Set-Status ("Preset '$name' saved.") $Script:StatusReady }
    } catch {
        Add-Log ('Cannot save preset: ' + $_.Exception.Message)
        if (-not $Script:QueueActive) { Set-Status ('Cannot save preset: ' + $_.Exception.Message) }
    }
})
$btn_preview.Add_Click({
    $Script:PreviewGeneration++; $Script:PreviewTimer.Stop()
    $Script:PvCache = @{ SrcKey = ''; Source = $null; PrcKey = ''; Processed = $null }
    Start-PreviewRender
})
$txt_preview_time.Add_TextChanged({ Schedule-Preview })
$txt_preview_cli.Add_TextChanged({ Schedule-Preview })
$txt_input.Add_TextChanged({ Suggest-Output; Update-CommandPreview; Schedule-Preview })
$txt_output.Add_TextChanged({ Update-CommandPreview })
$cmb_encoder.Add_SelectionChanged({ Update-IdleStatus; Update-CommandPreview; Update-EncoderCapabilities; Schedule-Preview })
$cmb_codec.Add_SelectionChanged({ Update-CommandPreview })
$sl_quality.Add_ValueChanged({ $lbl_quality.Text = [string][int]$sl_quality.Value; Update-CommandPreview })
$chk_audio.Add_Checked({ Update-CommandPreview }); $chk_audio.Add_Unchecked({ Update-CommandPreview })
$tgl_avhw.Add_Checked({ Update-CommandPreview; Schedule-Preview }); $tgl_avhw.Add_Unchecked({ Update-CommandPreview; Schedule-Preview })
$txt_trim_start.Add_TextChanged({ Update-CommandPreview }); $txt_trim_frames.Add_TextChanged({ Update-CommandPreview }); $txt_bitrate.Add_TextChanged({ Update-CommandPreview })

# ------------------------------------------------------------ dispatcher timers only coordinate results; workers do I/O/conversion
$Script:ThemeRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:ThemeRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$Script:ThemeRefreshTimer.Add_Tick({
    $Script:ThemeRefreshTimer.Stop()
    if (-not $Script:Closing) { try { Apply-Theme } catch { Add-Log ('Theme refresh failed: ' + $_.Exception.Message) } }
})
$Script:CommandTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:CommandTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$Script:CommandTimer.Add_Tick({ $Script:CommandTimer.Stop(); Render-CommandPreview })
$Script:PreviewTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:PreviewTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$Script:PreviewTimer.Add_Tick({ $Script:PreviewTimer.Stop(); Start-PreviewRender })
$Script:PvTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:PvTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$Script:PvTimer.Add_Tick({ Poll-Preview })
$Script:CapsTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:CapsTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$Script:CapsTimer.Add_Tick({ Poll-EncoderCapabilities })
$Script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)
$Script:Timer.Add_Tick({
    try {
        $finished = $Script:Process -and $Script:Process.HasExited
        if ($finished) { $Script:Process.WaitForExit() } # Flush asynchronous redirected output before the final tail.
        Tail-LogFile $Script:StdoutPath $Script:OutTail $finished
        Tail-LogFile $Script:StderrPath $Script:ErrTail $finished
        if ($finished) {
            $code = $Script:Process.ExitCode; $Script:Process.Dispose(); $Script:Process = $null
            if ($code -eq 0) { Add-Log 'Encode finished.'; $pb_progress.Value = 100 }
            else { $Script:QueueFailures++; Add-Log ('Encoder exited with code ' + $code + '.') }
            $Script:QueueIndex++; Start-NextEncode
        }
    } catch { Add-Log ('Queue error: ' + $_.Exception.Message); Stop-Queue }
})
$window.Add_Closing({ param($sender, $eventArgs)
    if ($Script:QueueActive -and [Windows.MessageBox]::Show('Encoding is in progress. Stop it and close VPPBox?', 'VPPBox', 'YesNo', 'Warning') -ne 'Yes') { $eventArgs.Cancel = $true; return }
    $Script:Closing = $true
    Disconnect-ThemeNotifications
    $popup_settings.IsOpen = $false
    foreach ($timer in @($Script:Timer, $Script:PreviewTimer, $Script:PvTimer, $Script:CapsTimer, $Script:CommandTimer, $Script:ThemeRefreshTimer)) { if ($timer) { $timer.Stop() } }
    Cancel-Preview
    if ($Script:CapsJob) { $Script:CapsJob.Cancel(); $Script:CleanupTasks.Add($Script:CapsJob.Completion) }
    if ($Script:QueueActive -or $Script:Process) { Stop-Queue }
})
$Script:Restoring = $false; $Script:UiReady = $true
$lbl_quality.Text = [string][int]$sl_quality.Value
Update-IdleStatus
Render-CommandPreview
$window.Add_ContentRendered({ Update-Comparison; Update-EncoderCapabilities })
try { $null = $window.ShowDialog() }
finally {
    $Script:Closing = $true
    Disconnect-ThemeNotifications
    foreach ($timer in @($Script:Timer, $Script:PreviewTimer, $Script:PvTimer, $Script:CapsTimer, $Script:CommandTimer, $Script:ThemeRefreshTimer)) { if ($timer) { $timer.Stop() } }
    if ($Script:Pv.Busy) { Cancel-Preview }
    if ($Script:CapsJob) { $Script:CapsJob.Cancel() }
    if ($Script:Process) { Stop-Queue }
    try { if ($Script:CleanupTasks.Count -gt 0) { [void][Threading.Tasks.Task]::WaitAll($Script:CleanupTasks.ToArray(), 10000) } } catch { }
    Remove-Item -LiteralPath $Script:StdoutPath, $Script:StderrPath -Force -ErrorAction SilentlyContinue
    $Script:PvCache.Clear(); $img_original.Source = $null; $img_processed.Source = $null
}
