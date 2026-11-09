# VPPBox — lightweight Windows PowerShell GUI for rigaya hardware encoders.
# Windows PowerShell 5.1+ with WPF. Frame previews are decoded/processed by the
# selected rigaya encoder itself, using raw Y4M output; FFmpeg is not required.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Process = $null
$Script:Timer = $null
$Script:PreviewTimer = $null
$Script:PreviewWorker = $null
$Script:PreviewGeneration = 0
$Script:QueueItems = @()
$Script:QueueIndex = 0
$Script:StdoutPath = Join-Path $env:TEMP ("vppbox-{0}.out" -f [guid]::NewGuid())
$Script:StderrPath = Join-Path $env:TEMP ("vppbox-{0}.err" -f [guid]::NewGuid())
$Script:ReadOut = 0L
$Script:ReadErr = 0L
$Script:DetectedGpus = @()
$Script:EncoderChoices = @()

function Get-VideoControllers {
    try { return @(Get-WmiObject -Class Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
    catch {
        try { return @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) }
        catch { return @() }
    }
}

function Get-EncoderCandidates {
    $names = Get-VideoControllers
    $Script:DetectedGpus = $names
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($gpu in $names) {
        $exe = $null
        if ($gpu -match 'NVIDIA|GeForce|Quadro|RTX|Tesla') { $exe = 'NVEncC64.exe' }
        elseif ($gpu -match 'AMD|Radeon|FirePro') { $exe = 'VCEEncC64.exe' }
        elseif ($gpu -match 'Intel|Arc|Iris|UHD Graphics|HD Graphics') { $exe = 'QSVEncC64.exe' }
        if ($exe -and -not ($candidates | Where-Object { $_.Exe -eq $exe })) {
            $resolved = Resolve-EncoderExecutable $exe
            $candidates.Add([pscustomobject]@{Gpu=$gpu; Exe=$exe; Path=$resolved})
        }
    }
    if ($candidates.Count -eq 0) {
        foreach ($exe in @('NVEncC64.exe','VCEEncC64.exe','QSVEncC64.exe')) {
            $resolved = Resolve-EncoderExecutable $exe
            if ($resolved) { $candidates.Add([pscustomobject]@{Gpu='Detected from PATH';Exe=$exe;Path=$resolved}) }
        }
    }
    return @($candidates)
}

function Resolve-EncoderExecutable {
    param([string]$Name)
    $local = Join-Path $Script:Root $Name
    if (Test-Path -LiteralPath $local) { return $local }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-SelectedEncoder {
    if ($cmb_encoder.SelectedItem -and $cmb_encoder.SelectedItem.Tag) { return [string]$cmb_encoder.SelectedItem.Tag }
    return $null
}

function Get-FilterArguments {
    $args = @()
    if ($chk_knn.IsChecked) { $args += @('--vpp-knn', ('radius={0},strength={1:0.00}' -f [int]$sl_radius.Value, [double]$sl_strength.Value)) }
    if ($chk_deband.IsChecked) { $args += @('--vpp-deband', ('range={0},thre={1},dither={2}' -f [int]$sl_range.Value, [int]$sl_threshold.Value, [int]$sl_dither.Value)) }
    if ($chk_unsharp.IsChecked) { $args += @('--vpp-unsharp', ('weight={0:0.00}' -f [double]$sl_unsharp.Value)) }
    if ($chk_resize.IsChecked -and [int]$txt_width.Text -gt 0 -and [int]$txt_height.Text -gt 0) { $args += @('--output-res', ('{0}x{1}' -f [int]$txt_width.Text, [int]$txt_height.Text)) }
    return ,$args
}

function Get-EncoderArguments {
    param([string]$InputPath, [string]$OutputPath)
    $args = @('--avhw', '--codec', $(if ($cmb_codec.SelectedIndex -eq 0) { 'h264' } else { 'hevc' }), '--cqp', ([int]$sl_quality.Value).ToString())
    $args += Get-FilterArguments
    if ($chk_audio.IsChecked) { $args += '--audio-copy' }
    $args += @('-i', $InputPath, '-o', $OutputPath)
    return ,$args
}

function Get-FrameArguments {
    param([string]$InputPath, [string]$OutputPath)
    $time = $txt_preview_time.Text.Trim()
    $args = @('--avhw', '--seek', $time, '--frames', '1', '--codec', 'raw', '--output-format', 'y4m', '--output-csp', 'yuv420', '--output-depth', '8')
    $args += Get-FilterArguments
    $args += @('-i', $InputPath, '-o', $OutputPath)
    return ,$args
}

function Quote-Argument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Update-CommandPreview {
    if (-not $txt_command) { return }
    $exe = Get-SelectedEncoder
    if (-not $exe) { $exe = 'NVEncC64.exe' }
    $inputPath = if ($txt_input.Text.Trim()) { $txt_input.Text.Trim() } else { 'INPUT' }
    $outputPath = if ($txt_output.Text.Trim()) { $txt_output.Text.Trim() } else { 'OUTPUT' }
    $parts = @($exe) + @(Get-EncoderArguments $inputPath $outputPath)
    $txt_command.Text = (($parts | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
}

function Add-Log {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $txt_log.AppendText($Text.TrimEnd() + "`r`n")
    $txt_log.ScrollToEnd()
}

function Tail-LogFile {
    param([string]$Path, [ref]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0 }
            [void]$stream.Seek($Offset.Value, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            $Offset.Value = $stream.Position
            if ($text) { foreach ($line in ($text -split "`r?`n")) { if ($line) { Add-Log $line } } }
        } finally { $stream.Dispose() }
    } catch { }
}

function Browse-Videos {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Add videos to queue'; $dialog.Multiselect = $true
    $dialog.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.webm|All files|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($path in $dialog.FileNames) { if (-not ($lst_queue.Items -contains $path)) { [void]$lst_queue.Items.Add($path) } }
        if (-not $txt_input.Text -and $lst_queue.Items.Count -gt 0) {
            $txt_input.Text = [string]$lst_queue.Items[0]
            if (-not $txt_output.Text) { $name=[IO.Path]::GetFileNameWithoutExtension($txt_input.Text); $txt_output.Text=Join-Path (Split-Path -Parent $txt_input.Text) ($name+'_encoded.mp4') }
        }
        Update-CommandPreview; Schedule-Preview
    }
}

function Browse-Output {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Choose output video'; $dialog.Filter = 'MP4 video|*.mp4|Matroska video|*.mkv|All files|*.*'
    $dialog.FileName = if ($txt_output.Text) { [IO.Path]::GetFileName($txt_output.Text) } else { 'output.mp4' }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txt_output.Text=$dialog.FileName; Update-CommandPreview }
}

function Update-Comparison {
    if (-not $preview_grid -or $preview_grid.ActualWidth -le 0) { return }
    $x = $preview_grid.ActualWidth * [double]$sl_split.Value
    $clip_original.Rect = New-Object System.Windows.Rect(0,0,$x,$preview_grid.ActualHeight)
    $divider.Margin = New-Object System.Windows.Thickness(($x-1.5),0,0,0)
}

function Convert-Y4mToBitmap {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $headerEnd = [Array]::IndexOf($bytes, [byte]10, $offset)
    if ($headerEnd -lt 0) { throw 'Encoder output is missing the Y4M header.' }
    $header = [Text.Encoding]::ASCII.GetString($bytes, 0, $headerEnd)
    $widthMatch = [regex]::Match($header, '\bW(\d+)')
    $heightMatch = [regex]::Match($header, '\bH(\d+)')
    if (-not $widthMatch.Success -or -not $heightMatch.Success) { throw "Invalid Y4M dimensions header: $header" }
    $width=[int]$widthMatch.Groups[1].Value; $height=[int]$heightMatch.Groups[1].Value
    $frameHeaderEnd = [Array]::IndexOf($bytes, [byte]10, $headerEnd + 1)
    if ($frameHeaderEnd -lt 0) { throw 'Encoder output contains no Y4M frame.' }
    $frameHeader = [Text.Encoding]::ASCII.GetString($bytes, $headerEnd+1, $frameHeaderEnd-$headerEnd-1)
    if (-not $frameHeader.StartsWith('FRAME')) { throw 'Y4M frame marker was not found.' }
    $dataStart=$frameHeaderEnd+1; $ySize=$width*$height; $chromaW=[int][Math]::Ceiling($width/2.0); $chromaH=[int][Math]::Ceiling($height/2.0); $cSize=$chromaW*$chromaH
    if ($bytes.Length -lt ($dataStart+$ySize+2*$cSize)) { throw 'Y4M frame payload is truncated or is not 8-bit 4:2:0.' }
    $bgra=New-Object byte[] ($width*$height*4)
    $uStart=$dataStart+$ySize; $vStart=$uStart+$cSize
    for($y=0;$y -lt $height;$y++) { for($x=0;$x -lt $width;$x++) {
        $yy=[double]$bytes[$dataStart+$y*$width+$x]; $u=[double]$bytes[$uStart+[int]($y/2)*$chromaW+[int]($x/2)]-128; $v=[double]$bytes[$vStart+[int]($y/2)*$chromaW+[int]($x/2)]-128
        $r=[Math]::Max(0,[Math]::Min(255,[int][Math]::Round($yy+1.402*$v))); $g=[Math]::Max(0,[Math]::Min(255,[int][Math]::Round($yy-0.344136*$u-0.714136*$v))); $b=[Math]::Max(0,[Math]::Min(255,[int][Math]::Round($yy+1.772*$u))); $i=($y*$width+$x)*4
        $bgra[$i]=$b; $bgra[$i+1]=$g; $bgra[$i+2]=$r; $bgra[$i+3]=255
    } }
    return [Windows.Media.Imaging.BitmapSource]::Create($width,$height,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$bgra,$width*4)
}

function Schedule-Preview {
    $Script:PreviewGeneration++
    if ($Script:PreviewTimer) { $Script:PreviewTimer.Stop(); $Script:PreviewTimer.Start() }
}

function Start-PreviewRender {
    if ($Script:PreviewWorker.IsBusy) { $lbl_preview_status.Text='Preview update queued…'; return }
    $inputPath=$txt_input.Text.Trim(); if (-not (Test-Path -LiteralPath $inputPath)) { $lbl_preview_status.Text='Choose a valid source video'; return }
    $exe=Get-SelectedEncoder; if (-not $exe) { $lbl_preview_status.Text='No compatible rigaya encoder found'; return }
    $time=$txt_preview_time.Text.Trim(); if ($time -notmatch '^(\d+:)?\d+:\d+(\.\d+)?$') { $lbl_preview_status.Text='Use time format HH:MM:SS.mmm'; return }
    $revision=$Script:PreviewGeneration
    $rawSource=Join-Path $env:TEMP ("vppbox-source-{0}.y4m" -f [guid]::NewGuid())
    $rawProcessed=Join-Path $env:TEMP ("vppbox-vpp-{0}.y4m" -f [guid]::NewGuid())
    $logs=@((Join-Path $env:TEMP ("vppbox-preview-{0}.out" -f [guid]::NewGuid())),(Join-Path $env:TEMP ("vppbox-preview-{0}.err" -f [guid]::NewGuid())))
    $common=@('--avhw','--seek',$time,'--frames','1','-c','raw','--output-format','y4m','--output-csp','yuv420','--output-depth','8','-i',$inputPath)
    $sourceArgs=@($common)+@('-o',$rawSource)
    $processedArgs=@($common)+@(Get-FilterArguments)+@('-o',$rawProcessed)
    $Script:PreviewWorker.RunWorkerAsync(@{Revision=$revision;Exe=$exe;Source=$rawSource;Processed=$rawProcessed;SourceArgs=$sourceArgs;ProcessedArgs=$processedArgs;Logs=$logs})
    $lbl_preview_status.Text='Rendering preview with selected encoder…'; $btn_preview.IsEnabled=$false
}

function Invoke-EncoderFrame {
    param([string]$Exe,[string[]]$Arguments,[string]$LogPath)
    $p=Start-Process -FilePath $Exe -ArgumentList (($Arguments|ForEach-Object {Quote-Argument ([string]$_)}) -join ' ') -PassThru -Wait -NoNewWindow -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath+'.err')
    if($p.ExitCode -ne 0){$message=Get-Content -LiteralPath ($LogPath+'.err') -Raw -ErrorAction SilentlyContinue;throw "Encoder exited with $($p.ExitCode): $message"}
}

