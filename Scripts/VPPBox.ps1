# VPPBox — lightweight Windows PowerShell GUI for rigaya NVEncC.
# Windows PowerShell 5.1+ with WPF. The comparison preview uses user-loaded stills.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Process = $null
$Script:Timer = $null
$Script:StdoutPath = Join-Path $env:TEMP ("vppbox-{0}.out" -f [guid]::NewGuid())
$Script:StderrPath = Join-Path $env:TEMP ("vppbox-{0}.err" -f [guid]::NewGuid())
$Script:ReadOut = 0L
$Script:ReadErr = 0L

function Resolve-NVEncC {
    $local = Join-Path $Script:Root 'NVEncC64.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $command = Get-Command 'NVEncC64.exe' -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-EncoderArguments {
    param([string]$InputPath, [string]$OutputPath)
    $args = @('--avhw', '--codec', $(if ($cmb_codec.SelectedIndex -eq 0) { 'h264' } else { 'hevc' }), '--cqp', ([int]$sl_quality.Value).ToString())
    if ($chk_knn.IsChecked) { $args += @('--vpp-knn', ('radius={0},strength={1:0.00}' -f [int]$sl_radius.Value, [double]$sl_strength.Value)) }
    if ($chk_deband.IsChecked) { $args += @('--vpp-deband', ('range={0},thre={1},dither={2}' -f [int]$sl_range.Value, [int]$sl_threshold.Value, [int]$sl_dither.Value)) }
    if ($chk_unsharp.IsChecked) { $args += @('--vpp-unsharp', ('weight={0:0.00}' -f [double]$sl_unsharp.Value)) }
    if ($chk_resize.IsChecked -and [int]$txt_width.Text -gt 0 -and [int]$txt_height.Text -gt 0) { $args += @('--output-res', ('{0}x{1}' -f [int]$txt_width.Text, [int]$txt_height.Text)) }
    if ($chk_audio.IsChecked) { $args += '--audio-copy' }
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
    $inputPath = if ($txt_input.Text.Trim()) { $txt_input.Text.Trim() } else { 'INPUT' }
    $outputPath = if ($txt_output.Text.Trim()) { $txt_output.Text.Trim() } else { 'OUTPUT' }
    $exe = Resolve-NVEncC
    if (-not $exe) { $exe = 'NVEncC64.exe' }
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
    $dialog.Title = 'Add videos to queue'
    $dialog.Multiselect = $true
    $dialog.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.webm|All files|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($path in $dialog.FileNames) {
            if (-not ($lst_queue.Items -contains $path)) { [void]$lst_queue.Items.Add($path) }
        }
        if (-not $txt_input.Text -and $lst_queue.Items.Count -gt 0) {
            $txt_input.Text = [string]$lst_queue.Items[0]
            if (-not $txt_output.Text) {
                $name = [IO.Path]::GetFileNameWithoutExtension($txt_input.Text)
                $txt_output.Text = Join-Path (Split-Path -Parent $txt_input.Text) ($name + '_encoded.mp4')
            }
        }
        Update-CommandPreview
    }
}

function Browse-Output {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Choose output video'
    $dialog.Filter = 'MP4 video|*.mp4|Matroska video|*.mkv|All files|*.*'
    $dialog.FileName = if ($txt_output.Text) { [IO.Path]::GetFileName($txt_output.Text) } else { 'output.mp4' }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txt_output.Text = $dialog.FileName
        Update-CommandPreview
    }
}

function Load-Still {
    param([bool]$IsOriginal)
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = if ($IsOriginal) { 'Load original still' } else { 'Load processed still' }
    $dialog.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.bmp;*.webp|All files|*.*'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = [Uri]$dialog.FileName
        $bitmap.EndInit()
        $bitmap.Freeze()
        if ($IsOriginal) { $img_original.Source = $bitmap } else { $img_processed.Source = $bitmap }
        Update-Comparison
    } catch {
        [System.Windows.MessageBox]::Show("Could not load image: $_", 'Preview', 'OK', 'Warning') | Out-Null
    }
}

function Update-Comparison {
    if (-not $preview_grid -or $preview_grid.ActualWidth -le 0) { return }
    $x = $preview_grid.ActualWidth * [double]$sl_split.Value
    $clip_original.Rect = New-Object System.Windows.Rect(0, 0, $x, $preview_grid.ActualHeight)
    $divider.Margin = New-Object System.Windows.Thickness(($x - 1.5), 0, 0, 0)
}

