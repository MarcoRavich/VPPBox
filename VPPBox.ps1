# VPPBox v0.6 - PowerShell GUI for rigaya hardware encoders (NVEncC64 / QSVEncC64 / VCEEncC64)
# Windows PowerShell 5.1 and PowerShell 7. No VapourSynth, no FFmpeg.
#
# v0.6  Encoder/GPU detection is the v1 method again (Resolve-EncoderExecutable + Test-Path / Get-Command, one entry per GPU,
#       Tag = path string). v2.4/v2.5 failed because "return ,$array" + "@(Get-...)" produced NESTED arrays, so the folder loop
#       called .TrimEnd() on an array inside a try/catch and silently found nothing. The same bug also garbled the command preview.
#       No function in this script returns "," arrays any more.
# v0.5  real-bounds draggable preview divider, cached/cancellable preview, progress bar, drag & drop.
# v0.4  window <= 90% of screen.   v2.3 preview via child process + UI timer, safe C# helper, corrected VPP syntax.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

$Script:Root = $null
try { $Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
if (-not $Script:Root) { $Script:Root = $PSScriptRoot }
if (-not $Script:Root) { $Script:Root = (Get-Location).Path }
$Script:Process = $null; $Script:Timer = $null; $Script:PreviewTimer = $null; $Script:PvTimer = $null
$Script:PreviewGeneration = 0; $Script:Restoring = $false
$Script:PreviewMode = 'split'; $Script:QueueItems = @(); $Script:QueueIndex = 0; $Script:Encoder = $null
$Script:StdoutPath = Join-Path $env:TEMP ("vppbox-{0}.out" -f [guid]::NewGuid())
$Script:StderrPath = Join-Path $env:TEMP ("vppbox-{0}.err" -f [guid]::NewGuid())
$Script:ReadOut = 0L; $Script:ReadErr = 0L
$Script:CapsCache = @{}
$Script:BrushConv = New-Object System.Windows.Media.BrushConverter
$Script:PvBest = 0
$Script:Pv = @{ Busy = $false }
$Script:PvCache = @{ SrcKey = ''; SrcBmp = $null; SrcAttempt = 0; PrcKey = ''; PrcBmp = $null }

function Brush([string]$c) { return $Script:BrushConv.ConvertFrom($c) }
function Fmt-Num([double]$v) { return $v.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture) }