function Get-OutputForItem([string]$InputPath) {
    if ($Script:QueueItems.Count -eq 1) { return $txt_output.Text.Trim() }
    $extension=[IO.Path]::GetExtension($txt_output.Text);if(-not $extension){$extension='.mp4'}
    return Join-Path (Split-Path -Parent $txt_output.Text) (([IO.Path]::GetFileNameWithoutExtension($InputPath)+'_encoded'+$extension))
}
function Start-Queue {
    if ($Script:Process -and -not $Script:Process.HasExited) { return }
    $items=@();foreach($item in $lst_queue.Items){$items += [string]$item};if(-not $items.Count -and (Test-Path -LiteralPath $txt_input.Text)){$items=@($txt_input.Text.Trim())}
    if(-not $items.Count){[Windows.MessageBox]::Show('Add a valid source video.','Input required','OK','Warning')|Out-Null;return}
    if(-not $txt_output.Text.Trim()){[Windows.MessageBox]::Show('Choose an output file.','Output required','OK','Warning')|Out-Null;return}
    $exe=Get-SelectedEncoder;if(-not $exe){[Windows.MessageBox]::Show('No matching rigaya encoder found. See GPU/encoder status.','Encoder missing','OK','Error')|Out-Null;return}
    $Script:QueueItems=$items;$Script:QueueIndex=0;$Script:Encoder=$exe;$Script:ReadOut=0L;$Script:ReadErr=0L
    Set-Content -LiteralPath $Script:StdoutPath -Value '' -Encoding UTF8;Set-Content -LiteralPath $Script:StderrPath -Value '' -Encoding UTF8;$txt_log.Clear();$btn_start.IsEnabled=$false;$btn_stop.IsEnabled=$true;$lbl_status.Text='Encoding…';Start-NextEncode;$Script:Timer.Start()
}
function Start-NextEncode {
    if($Script:QueueIndex -ge $Script:QueueItems.Count){$Script:Timer.Stop();$btn_start.IsEnabled=$true;$btn_stop.IsEnabled=$false;$lbl_status.Text='Queue complete';Add-Log 'Queue complete.';$Script:Process=$null;return}
    $inputPath=$Script:QueueItems[$Script:QueueIndex];if(-not(Test-Path -LiteralPath $inputPath)){Add-Log "Skipped missing input: $inputPath";$Script:QueueIndex++;Start-NextEncode;return}
    $outputPath=Get-OutputForItem $inputPath;$args=@('--avhw','--codec',$(if($cmb_codec.SelectedIndex -eq 0){'h264'}else{'hevc'}),'--cqp',([int]$sl_quality.Value).ToString())+@(Get-FilterArguments);if($chk_audio.IsChecked){$args+='--audio-copy'};$args+=@('-i',$inputPath,'-o',$outputPath)
    Add-Log ("[{0}/{1}] {2}" -f ($Script:QueueIndex+1),$Script:QueueItems.Count,[IO.Path]::GetFileName($inputPath))
    try{$Script:Process=Start-Process -FilePath $Script:Encoder -ArgumentList (($args|ForEach-Object {Quote-Argument ([string]$_)}) -join ' ') -PassThru -NoNewWindow -RedirectStandardOutput $Script:StdoutPath -RedirectStandardError $Script:StderrPath}catch{Add-Log "Failed to start encoder: $_";$Script:QueueIndex++;Start-NextEncode}
}
function Stop-Queue {if($Script:Process -and -not $Script:Process.HasExited){try{$Script:Process.Kill()}catch{}};$Script:Timer.Stop();$Script:Process=$null;$btn_start.IsEnabled=$true;$btn_stop.IsEnabled=$false;$lbl_status.Text='Stopped';Add-Log 'Queue stopped.'}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="VPPBox · rigaya HWEnc" Width="1180" Height="850" MinWidth="930" MinHeight="690" WindowStartupLocation="CenterScreen" Background="#17191E" Foreground="#E8EAF0">
<Window.Resources>
 <Style TargetType="{x:Type Button}"><Setter Property="Foreground" Value="#F2F2F2"/><Setter Property="Background" Value="#353943"/><Setter Property="BorderBrush" Value="#505562"/><Setter Property="Padding" Value="8,5"/><Setter Property="Margin" Value="2"/></Style>
 <Style TargetType="{x:Type TextBox}"><Setter Property="Foreground" Value="#F2F2F2"/><Setter Property="Background" Value="#252830"/><Setter Property="CaretBrush" Value="White"/><Setter Property="BorderBrush" Value="#4B505B"/><Setter Property="Padding" Value="5,4"/></Style>
 <Style TargetType="{x:Type ComboBox}"><Setter Property="Foreground" Value="#F2F2F2"/><Setter Property="Background" Value="#30343D"/><Setter Property="BorderBrush" Value="#4B505B"/><Setter Property="Padding" Value="4"/></Style>
 <Style TargetType="{x:Type ComboBoxItem}"><Setter Property="Foreground" Value="#F2F2F2"/><Setter Property="Background" Value="#30343D"/><Setter Property="Padding" Value="5"/></Style>
 <Style TargetType="{x:Type CheckBox}"><Setter Property="Foreground" Value="#E8EAF0"/><Setter Property="Margin" Value="2,4"/></Style>