function Get-OutputForItem {
    param([string]$InputPath)
    if ($Script:QueueItems.Count -eq 1) { return $txt_output.Text.Trim() }
    $extension = [IO.Path]::GetExtension($txt_output.Text)
    if (-not $extension) { $extension = '.mp4' }
    $name = [IO.Path]::GetFileNameWithoutExtension($InputPath) + '_encoded' + $extension
    return Join-Path (Split-Path -Parent $txt_output.Text) $name
}

function Start-Queue {
    if ($Script:Process -and -not $Script:Process.HasExited) { return }
    $items = @()
    foreach ($item in $lst_queue.Items) { $items += [string]$item }
    if ($items.Count -eq 0 -and (Test-Path -LiteralPath $txt_input.Text)) { $items = @($txt_input.Text.Trim()) }
    if ($items.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Add a valid source video.', 'Input required', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $txt_output.Text.Trim()) {
        [System.Windows.MessageBox]::Show('Choose an output file.', 'Output required', 'OK', 'Warning') | Out-Null
        return
    }
    $exe = Resolve-NVEncC
    if (-not $exe) {
        [System.Windows.MessageBox]::Show('NVEncC64.exe was not found. Put it beside this script or add it to PATH.', 'NVEncC missing', 'OK', 'Error') | Out-Null
        return
    }

    $Script:QueueItems = $items
    $Script:QueueIndex = 0
    $Script:Encoder = $exe
    $Script:ReadOut = 0L
    $Script:ReadErr = 0L
    Set-Content -LiteralPath $Script:StdoutPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $Script:StderrPath -Value '' -Encoding UTF8
    $txt_log.Clear()
    $btn_start.IsEnabled = $false
    $btn_stop.IsEnabled = $true
    $lbl_status.Text = 'Encoding…'
    Start-NextEncode
    $Script:Timer.Start()
}