# ------------------------------------------------------------ GPU + encoder discovery (v1 method)
function Get-VideoControllers {
    $names = @()
    try { $names = @(Get-WmiObject -Class Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
    catch {
        try { $names = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
        catch { $names = @() }
    }
    if ($names.Count -eq 0) {
        try { $names = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) } catch { }
    }
    return $names
}

function Resolve-EncoderExecutable {
    param([string]$Name)
    $local = Join-Path $Script:Root $Name
    if (Test-Path -LiteralPath $local) { return $local }
    $cwd = Join-Path (Get-Location).Path $Name
    if (Test-Path -LiteralPath $cwd) { return $cwd }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-SelectedEncoder {
    $item = $cmb_encoder.SelectedItem
    if ($item -and $item.Tag) { return [string]$item.Tag }
    return $null
}

function Run-ToText([string]$exe, [string]$arguments) {
    $log = Join-Path $env:TEMP ("vppbox-probe-{0}.txt" -f [guid]::NewGuid())
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -NoNewWindow -PassThru -Wait -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
        $t = ''
        if (Test-Path -LiteralPath $log) { $t += (Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path -LiteralPath ($log + '.err')) { $t += (Get-Content -LiteralPath ($log + '.err') -Raw -ErrorAction SilentlyContinue) }
        return [string]$t
    } catch { return '' }
    finally { Remove-Item -LiteralPath $log, ($log + '.err') -Force -ErrorAction SilentlyContinue }
}

function Get-EncoderFeatures([string]$exe) {
    if ($Script:CapsCache.ContainsKey($exe)) { return $Script:CapsCache[$exe] }
    $features = @{}
    foreach ($probe in @('--option-list', '--help', '--check-features')) {
        $text = Run-ToText $exe $probe
        if ($text) { foreach ($m in [regex]::Matches($text, '--(vpp-[a-zA-Z0-9\-]+)')) { $features[$m.Groups[1].Value.ToLower()] = $true } }
        if ($features.Count -ge 5) { break }
    }
    if ($features.Count -lt 5) { $features = @{} }
    $Script:CapsCache[$exe] = $features
    return $features
}

# ------------------------------------------------------------ safe C# YUV420 -> BGRA
if (-not ('YuvConvert' -as [type])) {
$csSource = @"
using System;
public static class YuvConvert {
    public static byte[] Yuv420ToBgra(byte[] src, int yStart, int width, int height) {
        int cw = (width + 1) / 2, ch = (height + 1) / 2;
        int uStart = yStart + width * height;
        int vStart = uStart + cw * ch;
        byte[] dst = new byte[width * height * 4];
        for (int y = 0; y < height; y++) {
            int row = y * width, crow = (y >> 1) * cw;
            for (int x = 0; x < width; x++) {
                int Y = src[yStart + row + x] - 16; if (Y < 0) Y = 0;
                int D = src[uStart + crow + (x >> 1)] - 128;
                int E = src[vStart + crow + (x >> 1)] - 128;
                int r = (298 * Y + 409 * E + 128) >> 8;
                int g = (298 * Y - 100 * D - 208 * E + 128) >> 8;
                int b = (298 * Y + 516 * D + 128) >> 8;
                if (r < 0) r = 0; else if (r > 255) r = 255;
                if (g < 0) g = 0; else if (g > 255) g = 255;
                if (b < 0) b = 0; else if (b > 255) b = 255;
                int i = (row + x) * 4;
                dst[i] = (byte)b; dst[i + 1] = (byte)g; dst[i + 2] = (byte)r; dst[i + 3] = 255;
            }
        }
        return dst;
    }
}
"@
    Add-Type -TypeDefinition $csSource -Language CSharp
}

function New-BitmapFromYuv([byte[]]$bytes, [int]$yStart, [int]$width, [int]$height) {
    $ySize = $width * $height
    $cSize = [int][Math]::Ceiling($width / 2.0) * [int][Math]::Ceiling($height / 2.0)
    if ($bytes.Length -lt ($yStart + $ySize + 2 * $cSize)) { throw 'Frame payload truncated (expected 8-bit 4:2:0).' }
    $bgra = [YuvConvert]::Yuv420ToBgra($bytes, $yStart, $width, $height)
    $bmp = [Windows.Media.Imaging.BitmapSource]::Create($width, $height, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $bgra, $width * 4)
    $bmp.Freeze()
    return $bmp
}

function Convert-FrameFile([string]$Path, [string]$LogText) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64) { throw 'Encoder produced an empty frame file.' }
    $sig = [Text.Encoding]::ASCII.GetString($bytes, 0, 9)
    if ($sig -eq 'YUV4MPEG2') {
        $headerEnd = [Array]::IndexOf($bytes, [byte]10, 0)
        $header = [Text.Encoding]::ASCII.GetString($bytes, 0, $headerEnd)
        $wm = [regex]::Match($header, '\bW(\d+)'); $hm = [regex]::Match($header, '\bH(\d+)')
        if (-not $wm.Success -or -not $hm.Success) { throw "Invalid Y4M header: $header" }
        $frameEnd = [Array]::IndexOf($bytes, [byte]10, $headerEnd + 1)
        if ($frameEnd -lt 0) { throw 'Y4M contains no frame.' }
        return New-BitmapFromYuv $bytes ($frameEnd + 1) ([int]$wm.Groups[1].Value) ([int]$hm.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($LogText, '(\d{2,5})\s*[x\u00d7]\s*(\d{2,5})')) {
        $w = [int]$m.Groups[1].Value; $h = [int]$m.Groups[2].Value
        $need = $w * $h + 2 * ([int][Math]::Ceiling($w / 2.0) * [int][Math]::Ceiling($h / 2.0))
        if ($need -eq $bytes.Length) { return New-BitmapFromYuv $bytes 0 $w $h }
    }
    throw ('Raw frame of {0} bytes: could not recover frame size from the encoder log.' -f $bytes.Length)
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
    if ($Value -notmatch '[\s"]') { return $Value }
    $e = $Value -replace '(\\*)"', '$1$1\"'
    $e = $e -replace '(\\+)$', '$1$1'
    return '"' + $e + '"'
}
function Command-LineText([string[]]$Parts) { return (($Parts | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ') }

function Get-Bitrate { $b = 0; if ([int]::TryParse($txt_bitrate.Text.Trim(), [ref]$b) -and $b -gt 0) { return $b }; return 8000 }

function Get-EncoderArguments([string]$InputPath, [string]$OutputPath) {
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add($(if ($chk_avsw.IsChecked) { '--avsw' } else { '--avhw' }))
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
    if (-not $txt_command -or $Script:Restoring) { return }
    $exe = Get-SelectedEncoder; if (-not $exe) { $exe = 'NVEncC64.exe' }
    $inp = if ($txt_input.Text.Trim()) { $txt_input.Text.Trim() } else { 'INPUT.mkv' }
    $out = if ($txt_output.Text.Trim()) { $txt_output.Text.Trim() } else { 'OUTPUT.mp4' }
    $encArgs = @(Get-EncoderArguments $inp $out)
    $txt_command.Text = Command-LineText (@($exe) + $encArgs)
}

function Add-Log([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text) -or -not $txt_log) { return }
    $txt_log.AppendText($Text.TrimEnd() + "`r`n"); $txt_log.ScrollToEnd()
}

# Encoder progress lines ("[12.3%] ...") go to the progress bar / status; everything else to the log.
function Tail-LogFile([string]$Path, [ref]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $text = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -lt $Offset.Value) { $Offset.Value = 0 }
            [void]$fs.Seek($Offset.Value, [IO.SeekOrigin]::Begin)
            $sr = New-Object IO.StreamReader($fs); $text = $sr.ReadToEnd(); $Offset.Value = $fs.Position
        } finally { $fs.Dispose() }
    } catch { return }
    if (-not $text) { return }
    $progress = $null; $buf = New-Object System.Text.StringBuilder
    foreach ($l in ($text -split "[`r`n]+")) {
        if (-not $l) { continue }
        $m = [regex]::Match($l, '\[(\d+(?:\.\d+)?)%\]')
        if ($m.Success) { $progress = $l; $pb_progress.Value = [Math]::Min(100.0, [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)) }
        else { [void]$buf.AppendLine($l) }
    }
    if ($buf.Length -gt 0) { Add-Log $buf.ToString() }
    if ($progress) { $lbl_status.Text = $progress.Trim().Substring(0, [Math]::Min(120, $progress.Trim().Length)) }
}

# ------------------------------------------------------------ filter UI (no closures: state lives in .Tag)
function Add-Label($panel, [string]$text) {
    $lab = New-Object System.Windows.Controls.TextBlock
    $lab.Text = $text; $lab.Width = 110; $lab.VerticalAlignment = 'Center'; $lab.Foreground = Brush '#C4CAD8'
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
    $val.Width = 52; $val.TextAlignment = 'Right'; $val.VerticalAlignment = 'Center'; $val.Foreground = Brush '#F0F2F7'; $val.FontFamily = 'Consolas'
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
    $chk.Foreground = Brush '#E9ECF3'
    [void]$head.Children.Add($chk)
    $ot = New-Object System.Windows.Controls.TextBlock; $ot.Text = $def.Opt; $ot.FontFamily = 'Consolas'; $ot.FontSize = 11
    $ot.Foreground = Brush '#7E96C4'; $ot.VerticalAlignment = 'Center'; $ot.Margin = '8,0,0,0'
    [void]$head.Children.Add($ot)
    $exp.Header = $head; $exp.ToolTip = $def.Tip
    $body = New-Object System.Windows.Controls.StackPanel
    $tip = New-Object System.Windows.Controls.TextBlock
    $tip.Text = $def.Tip; $tip.TextWrapping = 'Wrap'; $tip.FontStyle = 'Italic'; $tip.FontSize = 11; $tip.Foreground = Brush '#9AA7BF'; $tip.Margin = '10,2,8,6'
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
                $fc = New-Object System.Windows.Controls.CheckBox; $fc.Content = $p.Label; $fc.Margin = '10,2,8,2'; $fc.Foreground = Brush '#C4CAD8'
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
        $box.Background = Brush '#2A2F3B'; $box.CornerRadius = 8; $box.BorderBrush = Brush '#3B4150'; $box.BorderThickness = 1
        $box.Padding = 10; $box.Margin = '0,0,0,10'
        $sp = New-Object System.Windows.Controls.StackPanel
        $gt = New-Object System.Windows.Controls.TextBlock
        $gt.Text = $g.ToUpper(); $gt.FontSize = 12.5; $gt.FontWeight = 'Bold'; $gt.Foreground = Brush '#8AB4F8'; $gt.Margin = '0,0,0,6'
        [void]$sp.Children.Add($gt)
        foreach ($id in $groups[$g]) { Build-FilterPanel $id $Script:FilterDefs[$id] $sp }
        $box.Child = $sp
        [void]$panelHost.Children.Add($box)
    }
}

function Update-EncoderCapabilities {
    $exe = Get-SelectedEncoder
    if (-not $exe) { return }
    $features = Get-EncoderFeatures $exe
    foreach ($id in $Script:FilterOrder) {
        $def = $Script:FilterDefs[$id]
        $chk = $Script:Ctrl[$id + '|on']; $exp = $Script:Ctrl[$id + '|panel']
        $ok = $true
        if ($features.Count -gt 0 -and $def.Type -ne 'resize') { $ok = $features.ContainsKey($def.Opt.TrimStart('-').ToLower()) }
        $chk.IsEnabled = $ok; $exp.Opacity = $(if ($ok) { 1.0 } else { 0.4 })
        if (-not $ok) { $chk.IsChecked = $false; $exp.IsExpanded = $false }
    }
}