</Window.Resources>
<Grid Margin="12"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
 <Border Background="#202329" BorderBrush="#343842" BorderThickness="0,0,0,1" Padding="12"><DockPanel><StackPanel Orientation="Horizontal"><TextBlock Text="◈  VPPBox" FontSize="18" FontWeight="Bold" Foreground="#A99AFF"/><TextBlock Text="  /  rigaya HWEnc" VerticalAlignment="Center" Foreground="#9BA0AE"/></StackPanel><StackPanel DockPanel.Dock="Right"><TextBlock x:Name="lbl_status" Text="Ready" HorizontalAlignment="Right"/><TextBlock x:Name="lbl_gpu" Text="Checking GPU…" FontSize="9" Foreground="#A8ACB7" HorizontalAlignment="Right"/></StackPanel></DockPanel></Border>
 <Grid Grid.Row="1" Margin="0,10"><Grid.ColumnDefinitions><ColumnDefinition Width="1.7*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
  <Grid Grid.Column="0" Margin="0,0,10,0"><Grid.RowDefinitions><RowDefinition Height="1.55*"/><RowDefinition Height="0.8*"/><RowDefinition Height="120"/></Grid.RowDefinitions>
   <Border Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="10" Margin="0,0,0,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><DockPanel Margin="0,0,0,7"><TextBlock Text="BEFORE / AFTER PREVIEW" FontSize="11" FontWeight="Bold" Foreground="#B8BBC4"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><TextBlock x:Name="lbl_preview_status" Text="Choose a source and time" VerticalAlignment="Center" FontSize="10" Foreground="#A8ACB7"/><TextBox x:Name="txt_preview_time" Text="00:00:01.000" Width="105" Margin="6,0"/><Button x:Name="btn_preview" Content="Refresh"/></StackPanel></DockPanel><Border Grid.Row="1" Background="#30343C" ClipToBounds="True" CornerRadius="4"><Grid x:Name="preview_grid"><Image x:Name="img_processed" Stretch="Uniform"/><Image x:Name="img_original" Stretch="Uniform"><Image.Clip><RectangleGeometry x:Name="clip_original"/></Image.Clip></Image><Border x:Name="divider" Width="3" Background="White" HorizontalAlignment="Left" IsHitTestVisible="False"/><TextBlock Text="Source" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="9" Padding="6,3" Background="#AA000000"/><TextBlock Text="VPP processed" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="9" Padding="6,3" Background="#AA000000"/><TextBlock Text="Preview frames are rendered by the selected rigaya encoder" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#9BA0AE" IsHitTestVisible="False"/></Grid></Border><DockPanel Grid.Row="2" Margin="0,7,0,0"><TextBlock Text="Original" VerticalAlignment="Center" Foreground="#9BA0AE"/><Slider x:Name="sl_split" Minimum="0.02" Maximum="0.98" Value="0.5" Margin="8,0"/><TextBlock Text="Processed" VerticalAlignment="Center" Foreground="#9BA0AE"/></DockPanel></Grid></Border>
   <Border Grid.Row="1" Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="9" Margin="0,0,0,8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><DockPanel><TextBlock Text="VIDEO QUEUE" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_add" Content="Add videos"/><Button x:Name="btn_remove" Content="Remove"/><Button x:Name="btn_clear" Content="Clear"/></StackPanel></DockPanel><ListBox x:Name="lst_queue" Grid.Row="1" Margin="0,6,0,0" Background="#17191E" BorderThickness="0"/></Grid></Border>
   <Border Grid.Row="2" Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="8"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="PROCESSING LOG" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="0,0,0,5"/><TextBox x:Name="txt_log" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#17191E" BorderThickness="0" FontFamily="Consolas" FontSize="10"/></Grid></Border>
  </Grid>
  <Border Grid.Column="1" Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="12"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel><TextBlock Text="ENCODE &amp; VPP" FontSize="12" FontWeight="Bold" Foreground="#A99AFF" Margin="0,0,0,10"/><TextBlock Text="Input" FontSize="10" Foreground="#A8ACB7"/><DockPanel Margin="0,3,0,8"><TextBox x:Name="txt_input"/><Button x:Name="btn_input" Content="Browse…" DockPanel.Dock="Right"/></DockPanel><TextBlock Text="Output" FontSize="10" Foreground="#A8ACB7"/><DockPanel Margin="0,3,0,8"><TextBox x:Name="txt_output"/><Button x:Name="btn_output" Content="Browse…" DockPanel.Dock="Right"/></DockPanel><TextBlock Text="Detected encoder" FontSize="10" Foreground="#A8ACB7"/><ComboBox x:Name="cmb_encoder" Margin="0,3,0,8"/><TextBlock Text="Codec" FontSize="10" Foreground="#A8ACB7"/><ComboBox x:Name="cmb_codec" SelectedIndex="1" Margin="0,3,0,8"><ComboBoxItem Content="H.264 / AVC"/><ComboBoxItem Content="HEVC / H.265"/></ComboBox><TextBlock Text="CQP quality" FontSize="10" Foreground="#A8ACB7"/><DockPanel><Slider x:Name="sl_quality" Minimum="1" Maximum="51" Value="20"/><TextBlock x:Name="lbl_quality" Text="20" Width="30" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel><CheckBox x:Name="chk_audio" Content="Copy audio streams" IsChecked="True"/><Separator/><TextBlock Text="VPP FILTER DROPDOWNS" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="0,9,0,5"/>
    <Expander IsExpanded="False"><Expander.Header><DockPanel><CheckBox x:Name="chk_knn" Content="KNN denoise"/><TextBlock Text="--vpp-knn" Foreground="#A8ACB7" VerticalAlignment="Center"/></DockPanel></Expander.Header><StackPanel Margin="10,4"><DockPanel><TextBlock Text="Strength" Width="70"/><Slider x:Name="sl_strength" Minimum="0" Maximum="1" Value="0.08"/><TextBlock x:Name="lbl_strength" Text="0.08" Width="34"/></DockPanel><DockPanel><TextBlock Text="Radius" Width="70"/><Slider x:Name="sl_radius" Minimum="1" Maximum="5" Value="3" TickFrequency="1" IsSnapToTickEnabled="True"/><TextBlock x:Name="lbl_radius" Text="3" Width="34"/></DockPanel></StackPanel></Expander>
    <Expander IsExpanded="False"><Expander.Header><DockPanel><CheckBox x:Name="chk_deband" Content="Deband"/><TextBlock Text="--vpp-deband" Foreground="#A8ACB7" VerticalAlignment="Center"/></DockPanel></Expander.Header><StackPanel Margin="10,4"><DockPanel><TextBlock Text="Range" Width="70"/><Slider x:Name="sl_range" Minimum="0" Maximum="127" Value="15"/><TextBlock x:Name="lbl_range" Text="15" Width="34"/></DockPanel><DockPanel><TextBlock Text="Threshold" Width="70"/><Slider x:Name="sl_threshold" Minimum="0" Maximum="31" Value="15"/><TextBlock x:Name="lbl_threshold" Text="15" Width="34"/></DockPanel><DockPanel><TextBlock Text="Dither" Width="70"/><Slider x:Name="sl_dither" Minimum="0" Maximum="31" Value="15"/><TextBlock x:Name="lbl_dither" Text="15" Width="34"/></DockPanel></StackPanel></Expander>
    <Expander IsExpanded="False"><Expander.Header><DockPanel><CheckBox x:Name="chk_unsharp" Content="Unsharp"/><TextBlock Text="--vpp-unsharp" Foreground="#A8ACB7" VerticalAlignment="Center"/></DockPanel></Expander.Header><DockPanel Margin="10,4"><TextBlock Text="Weight" Width="70"/><Slider x:Name="sl_unsharp" Minimum="0" Maximum="10" Value="0.5"/><TextBlock x:Name="lbl_unsharp" Text="0.50" Width="40"/></DockPanel></Expander>
    <Expander IsExpanded="False"><Expander.Header><DockPanel><CheckBox x:Name="chk_resize" Content="Resize"/><TextBlock Text="--output-res" Foreground="#A8ACB7" VerticalAlignment="Center"/></DockPanel></Expander.Header><StackPanel Margin="10,4"><DockPanel><TextBlock Text="Width" Width="55"/><TextBox x:Name="txt_width" Text="1920"/></DockPanel><DockPanel Margin="0,4,0,0"><TextBlock Text="Height" Width="55"/><TextBox x:Name="txt_height" Text="1080"/></DockPanel></StackPanel></Expander><TextBlock Text="COMMAND PREVIEW" FontWeight="Bold" FontSize="10" Foreground="#A8ACB7" Margin="0,9,0,5"/><TextBox x:Name="txt_command" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" MinHeight="72" Background="#17191E" BorderThickness="0" FontFamily="Consolas" FontSize="9" Padding="7"/><Button x:Name="btn_copy" Content="Copy command" HorizontalAlignment="Left" Margin="0,7,0,0"/></StackPanel></ScrollViewer></Border>
 </Grid>
 <DockPanel Grid.Row="2" Margin="0,3,0,0"><TextBlock Text="VPPBox • rigaya HWEnc Windows" Foreground="#A8ACB7" VerticalAlignment="Center" FontSize="10"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_stop" Content="Stop" IsEnabled="False" MinWidth="80"/><Button x:Name="btn_start" Content="Go" MinWidth="105" Background="#7564D8" Foreground="White" FontWeight="Bold"/></StackPanel></DockPanel>