function Start-NextEncode {
    if ($Script:QueueIndex -ge $Script:QueueItems.Count) {
        $Script:Timer.Stop()
        $btn_start.IsEnabled = $true
        $btn_stop.IsEnabled = $false
        $lbl_status.Text = 'Queue complete'
        Add-Log 'Queue complete.'
        $Script:Process = $null
        return
    }

    $inputPath = $Script:QueueItems[$Script:QueueIndex]
    if (-not (Test-Path -LiteralPath $inputPath)) {
        Add-Log "Skipped missing input: $inputPath"
        $Script:QueueIndex++
        Start-NextEncode
        return
    }
    $outputPath = Get-OutputForItem $inputPath
    $args = Get-EncoderArguments $inputPath $outputPath
    Add-Log ("[{0}/{1}] {2}" -f ($Script:QueueIndex + 1), $Script:QueueItems.Count, [IO.Path]::GetFileName($inputPath))

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Script:Encoder
    $startInfo.Arguments = (($args | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    try {
        $Script:Process = Start-Process -FilePath $startInfo.FileName -ArgumentList $startInfo.Arguments -PassThru -NoNewWindow -RedirectStandardOutput $Script:StdoutPath -RedirectStandardError $Script:StderrPath
    } catch {
        Add-Log "Failed to start NVEncC: $_"
        $Script:QueueIndex++
        Start-NextEncode
    }
}

function Stop-Queue {
    if ($Script:Process -and -not $Script:Process.HasExited) {
        try { $Script:Process.Kill() } catch { }
    }
    $Script:Timer.Stop()
    $Script:Process = $null
    $btn_start.IsEnabled = $true
    $btn_stop.IsEnabled = $false
    $lbl_status.Text = 'Stopped'
    Add-Log 'Queue stopped.'
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VPPBox · NVEnc" Width="1180" Height="850" MinWidth="930" MinHeight="690"
        WindowStartupLocation="CenterScreen" Background="#17191E" Foreground="#E8EAF0">
<Grid Margin="12">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border Background="#202329" BorderBrush="#343842" BorderThickness="0,0,0,1" Padding="12">
    <DockPanel><StackPanel Orientation="Horizontal"><TextBlock Text="◈  VPPBox" FontSize="18" FontWeight="Bold" Foreground="#A99AFF"/><TextBlock Text="  /  NVEnc" VerticalAlignment="Center" Foreground="#9BA0AE"/></StackPanel><TextBlock x:Name="lbl_status" DockPanel.Dock="Right" Text="Ready" VerticalAlignment="Center"/></DockPanel>
  </Border>
  <Grid Grid.Row="1" Margin="0,10">
    <Grid.ColumnDefinitions><ColumnDefinition Width="1.7*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
    <Grid Grid.Column="0" Margin="0,0,10,0">
      <Grid.RowDefinitions><RowDefinition Height="1.55*"/><RowDefinition Height="0.8*"/><RowDefinition Height="120"/></Grid.RowDefinitions>
      <Border Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="10" Margin="0,0,0,8">
        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,7"><TextBlock Text="BEFORE / AFTER PREVIEW" FontSize="11" FontWeight="Bold" Foreground="#B8BBC4"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_original" Content="Original still" Margin="0,0,5,0" Padding="8,4"/><Button x:Name="btn_processed" Content="Processed still" Padding="8,4"/></StackPanel></DockPanel>
          <Border Grid.Row="1" Background="#30343C" ClipToBounds="True" CornerRadius="4">
            <Grid x:Name="preview_grid">
              <Image x:Name="img_processed" Stretch="Uniform"/>
              <Image x:Name="img_original" Stretch="Uniform"><Image.Clip><RectangleGeometry x:Name="clip_original"/></Image.Clip></Image>
              <Border x:Name="divider" Width="3" Background="White" HorizontalAlignment="Left" IsHitTestVisible="False"/>
              <TextBlock Text="Original" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="9" Padding="6,3" Background="#AA000000"/>
              <TextBlock Text="Processed" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="9" Padding="6,3" Background="#AA000000"/>
              <TextBlock Text="Load stills to compare" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#9BA0AE" IsHitTestVisible="False"/>
            </Grid>
          </Border>
          <DockPanel Grid.Row="2" Margin="0,7,0,0"><TextBlock Text="Original" VerticalAlignment="Center" Foreground="#9BA0AE"/><Slider x:Name="sl_split" Minimum="0.02" Maximum="0.98" Value="0.5" Margin="8,0"/><TextBlock Text="Processed" VerticalAlignment="Center" Foreground="#9BA0AE"/></DockPanel>
        </Grid>
      </Border>
      <Border Grid.Row="1" Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="9" Margin="0,0,0,8">
        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><DockPanel><TextBlock Text="VIDEO QUEUE" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_add" Content="Add videos" Padding="7,3"/><Button x:Name="btn_remove" Content="Remove" Padding="7,3" Margin="4,0,0,0"/><Button x:Name="btn_clear" Content="Clear" Padding="7,3" Margin="4,0,0,0"/></StackPanel></DockPanel><ListBox x:Name="lst_queue" Grid.Row="1" Margin="0,6,0,0" Background="#17191E" BorderThickness="0"/></Grid>
      </Border>
      <Border Grid.Row="2" Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="8">
        <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="PROCESSING LOG" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="0,0,0,5"/><TextBox x:Name="txt_log" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#17191E" BorderThickness="0" FontFamily="Consolas" FontSize="10"/></Grid>
      </Border>
    </Grid>
    <Border Grid.Column="1" Background="#202329" BorderBrush="#343842" BorderThickness="1" CornerRadius="6" Padding="12">
      <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
        <TextBlock Text="ENCODE &amp; VPP" FontSize="12" FontWeight="Bold" Foreground="#A99AFF" Margin="0,0,0,10"/>
        <TextBlock Text="Input" FontSize="10" Foreground="#A8ACB7"/><DockPanel Margin="0,3,0,8"><TextBox x:Name="txt_input"/><Button x:Name="btn_input" Content="Browse…" DockPanel.Dock="Right" Margin="5,0,0,0" Padding="7,3"/></DockPanel>
        <TextBlock Text="Output" FontSize="10" Foreground="#A8ACB7"/><DockPanel Margin="0,3,0,8"><TextBox x:Name="txt_output"/><Button x:Name="btn_output" Content="Browse…" DockPanel.Dock="Right" Margin="5,0,0,0" Padding="7,3"/></DockPanel>
        <TextBlock Text="NVEncC executable" FontSize="10" Foreground="#A8ACB7"/><TextBox x:Name="txt_encoder" Text="NVEncC64.exe" Margin="0,3,0,8"/>
        <TextBlock Text="Codec" FontSize="10" Foreground="#A8ACB7"/><ComboBox x:Name="cmb_codec" SelectedIndex="1" Margin="0,3,0,8"><ComboBoxItem Content="H.264 / AVC"/><ComboBoxItem Content="HEVC / H.265"/></ComboBox>
        <TextBlock Text="CQP quality" FontSize="10" Foreground="#A8ACB7"/><DockPanel><Slider x:Name="sl_quality" Minimum="1" Maximum="51" Value="20"/><TextBlock x:Name="lbl_quality" Text="20" Width="30" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel><CheckBox x:Name="chk_audio" Content="Copy audio streams" IsChecked="True" Margin="0,3,0,8"/>
        <Separator/><TextBlock Text="VPP FILTER PIPELINE" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="0,9,0,5"/>
        <CheckBox x:Name="chk_knn" Content="KNN denoise (--vpp-knn)" IsChecked="True"/><TextBlock Text="Strength" FontSize="9" Foreground="#9BA0AE"/><DockPanel><Slider x:Name="sl_strength" Minimum="0" Maximum="1" Value="0.08"/><TextBlock x:Name="lbl_strength" Text="0.08" Width="32" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel><TextBlock Text="Radius" FontSize="9" Foreground="#9BA0AE"/><DockPanel Margin="0,0,0,6"><Slider x:Name="sl_radius" Minimum="1" Maximum="5" Value="3" TickFrequency="1" IsSnapToTickEnabled="True"/><TextBlock x:Name="lbl_radius" Text="3" Width="32" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <CheckBox x:Name="chk_deband" Content="Deband (--vpp-deband)"/><TextBlock Text="Range / threshold / dither" FontSize="9" Foreground="#9BA0AE"/><DockPanel Margin="0,0,0,6"><Slider x:Name="sl_range" Minimum="0" Maximum="127" Value="15"/><TextBlock x:Name="lbl_range" Text="15" Width="28" VerticalAlignment="Center" TextAlignment="Right"/><Slider x:Name="sl_threshold" Minimum="0" Maximum="31" Value="15"/><TextBlock x:Name="lbl_threshold" Text="15" Width="28" VerticalAlignment="Center" TextAlignment="Right"/><Slider x:Name="sl_dither" Minimum="0" Maximum="31" Value="15"/><TextBlock x:Name="lbl_dither" Text="15" Width="28" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <CheckBox x:Name="chk_unsharp" Content="Unsharp (--vpp-unsharp)"/><DockPanel Margin="0,0,0,6"><Slider x:Name="sl_unsharp" Minimum="0" Maximum="10" Value="0.5"/><TextBlock x:Name="lbl_unsharp" Text="0.50" Width="35" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <CheckBox x:Name="chk_resize" Content="Resize (--output-res)"/><DockPanel Margin="0,0,0,8"><TextBox x:Name="txt_width" Text="1920" ToolTip="Output width"/><TextBlock Text=" × " VerticalAlignment="Center"/><TextBox x:Name="txt_height" Text="1080" ToolTip="Output height"/></DockPanel>
        <TextBlock Text="COMMAND PREVIEW" FontWeight="Bold" FontSize="10" Foreground="#A8ACB7" Margin="0,3,0,5"/><TextBox x:Name="txt_command" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" MinHeight="75" Background="#17191E" BorderThickness="0" FontFamily="Consolas" FontSize="9" Padding="7"/><Button x:Name="btn_copy" Content="Copy command" HorizontalAlignment="Left" Margin="0,7,0,0" Padding="9,4"/>
      </StackPanel></ScrollViewer>
    </Border>
  </Grid>
  <DockPanel Grid.Row="2" Margin="0,3,0,0"><TextBlock Text="NVEncC Windows • VapourBox-inspired workflow" Foreground="#777E8A" VerticalAlignment="Center" FontSize="10"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_stop" Content="Stop" IsEnabled="False" MinWidth="80" Margin="0,0,7,0" Padding="9,6"/><Button x:Name="btn_start" Content="Go" MinWidth="105" Padding="12,6" Background="#7564D8" Foreground="White" FontWeight="Bold"/></StackPanel></DockPanel>
</Grid>
</Window>
'@

# Important: XamlReader.Load cannot resolve event-handler attributes such as
# SizeChanged="PreviewSizeChanged" without a compiled WPF code-behind class.
# Keep all event hookups in PowerShell after XamlReader.Load succeeds.
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($null -eq $window) { throw 'Failed to load VPPBox WPF window from XAML.' }

$controlNames = 'lbl_status txt_log txt_input txt_output txt_encoder cmb_codec sl_quality lbl_quality chk_audio chk_knn sl_strength lbl_strength sl_radius lbl_radius chk_deband sl_range lbl_range sl_threshold lbl_threshold sl_dither lbl_dither chk_unsharp sl_unsharp lbl_unsharp chk_resize txt_width txt_height txt_command btn_input btn_output btn_add btn_remove btn_clear lst_queue btn_original btn_processed img_original img_processed preview_grid clip_original divider sl_split btn_copy btn_stop btn_start'.Split(' ')
foreach ($name in $controlNames) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "Required WPF control '$name' was not found in the XAML." }
    Set-Variable -Name $name -Value $control -Scope Script
}

$btn_input.Add_Click({ Browse-Videos })
$btn_add.Add_Click({ Browse-Videos })
$btn_output.Add_Click({ Browse-Output })
$btn_original.Add_Click({ Load-Still $true })
$btn_processed.Add_Click({ Load-Still $false })
$btn_start.Add_Click({ Start-Queue })
$btn_stop.Add_Click({ Stop-Queue })
$btn_copy.Add_Click({ [Windows.Clipboard]::SetText($txt_command.Text); $lbl_status.Text = 'Command copied.' })
$btn_remove.Add_Click({ foreach ($item in @($lst_queue.SelectedItems)) { [void]$lst_queue.Items.Remove($item) } })
$btn_clear.Add_Click({ if ($btn_start.IsEnabled) { $lst_queue.Items.Clear() } })
$lst_queue.Add_SelectionChanged({
    if ($lst_queue.SelectedItem) {
        $txt_input.Text = [string]$lst_queue.SelectedItem
        Update-CommandPreview
    }
})

# Hook the preview-size event in PowerShell, not in XAML.
$preview_grid.Add_SizeChanged({ Update-Comparison })
$sl_split.Add_ValueChanged({ Update-Comparison })
foreach ($control in @($txt_input, $txt_output, $txt_encoder, $txt_width, $txt_height)) {
    $control.Add_TextChanged({ Update-CommandPreview })
}
$cmb_codec.Add_SelectionChanged({ Update-CommandPreview })
foreach ($control in @($chk_knn, $chk_deband, $chk_unsharp, $chk_resize, $chk_audio)) {
    $control.Add_Checked({ Update-CommandPreview })
    $control.Add_Unchecked({ Update-CommandPreview })
}
foreach ($slider in @($sl_quality, $sl_strength, $sl_radius, $sl_range, $sl_threshold, $sl_dither, $sl_unsharp)) {
    $slider.Add_ValueChanged({ Update-CommandPreview })
}
$sl_quality.Add_ValueChanged({ $lbl_quality.Text = [string][int]$sl_quality.Value })
$sl_strength.Add_ValueChanged({ $lbl_strength.Text = '{0:0.00}' -f $sl_strength.Value })
$sl_radius.Add_ValueChanged({ $lbl_radius.Text = [string][int]$sl_radius.Value })
$sl_range.Add_ValueChanged({ $lbl_range.Text = [string][int]$sl_range.Value })
$sl_threshold.Add_ValueChanged({ $lbl_threshold.Text = [string][int]$sl_threshold.Value })
$sl_dither.Add_ValueChanged({ $lbl_dither.Text = [string][int]$sl_dither.Value })
$sl_unsharp.Add_ValueChanged({ $lbl_unsharp.Text = '{0:0.00}' -f $sl_unsharp.Value })

$Script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:Timer.Interval = [TimeSpan]::FromMilliseconds(400)
$Script:Timer.Add_Tick({
    Tail-LogFile $Script:StdoutPath ([ref]$Script:ReadOut)
    Tail-LogFile $Script:StderrPath ([ref]$Script:ReadErr)
    if ($Script:Process -and $Script:Process.HasExited) {
        if ($Script:Process.ExitCode -eq 0) { Add-Log 'Encode finished.' }
        else { Add-Log "NVEncC exited with code $($Script:Process.ExitCode)." }
        $Script:Process = $null
        $Script:QueueIndex++
        Start-NextEncode
    }
})
$window.Add_Closing({
    if ($Script:Timer) { $Script:Timer.Stop() }
    if ($Script:Process -and -not $Script:Process.HasExited) { try { $Script:Process.Kill() } catch { } }
    Remove-Item $Script:StdoutPath, $Script:StderrPath -Force -ErrorAction SilentlyContinue
})

Update-CommandPreview
$lbl_quality.Text = [string][int]$sl_quality.Value
$lbl_strength.Text = '{0:0.00}' -f $sl_strength.Value
$lbl_radius.Text = [string][int]$sl_radius.Value
$lbl_range.Text = [string][int]$sl_range.Value
$lbl_threshold.Text = [string][int]$sl_threshold.Value
$lbl_dither.Text = [string][int]$sl_dither.Value
$lbl_unsharp.Text = '{0:0.00}' -f $sl_unsharp.Value
$null = $window.ShowDialog()