# ------------------------------------------------------------ preview engine (child process + UI timer, no threads)
function Schedule-Preview {
    if ($Script:Restoring) { return }
    $Script:PreviewGeneration++
    if ($Script:PreviewTimer) { $Script:PreviewTimer.Stop(); $Script:PreviewTimer.Start() }
}

function Get-PvAttempts {
    $decs = if ($chk_avsw.IsChecked) { @('--avsw') } else { @('--avhw','--avsw') }
    $list = @()
    foreach ($d in $decs) { foreach ($f in @('y4m','raw')) { $list += @{ Dec = $d; Fmt = $f } } }
    return $list
}

function Start-PvAttempt {
    $pv = $Script:Pv
    $att = $pv.Attempts[$pv.Attempt]
    $out = Join-Path $env:TEMP ("vppbox-{0}-{1}.frame" -f $pv.Stage, [guid]::NewGuid().ToString('N'))
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add($att.Dec); $a.Add('--seek'); $a.Add($pv.Time); $a.Add('--frames'); $a.Add('1')
    $a.Add('-c'); $a.Add('raw'); $a.Add('--output-format'); $a.Add($att.Fmt)
    $a.Add('--output-csp'); $a.Add('yuv420'); $a.Add('--output-depth'); $a.Add('8')
    if ($pv.Stage -eq 'vpp') { foreach ($x in $pv.Filters) { $a.Add($x) } }
    $a.Add('-i'); $a.Add($pv.Input); $a.Add('-o'); $a.Add($out)
    $pv.Out = $out; $pv.Log = $out + '.log'; $pv.Cmd = (Command-LineText (@($pv.Exe) + $a.ToArray()))
    try {
        $p = Start-Process -FilePath $pv.Exe -ArgumentList (Command-LineText $a.ToArray()) -NoNewWindow -PassThru `
             -RedirectStandardOutput $pv.Log -RedirectStandardError ($pv.Log + '.err')
        $null = $p.Handle
        $pv.Proc = $p
    } catch {
        $pv.Proc = $null
        Stop-Preview ('Cannot start encoder: ' + $_.Exception.Message)
    }
}

function Read-PvLog {
    $t = ''
    foreach ($f in @($Script:Pv.Log, ($Script:Pv.Log + '.err'))) {
        if ($f -and (Test-Path -LiteralPath $f)) { try { $t += [string](Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) + "`n" } catch { } }
    }
    return $t
}

function Remove-PvFiles {
    $pv = $Script:Pv
    if ($pv.Out) { Remove-Item -LiteralPath $pv.Out, $pv.Log, ($pv.Log + '.err') -Force -ErrorAction SilentlyContinue }
}

function Cancel-Preview {
    $pv = $Script:Pv
    $Script:PvTimer.Stop()
    if ($pv.Proc -and -not $pv.Proc.HasExited) { try { $pv.Proc.Kill(); [void]$pv.Proc.WaitForExit(1500) } catch { } }
    Remove-PvFiles
    $pv.Proc = $null; $pv.Busy = $false
}

function Stop-Preview([string]$Message) {
    $Script:PvTimer.Stop()
    Remove-PvFiles
    $Script:Pv.Busy = $false
    $btn_preview.IsEnabled = $true
    if ($Message) { $lbl_preview_status.Text = 'Preview failed - see log'; Add-Log $Message }
}

function Complete-Preview {
    $pv = $Script:Pv
    if ($pv.Gen -eq $Script:PreviewGeneration) {
        $img_original.Source = $pv.SrcBmp
        $img_processed.Source = $(if ($pv.PrcBmp) { $pv.PrcBmp } else { $pv.SrcBmp })
        $txt_preview_placeholder.Visibility = 'Collapsed'
        $lbl_preview_status.Text = 'Preview: ' + [IO.Path]::GetFileName($pv.Exe) + ' (' + $pv.Attempts[$pv.Attempt].Dec + $(if ($pv.FromCache) { ', cached source' } else { '' }) + ')'
        Update-Comparison
    }
    Stop-Preview ''
}

function Poll-Preview {
    $pv = $Script:Pv; $cache = $Script:PvCache
    if (-not $pv.Busy -or -not $pv.Proc) { return }
    if (-not $pv.Proc.HasExited) { return }
    $code = $pv.Proc.ExitCode
    $logText = Read-PvLog
    $ok = $false; $bmp = $null; $err = ''
    if ($code -eq 0 -and (Test-Path -LiteralPath $pv.Out) -and ((Get-Item -LiteralPath $pv.Out).Length -gt 0)) {
        try { $bmp = Convert-FrameFile $pv.Out $logText; $ok = $true } catch { $err = $_.Exception.Message }
    } else { $err = ("exit code {0}" -f $code) }
    if ($ok) {
        Remove-PvFiles
        if ($pv.Stage -eq 'src') {
            $pv.SrcBmp = $bmp; $Script:PvBest = $pv.Attempt
            $cache.SrcKey = $pv.SrcKey; $cache.SrcBmp = $bmp; $cache.SrcAttempt = $pv.Attempt; $cache.PrcKey = ''; $cache.PrcBmp = $null
            if ($pv.HasFilters) { $pv.Stage = 'vpp'; $lbl_preview_status.Text = 'Applying VPP filters...'; Start-PvAttempt; return }
            $pv.PrcBmp = $null
        } else {
            $pv.PrcBmp = $bmp; $cache.PrcKey = $pv.PrcKey; $cache.PrcBmp = $bmp
        }
        Complete-Preview
        return
    }
    $tail = ($logText -replace '\s+', ' ')
    if ($tail.Length -gt 500) { $tail = $tail.Substring($tail.Length - 500) }
    Remove-PvFiles
    if ($pv.Stage -eq 'src' -and ($pv.Attempt + 1) -lt $pv.Attempts.Count) { $pv.Attempt++; Start-PvAttempt; return }
    if ($pv.Stage -eq 'vpp' -and $pv.SrcBmp) {
        $pv.PrcBmp = $null
        $img_original.Source = $pv.SrcBmp; $img_processed.Source = $pv.SrcBmp
        $txt_preview_placeholder.Visibility = 'Collapsed'; Update-Comparison
        Stop-Preview ('VPP preview failed (' + $err + '): ' + $tail + "`r`nCommand: " + $pv.Cmd)
        return
    }
    Stop-Preview ('Frame extraction failed (' + $err + '): ' + $tail + "`r`nLast command: " + $pv.Cmd)
}