</Grid></Window>
'@

# WPF XamlReader cannot resolve code-behind event attributes. Find optional
# controls without failing the entire window if a XAML edit omits one.
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($null -eq $window) { throw 'Could not load VPPBox window XAML.' }
$controlNames = 'lbl_status lbl_gpu lbl_preview_status txt_preview_time txt_log txt_input txt_output cmb_encoder cmb_codec sl_quality lbl_quality chk_audio chk_knn sl_strength lbl_strength sl_radius lbl_radius chk_deband sl_range lbl_range sl_threshold lbl_threshold sl_dither lbl_dither chk_unsharp sl_unsharp lbl_unsharp chk_resize txt_width txt_height txt_command btn_input btn_output btn_add btn_remove btn_clear lst_queue btn_original btn_processed btn_preview img_original img_processed preview_grid clip_original divider sl_split btn_copy btn_stop btn_start'.Split(' ')
foreach ($name in $controlNames) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }

# Probe GPU names and map vendors to the matching rigaya executable. Resolve
# adjacent binaries before PATH; if several vendors exist, expose each choice.
$gpuNames = @(Get-VideoControllers)
$Script:EncoderChoices = @()
foreach ($gpu in $gpuNames) {
    $exe = if ($gpu -match 'NVIDIA|GeForce|Quadro|RTX|Tesla') {'NVEncC64.exe'} elseif ($gpu -match 'AMD|Radeon|FirePro') {'VCEEncC64.exe'} elseif ($gpu -match 'Intel|Arc|Iris|UHD Graphics|HD Graphics') {'QSVEncC64.exe'} else {$null}
    if ($exe -and -not ($Script:EncoderChoices | Where-Object {$_.Exe -eq $exe})) {
        $path = Resolve-EncoderExecutable $exe
        $Script:EncoderChoices += [pscustomobject]@{Gpu=$gpu;Exe=$exe;Path=$path}
    }
}
if (-not $Script:EncoderChoices.Count) {
    foreach ($exe in @('NVEncC64.exe','VCEEncC64.exe','QSVEncC64.exe')) { $path=Resolve-EncoderExecutable $exe; if($path){$Script:EncoderChoices += [pscustomobject]@{Gpu='Found on PATH';Exe=$exe;Path=$path}} }
}
foreach ($choice in $Script:EncoderChoices) { $item=New-Object Windows.Controls.ComboBoxItem; $item.Content="$($choice.Exe) — $($choice.Gpu)"; $item.Tag=$choice.Path; [void]$cmb_encoder.Items.Add($item) }
if ($cmb_encoder.Items.Count -gt 0) { $cmb_encoder.SelectedIndex=0; $lbl_gpu.Text="GPU: $($Script:EncoderChoices[0].Gpu)" } else { $lbl_gpu.Text= if($gpuNames.Count){'GPU found; matching rigaya encoder missing'}else{'No GPU detected; no encoder found'} }