function Start-PreviewRender {
    $pv = $Script:Pv; $cache = $Script:PvCache
    $inputPath = $txt_input.Text.Trim()
    if (-not $inputPath -or -not (Test-Path -LiteralPath $inputPath)) { $lbl_preview_status.Text = 'Choose a valid source video'; return }
    $exe = Get-SelectedEncoder
    if (-not $exe) { $lbl_preview_status.Text = 'No encoder selected (use Browse... next to the encoder box)'; return }
    $time = $txt_preview_time.Text.Trim()
    if ($time -notmatch '^(\d+:)?\d+:\d+(\.\d+)?$') { $lbl_preview_status.Text = 'Time must look like HH:MM:SS.mmm or MM:SS'; return }
    if ($pv.Busy) { Cancel-Preview }

    $filters = @(Get-FilterArgsCore -IncludeResize)
    $attempts = @(Get-PvAttempts)
    $srcKey = ($inputPath + '|' + $time + '|' + $exe + '|' + [bool]$chk_avsw.IsChecked)
    $prcKey = $srcKey + '|' + ($filters -join ' ')
    $pv.Busy = $true; $pv.Gen = $Script:PreviewGeneration; $pv.Exe = $exe; $pv.Input = $inputPath; $pv.Time = $time
    $pv.Filters = $filters; $pv.HasFilters = ($filters.Count -gt 0); $pv.Attempts = $attempts
    $pv.SrcKey = $srcKey; $pv.PrcKey = $prcKey; $pv.SrcBmp = $null; $pv.PrcBmp = $null; $pv.Out = $null; $pv.Log = $null; $pv.FromCache = $false

    if ($cache.SrcKey -eq $srcKey -and $cache.SrcBmp) {
        $pv.SrcBmp = $cache.SrcBmp; $pv.FromCache = $true
        $pv.Attempt = [Math]::Min($cache.SrcAttempt, $attempts.Count - 1)
        if (-not $pv.HasFilters) { Complete-Preview; return }
        if ($cache.PrcKey -eq $prcKey -and $cache.PrcBmp) { $pv.PrcBmp = $cache.PrcBmp; Complete-Preview; return }
        $pv.Stage = 'vpp'
    } else {
        $pv.Stage = 'src'; $pv.Attempt = [Math]::Min($Script:PvBest, $attempts.Count - 1)
    }
    $lbl_preview_status.Text = $(if ($pv.Stage -eq 'src') { 'Decoding frame with ' + [IO.Path]::GetFileName($exe) + '...' } else { 'Applying VPP filters...' })
    $btn_preview.IsEnabled = $false
    Start-PvAttempt
    if ($pv.Busy) { $Script:PvTimer.Start() }
}

# ------------------------------------------------------------ before/after display (real picture bounds + draggable divider)
function Get-PreviewBounds {
    $gw = [double]$preview_grid.ActualWidth; $gh = [double]$preview_grid.ActualHeight
    $src = $img_original.Source; if (-not $src) { $src = $img_processed.Source }
    if ($src -and $src.PixelWidth -gt 0 -and $src.PixelHeight -gt 0) {
        $scale = [Math]::Min($gw / $src.PixelWidth, $gh / $src.PixelHeight)
        $rw = $src.PixelWidth * $scale; $rh = $src.PixelHeight * $scale
    } else { $rw = $gw; $rh = $gh }
    return @{ GW = $gw; GH = $gh; W = $rw; H = $rh; Ox = ($gw - $rw) / 2; Oy = ($gh - $rh) / 2 }
}

function Update-Comparison {
    if (-not $preview_grid -or $preview_grid.ActualWidth -le 0 -or $preview_grid.ActualHeight -le 0) { return }
    $b = Get-PreviewBounds
    $mode = $Script:PreviewMode; $split = ($mode -eq 'split')
    $img_original.Visibility  = $(if ($mode -eq 'processed') { 'Collapsed' } else { 'Visible' })
    $img_processed.Visibility = $(if ($mode -eq 'original')  { 'Collapsed' } else { 'Visible' })
    $divider.Visibility = $(if ($split) { 'Visible' } else { 'Collapsed' })
    $labels.Visibility  = $(if ($split) { 'Visible' } else { 'Collapsed' })
    $sl_split.IsEnabled = $split
    $preview_grid.Cursor = $(if ($split) { [System.Windows.Input.Cursors]::SizeWE } else { [System.Windows.Input.Cursors]::Arrow })
    if ($split) {
        $x = $b.Ox + $b.W * [double]$sl_split.Value
        $clip_original.Rect = New-Object System.Windows.Rect(0, 0, $x, $b.GH)
        $divider.VerticalAlignment = 'Top'; $divider.Height = $b.H
        $divider.Margin = New-Object System.Windows.Thickness(($x - 1.5), $b.Oy, 0, 0)
        $labels.Margin  = New-Object System.Windows.Thickness($b.Ox, $b.Oy, $b.Ox, $b.Oy)
    } else {
        $clip_original.Rect = New-Object System.Windows.Rect(0, 0, $b.GW, $b.GH)
    }
}

function Set-SplitFromMouse($pt) {
    $b = Get-PreviewBounds
    if ($b.W -le 0) { return }
    $v = ($pt.X - $b.Ox) / $b.W
    $sl_split.Value = [Math]::Max($sl_split.Minimum, [Math]::Min($sl_split.Maximum, $v))
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
    ($out | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Script:PresetFile -Encoding UTF8
}
function Refresh-PresetCombo {
    $Script:Restoring = $true
    $cmb_preset.Items.Clear()
    foreach ($name in $Script:BuiltinPresets.Keys) { [void]$cmb_preset.Items.Add([string]$name) }
    foreach ($name in $Script:UserPresets.Keys)    { [void]$cmb_preset.Items.Add('* ' + $name) }
    if ($cmb_preset.Items.Count -gt 0) { $cmb_preset.SelectedIndex = 0 }
    $Script:Restoring = $false
}

# ------------------------------------------------------------ queue
function Suggest-Output {
    if ($txt_output.Text.Trim()) { return }
    $inp = $txt_input.Text.Trim(); if (-not $inp) { return }
    $txt_output.Text = Join-Path (Split-Path -Parent $inp) ([IO.Path]::GetFileNameWithoutExtension($inp) + '_vpp.mp4')
}
function Add-QueueFiles($files) {
    foreach ($f in $files) { if ([IO.File]::Exists([string]$f) -and -not ($lst_queue.Items -contains [string]$f)) { [void]$lst_queue.Items.Add([string]$f) } }
    if (-not $txt_input.Text -and $lst_queue.Items.Count -gt 0) { $txt_input.Text = [string]$lst_queue.Items[0]; Suggest-Output }
    Update-CommandPreview; Schedule-Preview
}
function Browse-Videos {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Add videos to the queue'; $dialog.Multiselect = $true
    $dialog.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.webm;*.vob;*.mpg;*.mpeg;*.mxf;*.dv|All files|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Add-QueueFiles $dialog.FileNames }
}
function Browse-Output {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Choose output video'; $dialog.Filter = 'MP4|*.mp4|Matroska|*.mkv|MPEG-TS|*.ts|All files|*.*'
    $dialog.FileName = $(if ($txt_output.Text) { [IO.Path]::GetFileName($txt_output.Text) } else { 'output.mp4' })
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txt_output.Text = $dialog.FileName; Update-CommandPreview }
}
function Get-OutputForItem([string]$InputPath) {
    if ($Script:QueueItems.Count -eq 1) { return $txt_output.Text.Trim() }
    $ext = [IO.Path]::GetExtension($txt_output.Text); if (-not $ext) { $ext = '.mp4' }
    return Join-Path (Split-Path -Parent $txt_output.Text) ([IO.Path]::GetFileNameWithoutExtension($InputPath) + '_vpp' + $ext)
}
function Start-Queue {
    if ($Script:Process -and -not $Script:Process.HasExited) { return }
    $items = @(); foreach ($item in $lst_queue.Items) { $items += [string]$item }
    if (-not $items.Count -and $txt_input.Text.Trim() -and (Test-Path -LiteralPath $txt_input.Text.Trim())) { $items = @($txt_input.Text.Trim()) }
    if (-not $items.Count) { [void][Windows.MessageBox]::Show('Add a valid source video.', 'Input required', 'OK', 'Warning'); return }
    Suggest-Output
    if (-not $txt_output.Text.Trim()) { [void][Windows.MessageBox]::Show('Choose an output file.', 'Output required', 'OK', 'Warning'); return }
    $exe = Get-SelectedEncoder
    if (-not $exe) { [void][Windows.MessageBox]::Show('No encoder selected. Use Browse... next to the encoder box.', 'Encoder missing', 'OK', 'Error'); return }
    $Script:QueueItems = $items; $Script:QueueIndex = 0; $Script:Encoder = $exe; $Script:ReadOut = 0L; $Script:ReadErr = 0L
    Set-Content -LiteralPath $Script:StdoutPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $Script:StderrPath -Value '' -Encoding UTF8
    $txt_log.Clear(); $btn_start.IsEnabled = $false; $btn_stop.IsEnabled = $true; $pb_progress.Value = 0
    Start-NextEncode
    $Script:Timer.Start()
}
function Start-NextEncode {
    if ($Script:QueueIndex -ge $Script:QueueItems.Count) {
        $Script:Timer.Stop(); $btn_start.IsEnabled = $true; $btn_stop.IsEnabled = $false
        $pb_progress.Value = 100; $lbl_status.Text = 'Queue complete'; Add-Log 'Queue complete.'; $Script:Process = $null; return
    }
    $inputPath = [string]$Script:QueueItems[$Script:QueueIndex]
    if (-not (Test-Path -LiteralPath $inputPath)) { Add-Log ("Skipped missing input: " + $inputPath); $Script:QueueIndex++; Start-NextEncode; return }
    $outputPath = Get-OutputForItem $inputPath
    $encArgs = @(Get-EncoderArguments $inputPath $outputPath)
    $pb_progress.Value = 0; $Script:ReadOut = 0L; $Script:ReadErr = 0L
    $lbl_status.Text = ("Encoding {0}/{1}: {2}" -f ($Script:QueueIndex + 1), $Script:QueueItems.Count, [IO.Path]::GetFileName($inputPath))
    Add-Log ("[{0}/{1}] {2}" -f ($Script:QueueIndex + 1), $Script:QueueItems.Count, [IO.Path]::GetFileName($inputPath))
    Add-Log (Command-LineText (@($Script:Encoder) + $encArgs))
    try {
        $Script:Process = Start-Process -FilePath $Script:Encoder -ArgumentList (Command-LineText $encArgs) -NoNewWindow -PassThru `
            -RedirectStandardOutput $Script:StdoutPath -RedirectStandardError $Script:StderrPath
        $null = $Script:Process.Handle
    } catch { Add-Log ("Failed to start encoder: " + $_.Exception.Message); $Script:QueueIndex++; Start-NextEncode }
}
function Stop-Queue {
    if ($Script:Process -and -not $Script:Process.HasExited) { try { $Script:Process.Kill() } catch { } }
    $Script:Timer.Stop(); $Script:Process = $null; $btn_start.IsEnabled = $true; $btn_stop.IsEnabled = $false
    $lbl_status.Text = 'Stopped'; Add-Log 'Queue stopped.'
}

# ------------------------------------------------------------ XAML (literal colours only)
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VPPBox v2.6 - rigaya HWEnc" Width="1320" Height="800" MinWidth="900" MinHeight="520" AllowDrop="True"
        WindowStartupLocation="CenterScreen" Background="#1B1E27" Foreground="#E9ECF3" FontFamily="Segoe UI" FontSize="13">
<Window.Resources>
  <Style TargetType="{x:Type Button}">
    <Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Background" Value="#39404F"/>
    <Setter Property="BorderBrush" Value="#4A5266"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="{x:Type Button}">
        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#465062"/><Setter Property="BorderBrush" Value="#5E8BFF"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#2C3140"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type ToggleButton}">
    <Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Background" Value="#39404F"/>
    <Setter Property="BorderBrush" Value="#4A5266"/><Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="{x:Type ToggleButton}">
        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter Property="Background" Value="#5E8BFF"/><Setter Property="BorderBrush" Value="#8AB4F8"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="#5E8BFF"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value></Setter>
  </Style>
  <Style TargetType="{x:Type TextBox}">
    <Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Background" Value="#171A22"/>
    <Setter Property="CaretBrush" Value="#FFFFFF"/><Setter Property="SelectionBrush" Value="#5E8BFF"/>
    <Setter Property="BorderBrush" Value="#4A5266"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="7,5"/>
  </Style>
  <Style TargetType="{x:Type ComboBox}">
    <Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Background" Value="#2B303C"/>
    <Setter Property="BorderBrush" Value="#4A5266"/><Setter Property="Padding" Value="6,4"/>
  </Style>
  <Style TargetType="{x:Type ComboBoxItem}">
    <Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Background" Value="#2B303C"/><Setter Property="Padding" Value="7,5"/>
  </Style>
  <Style TargetType="{x:Type ListBoxItem}"><Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Padding" Value="6,3"/></Style>
  <Style TargetType="{x:Type CheckBox}"><Setter Property="Foreground" Value="#E9ECF3"/><Setter Property="Margin" Value="2,3"/></Style>
  <Style TargetType="{x:Type Separator}"><Setter Property="Background" Value="#3B4150"/><Setter Property="Margin" Value="0,8"/></Style>
  <Style TargetType="{x:Type ToolTip}">
    <Setter Property="Background" Value="#2B303C"/><Setter Property="Foreground" Value="#E9ECF3"/>
    <Setter Property="BorderBrush" Value="#5E8BFF"/><Setter Property="Padding" Value="8"/>
  </Style>
</Window.Resources>
<Grid Margin="12">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border Background="#242832" BorderBrush="#3B4150" BorderThickness="1" Padding="14,8" CornerRadius="8" Margin="0,0,0,8">
    <DockPanel>
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="VPPBox" FontSize="22" FontWeight="Bold" Foreground="#8AB4F8"/>
        <TextBlock Text="  v2.6 - rigaya HWEnc (no VapourSynth, no FFmpeg)" VerticalAlignment="Center" Foreground="#B0BAD0" Margin="10,4,0,0"/>
      </StackPanel>
      <StackPanel DockPanel.Dock="Right" HorizontalAlignment="Right">
        <TextBlock x:Name="lbl_status" Text="Ready - drop video files anywhere on the window" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        <TextBlock x:Name="lbl_gpu" Text="Detecting..." FontSize="11" Foreground="#B0BAD0" HorizontalAlignment="Right"/>
      </StackPanel>
    </DockPanel>
  </Border>
  <Grid Grid.Row="1">
    <Grid.ColumnDefinitions><ColumnDefinition Width="1.75*" MinWidth="440"/><ColumnDefinition Width="6"/><ColumnDefinition Width="1*" MinWidth="380"/></Grid.ColumnDefinitions>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="1.55*" MinHeight="200"/><RowDefinition Height="0.7*" MinHeight="80"/><RowDefinition Height="120"/></Grid.RowDefinitions>
      <Border Background="#242832" BorderBrush="#3B4150" BorderThickness="1" CornerRadius="8" Padding="12" Margin="0,0,0,8">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,8">
            <TextBlock Text="BEFORE / AFTER PREVIEW" FontSize="12" FontWeight="Bold" Foreground="#B0BAD0" VerticalAlignment="Center"/>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <TextBlock x:Name="lbl_preview_status" Text="Choose a source and time" VerticalAlignment="Center" FontSize="11" Foreground="#B0BAD0" Margin="0,0,8,0"/>
              <TextBox x:Name="txt_preview_time" Text="00:00:01.000" Width="110" ToolTip="Frame time (HH:MM:SS.mmm or MM:SS)"/>
              <Button x:Name="btn_preview" Content="Refresh"/>
            </StackPanel>
          </DockPanel>
          <Border Grid.Row="1" Background="#101218" CornerRadius="6" ClipToBounds="True">
            <Grid x:Name="preview_grid" Background="Transparent">
              <Image x:Name="img_processed" Stretch="Uniform"/>
              <Image x:Name="img_original" Stretch="Uniform"><Image.Clip><RectangleGeometry x:Name="clip_original"/></Image.Clip></Image>
              <Border x:Name="divider" Width="3" Background="#FFFFFF" HorizontalAlignment="Left" IsHitTestVisible="False" Opacity="0.85"/>
              <Grid x:Name="labels" IsHitTestVisible="False">
                <TextBlock Text="Source" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10" Padding="7,3" Background="#CC101218" Foreground="#FFFFFF"/>
                <TextBlock Text="VPP processed" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="10" Padding="7,3" Background="#CC3D6FE0" Foreground="#FFFFFF"/>
              </Grid>
              <TextBlock x:Name="txt_preview_placeholder" Text="Pick a video, set a time and press Refresh. Frames are decoded by the selected rigaya encoder (-c raw). Drag in the picture to move the divider."
                         TextWrapping="Wrap" TextAlignment="Center" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#B0BAD0" IsHitTestVisible="False" MaxWidth="420"/>
            </Grid>
          </Border>
          <DockPanel Grid.Row="2" Margin="0,8,0,0">
            <ToggleButton x:Name="tgl_mode_original" Content="Original" MinWidth="90"/>
            <ToggleButton x:Name="tgl_mode_processed" Content="Processed" MinWidth="90"/>
            <ToggleButton x:Name="tgl_mode_split" Content="Split" IsChecked="True" MinWidth="90"/>
            <Slider x:Name="sl_split" Minimum="0.02" Maximum="0.98" Value="0.5" Margin="10,0" VerticalAlignment="Center"/>
          </DockPanel>
        </Grid>
      </Border>
      <Border Grid.Row="1" Background="#242832" BorderBrush="#3B4150" BorderThickness="1" CornerRadius="8" Padding="10" Margin="0,0,0,8">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel>
            <TextBlock Text="VIDEO QUEUE" FontSize="12" FontWeight="Bold" Foreground="#B0BAD0" VerticalAlignment="Center"/>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="btn_add" Content="+ Add videos"/><Button x:Name="btn_remove" Content="Remove"/><Button x:Name="btn_clear" Content="Clear"/>
            </StackPanel>
          </DockPanel>
          <ListBox x:Name="lst_queue" Grid.Row="1" Margin="0,6,0,0" Background="#171A22" BorderBrush="#4A5266" BorderThickness="1"/>
        </Grid>
      </Border>
      <Border Grid.Row="2" Background="#242832" BorderBrush="#3B4150" BorderThickness="1" CornerRadius="8" Padding="10">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock Text="PROCESSING LOG" FontSize="12" FontWeight="Bold" Foreground="#B0BAD0" Margin="0,0,0,6"/>
          <TextBox x:Name="txt_log" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   Background="#171A22" BorderBrush="#4A5266" BorderThickness="1" FontFamily="Consolas" FontSize="11.5" Foreground="#CFE0FF"/>
        </Grid>
      </Border>
    </Grid>
    <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" Background="#2E3341"/>
    <Border Grid.Column="2" Background="#242832" BorderBrush="#3B4150" BorderThickness="1" CornerRadius="8" Padding="14">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <TextBlock Text="PRESETS" FontSize="12.5" FontWeight="Bold" Foreground="#8AB4F8"/>
          <DockPanel Margin="0,6,0,10"><Button x:Name="btn_save_preset" Content="Save..." DockPanel.Dock="Right" MinWidth="62"/><ComboBox x:Name="cmb_preset"/></DockPanel>
          <TextBlock Text="SOURCE AND OUTPUT" FontSize="12.5" FontWeight="Bold" Foreground="#8AB4F8"/>
          <TextBlock Text="Input video" FontSize="11" Foreground="#B0BAD0" Margin="0,6,0,0"/>
          <DockPanel Margin="0,4,0,8"><Button x:Name="btn_input" Content="Browse..." DockPanel.Dock="Right"/><TextBox x:Name="txt_input"/></DockPanel>
          <TextBlock Text="Output video" FontSize="11" Foreground="#B0BAD0"/>
          <DockPanel Margin="0,4,0,8"><Button x:Name="btn_output" Content="Browse..." DockPanel.Dock="Right"/><TextBox x:Name="txt_output"/></DockPanel>
          <TextBlock Text="ENCODER" FontSize="12.5" FontWeight="Bold" Foreground="#8AB4F8"/>
          <TextBlock Text="Detected encoder (or pick one manually)" FontSize="11" Foreground="#B0BAD0" Margin="0,6,0,0"/>
          <DockPanel Margin="0,4,0,8"><Button x:Name="btn_enc_browse" Content="Browse..." DockPanel.Dock="Right"/><ComboBox x:Name="cmb_encoder"/></DockPanel>
          <TextBlock Text="Codec" FontSize="11" Foreground="#B0BAD0"/>
          <ComboBox x:Name="cmb_codec" SelectedIndex="1" Margin="0,4,0,8">
            <ComboBoxItem Content="H.264 / AVC"/><ComboBoxItem Content="HEVC / H.265"/><ComboBoxItem Content="AV1"/>
          </ComboBox>
          <DockPanel Margin="0,2,0,6">
            <TextBlock Text="Rate mode" FontSize="11" Foreground="#B0BAD0" VerticalAlignment="Center" Width="80"/>
            <ComboBox x:Name="cmb_mode" SelectedIndex="0"><ComboBoxItem Content="CQP (quality)"/><ComboBoxItem Content="VBR (bitrate)"/><ComboBoxItem Content="CBR (bitrate)"/></ComboBox>
          </DockPanel>
          <Grid Margin="0,0,0,8">
            <StackPanel x:Name="pnl_cqp">
              <DockPanel>
                <TextBlock x:Name="lbl_quality" Text="20" Width="32" TextAlignment="Right" VerticalAlignment="Center" FontFamily="Consolas" DockPanel.Dock="Right"/>
                <TextBlock Text="CQP quality (lower = better)" FontSize="11" Foreground="#B0BAD0" VerticalAlignment="Center"/>
              </DockPanel>
              <Slider x:Name="sl_quality" Minimum="1" Maximum="51" Value="20" TickFrequency="1" IsSnapToTickEnabled="True"/>
            </StackPanel>
            <StackPanel x:Name="pnl_bitrate" Visibility="Collapsed">
              <TextBlock Text="Bitrate (kbps)" FontSize="11" Foreground="#B0BAD0"/><TextBox x:Name="txt_bitrate" Text="8000"/>
            </StackPanel>
          </Grid>
          <CheckBox x:Name="chk_audio" Content="Copy audio streams" IsChecked="True"/>
          <CheckBox x:Name="chk_avsw" Content="Software decoder (--avsw) - for sources the GPU cannot decode (DV AVI, odd codecs)"/>
          <Separator/>
          <TextBlock Text="TRIM (optional)" FontSize="12.5" FontWeight="Bold" Foreground="#8AB4F8"/>
          <DockPanel Margin="0,6,0,10">
            <StackPanel Width="150" Margin="0,0,8,0"><TextBlock Text="Start at (seek)" FontSize="11" Foreground="#B0BAD0"/><TextBox x:Name="txt_trim_start" ToolTip="Empty = start. Format HH:MM:SS.mmm"/></StackPanel>
            <StackPanel><TextBlock Text="Max frames (empty = all)" FontSize="11" Foreground="#B0BAD0"/><TextBox x:Name="txt_trim_frames"/></StackPanel>
          </DockPanel>
          <Separator/>
          <TextBlock Text="VPP FILTERS" FontSize="12.5" FontWeight="Bold" Foreground="#8AB4F8"/>
          <TextBlock Text="Filters missing from your encoder build are greyed out (read from --option-list)." FontSize="11" Foreground="#B0BAD0" TextWrapping="Wrap" Margin="0,2,0,8"/>
          <StackPanel x:Name="sp_filters"/>
          <Separator/>
          <TextBlock Text="COMMAND PREVIEW" FontWeight="Bold" FontSize="12.5" Foreground="#8AB4F8" Margin="0,0,0,6"/>
          <TextBox x:Name="txt_command" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" MinHeight="80" FontFamily="Consolas" FontSize="11" Foreground="#CFE0FF" Padding="8"/>
          <Button x:Name="btn_copy" Content="Copy command" HorizontalAlignment="Left" Margin="0,8,0,0"/>
        </StackPanel>
      </ScrollViewer>
    </Border>
  </Grid>
  <DockPanel Grid.Row="2" Margin="0,6,0,0">
    <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
      <Button x:Name="btn_stop" Content="Stop" IsEnabled="False" MinWidth="90"/>
      <Button x:Name="btn_start" Content="Go" MinWidth="120" Background="#3D6FE0" Foreground="#FFFFFF" FontWeight="Bold"/>
    </StackPanel>
    <ProgressBar x:Name="pb_progress" Minimum="0" Maximum="100" Height="10" Margin="0,0,12,0" VerticalAlignment="Center" Background="#171A22" Foreground="#5E8BFF" BorderBrush="#4A5266"/>
  </DockPanel>
</Grid>
</Window>
'@

# ------------------------------------------------------------ load window
$reader = New-Object System.Xml.XmlNodeReader $xaml
try { $window = [Windows.Markup.XamlReader]::Load($reader) }
catch { [void][Windows.MessageBox]::Show("XAML failed to load:`r`n$($_.Exception.Message)", 'VPPBox', 'OK', 'Error'); throw }

# initial size: never taller than 90% of the screen (and never wider than 95%)
$wa = [System.Windows.SystemParameters]::WorkArea
$maxH = [Math]::Floor([Math]::Min([System.Windows.SystemParameters]::PrimaryScreenHeight * 0.9, $wa.Height))
$maxW = [Math]::Floor([Math]::Min([System.Windows.SystemParameters]::PrimaryScreenWidth * 0.95, $wa.Width))
$window.MinHeight = [Math]::Min(520, $maxH); $window.MinWidth = [Math]::Min(900, $maxW)
$window.Height = [Math]::Min(880, $maxH);    $window.Width = [Math]::Min(1320, $maxW)

$names = @('lbl_status','lbl_gpu','lbl_preview_status','txt_preview_time','txt_preview_placeholder','txt_log','txt_input','txt_output',
  'cmb_encoder','btn_enc_browse','cmb_codec','cmb_mode','sl_quality','lbl_quality','pnl_cqp','pnl_bitrate','txt_bitrate','chk_audio','chk_avsw',
  'txt_trim_start','txt_trim_frames','txt_command','cmb_preset','btn_save_preset','sp_filters','btn_input','btn_output','btn_add','btn_remove',
  'btn_clear','lst_queue','btn_preview','img_original','img_processed','preview_grid','clip_original','divider','labels','sl_split',
  'tgl_mode_original','tgl_mode_processed','tgl_mode_split','btn_copy','btn_stop','btn_start','pb_progress')
foreach ($n in $names) {
    $ctl = $window.FindName($n)
    if ($null -eq $ctl) { throw "XAML control not found: $n" }
    Set-Variable -Name $n -Value $ctl -Scope Script
}

Build-AllFilterPanels $sp_filters
Load-UserPresets
Refresh-PresetCombo

# ------------------------------------------------------------ GPU + encoder detection: the v1 method
# One entry per detected GPU (vendor -> exe), path via Resolve-EncoderExecutable (script folder, current folder, PATH).
# Tag = the path string (or $null when the exe is missing). Then any of the 3 exes found without a matching GPU is added.
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
    Add-Log 'No encoder found. Looked for NVEncC64.exe / VCEEncC64.exe / QSVEncC64.exe in the script folder, the current folder and PATH. Use Browse... next to the encoder box.'
    $lbl_gpu.Text += '  |  no encoder found - use Browse...'
}

$btn_enc_browse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select a rigaya encoder executable'
    $dialog.Filter = 'rigaya encoders|NVEncC64.exe;QSVEncC64.exe;VCEEncC64.exe|Executables|*.exe|All files|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $item = Add-EncoderItem ([IO.Path]::GetFileName($dialog.FileName)) 'manual selection' $dialog.FileName
        $cmb_encoder.SelectedItem = $item
        Add-Log ('Encoder selected manually: ' + $dialog.FileName)
    }
})

# ------------------------------------------------------------ events
$cmb_mode.Add_SelectionChanged({
    $pnl_cqp.Visibility = $(if ($cmb_mode.SelectedIndex -eq 0) { 'Visible' } else { 'Collapsed' })
    $pnl_bitrate.Visibility = $(if ($cmb_mode.SelectedIndex -eq 0) { 'Collapsed' } else { 'Visible' })
    Update-CommandPreview
})

function Set-PreviewMode([string]$mode) {
    $Script:PreviewMode = $mode
    $tgl_mode_original.IsChecked = ($mode -eq 'original'); $tgl_mode_processed.IsChecked = ($mode -eq 'processed'); $tgl_mode_split.IsChecked = ($mode -eq 'split')
    Update-Comparison
}
$tgl_mode_original.Add_Click({ Set-PreviewMode 'original' })
$tgl_mode_processed.Add_Click({ Set-PreviewMode 'processed' })
$tgl_mode_split.Add_Click({ Set-PreviewMode 'split' })

$preview_grid.Add_MouseLeftButtonDown({ param($s, $e) if ($Script:PreviewMode -ne 'split') { return }; [void]$s.CaptureMouse(); Set-SplitFromMouse ($e.GetPosition($s)) })
$preview_grid.Add_MouseMove({ param($s, $e) if ($s.IsMouseCaptured) { Set-SplitFromMouse ($e.GetPosition($s)) } })
$preview_grid.Add_MouseLeftButtonUp({ param($s, $e) if ($s.IsMouseCaptured) { $s.ReleaseMouseCapture() } })

$window.Add_PreviewDragOver({ param($s, $e)
    $e.Effects = $(if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None })
    $e.Handled = $true })
$window.Add_PreviewDrop({ param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { Add-QueueFiles ($e.Data.GetData([Windows.DataFormats]::FileDrop)) }
    $e.Handled = $true })

$btn_input.Add_Click({ Browse-Videos }); $btn_add.Add_Click({ Browse-Videos }); $btn_output.Add_Click({ Browse-Output })
$btn_start.Add_Click({ Start-Queue }); $btn_stop.Add_Click({ Stop-Queue })
$btn_copy.Add_Click({ try { [Windows.Clipboard]::SetText($txt_command.Text); $lbl_status.Text = 'Command copied.' } catch { } })
$btn_remove.Add_Click({ foreach ($item in @($lst_queue.SelectedItems)) { [void]$lst_queue.Items.Remove($item) }; Update-CommandPreview })
$btn_clear.Add_Click({ if ($btn_start.IsEnabled) { $lst_queue.Items.Clear(); Update-CommandPreview } })
$lst_queue.Add_SelectionChanged({
    if ($lst_queue.SelectedItem) { $txt_input.Text = [string]$lst_queue.SelectedItem; Suggest-Output; Update-CommandPreview; Schedule-Preview }
})

$cmb_preset.Add_SelectionChanged({
    if ($Script:Restoring) { return }
    $name = [string]$cmb_preset.SelectedItem
    if (-not $name) { return }
    if ($name.StartsWith('* ')) { $k = $name.Substring(2); if ($Script:UserPresets.Contains($k)) { Restore-Settings $Script:UserPresets[$k] } }
    elseif ($Script:BuiltinPresets.Contains($name)) { Restore-Settings $Script:BuiltinPresets[$name] }
})
$btn_save_preset.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Preset name:', 'Save preset', '')
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $name = $name.Trim()
    $snap = Get-SettingsSnapshot
    $ht = @{}
    foreach ($k in $snap.Keys) {
        $v = @{ On = $snap[$k].On; Values = @{} }
        foreach ($kk in $snap[$k].Values.Keys) { $v.Values[$kk] = $snap[$k].Values[$kk] }
        $ht[$k] = $v
    }
    $Script:UserPresets[$name] = $ht
    Save-UserPresets; Refresh-PresetCombo
    $Script:Restoring = $true; $cmb_preset.SelectedItem = '* ' + $name; $Script:Restoring = $false
    $lbl_status.Text = "Preset '$name' saved."
})

$btn_preview.Add_Click({
    $Script:PreviewGeneration++
    $Script:PvCache.SrcKey = ''; $Script:PvCache.SrcBmp = $null; $Script:PvCache.PrcKey = ''; $Script:PvCache.PrcBmp = $null
    Start-PreviewRender
})
$txt_preview_time.Add_TextChanged({ Schedule-Preview })
$preview_grid.Add_SizeChanged({ Update-Comparison })
$sl_split.Add_ValueChanged({ Update-Comparison })
$txt_input.Add_TextChanged({ Update-CommandPreview; Schedule-Preview })
$txt_output.Add_TextChanged({ Update-CommandPreview })
$cmb_encoder.Add_SelectionChanged({
    Update-CommandPreview
    if (Get-SelectedEncoder) { Update-EncoderCapabilities }
    $Script:PvBest = 0
    Schedule-Preview
})
$cmb_codec.Add_SelectionChanged({ Update-CommandPreview })
$sl_quality.Add_ValueChanged({ $lbl_quality.Text = [string][int]$sl_quality.Value; Update-CommandPreview })
$chk_audio.Add_Checked({ Update-CommandPreview }); $chk_audio.Add_Unchecked({ Update-CommandPreview })
$chk_avsw.Add_Checked({ $Script:PvBest = 0; Update-CommandPreview; Schedule-Preview }); $chk_avsw.Add_Unchecked({ $Script:PvBest = 0; Update-CommandPreview; Schedule-Preview })
$txt_trim_start.Add_TextChanged({ Update-CommandPreview }); $txt_trim_frames.Add_TextChanged({ Update-CommandPreview }); $txt_bitrate.Add_TextChanged({ Update-CommandPreview })

# ------------------------------------------------------------ timers (UI thread only)
$Script:PreviewTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:PreviewTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$Script:PreviewTimer.Add_Tick({ $Script:PreviewTimer.Stop(); Start-PreviewRender })

$Script:PvTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:PvTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$Script:PvTimer.Add_Tick({ Poll-Preview })

$Script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$Script:Timer.Add_Tick({
    Tail-LogFile $Script:StdoutPath ([ref]$Script:ReadOut)
    Tail-LogFile $Script:StderrPath ([ref]$Script:ReadErr)
    if ($Script:Process -and $Script:Process.HasExited) {
        Tail-LogFile $Script:StdoutPath ([ref]$Script:ReadOut)
        Tail-LogFile $Script:StderrPath ([ref]$Script:ReadErr)
        $code = $Script:Process.ExitCode
        if ($code -eq 0) { Add-Log 'Encode finished.'; $pb_progress.Value = 100 } else { Add-Log ('Encoder exited with code ' + $code + '.') }
        $Script:Process = $null; $Script:QueueIndex++; Start-NextEncode
    }
})

$window.Add_Closing({
    foreach ($t in @($Script:Timer, $Script:PreviewTimer, $Script:PvTimer)) { if ($t) { $t.Stop() } }
    foreach ($pr in @($Script:Process, $Script:Pv.Proc)) { if ($pr -and -not $pr.HasExited) { try { $pr.Kill() } catch { } } }
    Remove-Item -LiteralPath $Script:StdoutPath, $Script:StderrPath -Force -ErrorAction SilentlyContinue
})

$lbl_quality.Text = [string][int]$sl_quality.Value
Update-CommandPreview
if (Get-SelectedEncoder) { Update-EncoderCapabilities }
$window.Add_ContentRendered({ Update-Comparison })
$null = $window.ShowDialog()