$btn_input.Add_Click({Browse-Videos}); $btn_add.Add_Click({Browse-Videos}); $btn_output.Add_Click({Browse-Output})
$btn_original.Add_Click({Schedule-Preview}); $btn_processed.Add_Click({Schedule-Preview}); $btn_preview.Add_Click({Start-PreviewRender})
$btn_start.Add_Click({Start-Queue}); $btn_stop.Add_Click({Stop-Queue}); $btn_copy.Add_Click({[Windows.Clipboard]::SetText($txt_command.Text);$lbl_status.Text='Command copied.'})
$btn_remove.Add_Click({foreach($item in @($lst_queue.SelectedItems)){[void]$lst_queue.Items.Remove($item)}}); $btn_clear.Add_Click({if($btn_start.IsEnabled){$lst_queue.Items.Clear()}})
$lst_queue.Add_SelectionChanged({if($lst_queue.SelectedItem){$txt_input.Text=[string]$lst_queue.SelectedItem;Update-CommandPreview;Schedule-Preview}})
$preview_grid.Add_SizeChanged({Update-Comparison}); $sl_split.Add_ValueChanged({Update-Comparison})
$txt_input.Add_TextChanged({Update-CommandPreview;Schedule-Preview}); $txt_output.Add_TextChanged({Update-CommandPreview}); $cmb_encoder.Add_SelectionChanged({Update-CommandPreview;Schedule-Preview}); $cmb_codec.Add_SelectionChanged({Update-CommandPreview;Schedule-Preview}); $txt_preview_time.Add_TextChanged({Schedule-Preview})
foreach($control in @($chk_knn,$chk_deband,$chk_unsharp,$chk_resize,$chk_audio)){ $control.Add_Checked({Update-CommandPreview;Schedule-Preview});$control.Add_Unchecked({Update-CommandPreview;Schedule-Preview}) }
foreach($slider in @($sl_quality,$sl_strength,$sl_radius,$sl_range,$sl_threshold,$sl_dither,$sl_unsharp)){ $slider.Add_ValueChanged({Update-CommandPreview;Schedule-Preview}) }
foreach($control in @($txt_width,$txt_height)){ $control.Add_TextChanged({Update-CommandPreview}) }
$sl_quality.Add_ValueChanged({$lbl_quality.Text=[string][int]$sl_quality.Value});$sl_strength.Add_ValueChanged({$lbl_strength.Text='{0:0.00}' -f $sl_strength.Value});$sl_radius.Add_ValueChanged({$lbl_radius.Text=[string][int]$sl_radius.Value});$sl_range.Add_ValueChanged({$lbl_range.Text=[string][int]$sl_range.Value});$sl_threshold.Add_ValueChanged({$lbl_threshold.Text=[string][int]$sl_threshold.Value});$sl_dither.Add_ValueChanged({$lbl_dither.Text=[string][int]$sl_dither.Value});$sl_unsharp.Add_ValueChanged({$lbl_unsharp.Text='{0:0.00}' -f $sl_unsharp.Value})
$Script:PreviewTimer=New-Object Windows.Threading.DispatcherTimer;$Script:PreviewTimer.Interval=[TimeSpan]::FromMilliseconds(700);$Script:PreviewTimer.Add_Tick({$Script:PreviewTimer.Stop();Start-PreviewRender})
$Script:PreviewWorker=New-Object ComponentModel.BackgroundWorker
$Script:PreviewWorker.DoWork += { param($sender,$eventArgs);$d=$eventArgs.Argument;$errorText=$null;try{Invoke-EncoderFrame $d.Exe $d.SourceArgs $d.Logs[0];Invoke-EncoderFrame $d.Exe $d.ProcessedArgs $d.Logs[1];$source=Convert-Y4mToBitmap $d.Source;$processed=Convert-Y4mToBitmap $d.Processed;$eventArgs.Result=@{Revision=$d.Revision;Source=$source;Processed=$processed;Files=@($d.Source,$d.Processed)+$d.Logs}}catch{$errorText=$_.Exception.Message;$eventArgs.Result=@{Revision=$d.Revision;Error=$errorText;Files=@($d.Source,$d.Processed)+$d.Logs}} }
$Script:PreviewWorker.RunWorkerCompleted += {param($sender,$eventArgs);$result=$eventArgs.Result;if($result -and $result.Revision -eq $Script:PreviewGeneration){if($result.Error){$lbl_preview_status.Text='Preview failed';Add-Log $result.Error}else{$img_original.Source=$result.Source;$img_processed.Source=$result.Processed;$lbl_preview_status.Text='Preview rendered by '+(Get-SelectedEncoderName);Update-Comparison}};if($result){Remove-Item $result.Files -Force -ErrorAction SilentlyContinue};$btn_preview.IsEnabled=$true;if($Script:PreviewGeneration -ne $Script:PreviewWorkerRevision){$Script:PreviewTimer.Stop();$Script:PreviewTimer.Start()} }
$Script:Timer=New-Object Windows.Threading.DispatcherTimer;$Script:Timer.Interval=[TimeSpan]::FromMilliseconds(400);$Script:Timer.Add_Tick({Tail-LogFile $Script:StdoutPath ([ref]$Script:ReadOut);Tail-LogFile $Script:StderrPath ([ref]$Script:ReadErr);if($Script:Process -and $Script:Process.HasExited){if($Script:Process.ExitCode -eq 0){Add-Log 'Encode finished.'}else{Add-Log "Encoder exited with code $($Script:Process.ExitCode)."};$Script:Process=$null;$Script:QueueIndex++;Start-NextEncode}})
$window.Add_Closing({if($Script:Timer){$Script:Timer.Stop()};if($Script:PreviewTimer){$Script:PreviewTimer.Stop()};if($Script:Process -and -not $Script:Process.HasExited){try{$Script:Process.Kill()}catch{}};Remove-Item $Script:StdoutPath,$Script:StderrPath -Force -ErrorAction SilentlyContinue})
$lbl_quality.Text=[string][int]$sl_quality.Value;$lbl_strength.Text='{0:0.00}' -f $sl_strength.Value;$lbl_radius.Text=[string][int]$sl_radius.Value;$lbl_range.Text=[string][int]$sl_range.Value;$lbl_threshold.Text=[string][int]$sl_threshold.Value;$lbl_dither.Text=[string][int]$sl_dither.Value;$lbl_unsharp.Text='{0:0.00}' -f $sl_unsharp.Value
Update-CommandPreview
$null=$window.ShowDialog()
