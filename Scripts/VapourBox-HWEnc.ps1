# VapourBox HWEnc — lightweight PowerShell edition
# Windows PowerShell 5.1+; requires WPF and rigaya NVEncC for Windows.
# Preview is a user-loaded still-image comparison; encoding is performed by NVEncC.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$Script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:Process = $null
$Script:PollTimer = $null
$Script:StdoutPath = Join-Path $env:TEMP ("vapourbox-hwenc-{0}.out" -f [guid]::NewGuid())
$Script:StderrPath = Join-Path $env:TEMP ("vapourbox-hwenc-{0}.err" -f [guid]::NewGuid())
$Script:ReadOut = 0L
$Script:ReadErr = 0L
$Script:Closing = $false

function Resolve-NVEncC {
    $local = Join-Path $Script:Root 'NVEncC64.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $found = Get-Command 'NVEncC64.exe' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    return 'NVEncC64.exe'
}

function Get-EncoderArguments {
    $result = @('--avhw', '--codec', $(if ($cmb_codec.SelectedIndex -eq 0) { 'h264' } else { 'hevc' }),
        '--cqp', [string][int]$sl_quality.Value, '-i', $txt_input.Text.Trim(), '-o', $txt_output.Text.Trim())
    if ($chk_knn.IsChecked) {
        $result += @('--vpp-knn', ('radius={0},strength={1:0.00}' -f [int]$sl_knn_radius.Value, [double]$sl_knn_strength.Value))
    }
    if ($chk_deband.IsChecked) {
        $result += @('--vpp-deband', ('range={0},thre={1},dither={2}' -f [int]$sl_deband_range.Value, [int]$sl_deband_thre.Value, [int]$sl_deband_dither.Value))
    }
    if ($chk_unsharp.IsChecked) {
        $result += @('--vpp-unsharp', ('weight={0:0.00}' -f [double]$sl_unsharp.Value))
    }
    if ($chk_resize.IsChecked -and [int]$txt_width.Text -gt 0 -and [int]$txt_height.Text -gt 0) {
        $result += @('--output-res', ('{0}x{1}' -f [int]$txt_width.Text, [int]$txt_height.Text))
    }
    return ,$result
}

function Quote-Argument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    # Windows command-line quoting: escape backslashes before quotes and the closing quote.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Update-CommandPreview {
    if (-not $txt_command) { return }
    $exe = Resolve-NVEncC
    $parts = @($exe) + @(Get-EncoderArguments)
    $txt_command.Text = (($parts | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
}

function Add-Log([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $txt_log.AppendText($Text.TrimEnd() + "`r`n")
    $txt_log.ScrollToEnd()
}

function Read-NewLines([string]$Path, [ref]$Offset) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0 }
            [void]$stream.Seek($Offset.Value, [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($stream)
            $text = $reader.ReadToEnd()
            $Offset.Value = $stream.Position
            if ($text) { return $text -split "`r?`n" | Where-Object { $_ } }
        } finally { $stream.Dispose() }
    } catch { }
}

function Browse-Input {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose a video'
    $dialog.Filter = 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.webm|All files|*.*'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txt_input.Text = $dialog.FileName
        if (-not $txt_output.Text) {
            $txt_output.Text = Join-Path (Split-Path -Parent $dialog.FileName) (([IO.Path]::GetFileNameWithoutExtension($dialog.FileName)) + '_encoded.mp4')
        }
        Update-CommandPreview
    }
}

function Browse-Output {
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Choose encoded video output'
    $dialog.Filter = 'MP4 video|*.mp4|Matroska video|*.mkv|All files|*.*'
    $dialog.FileName = if ($txt_output.Text) { [IO.Path]::GetFileName($txt_output.Text) } else { 'output.mp4' }
    if ($txt_output.Text -and (Test-Path (Split-Path -Parent $txt_output.Text))) { $dialog.InitialDirectory = Split-Path -Parent $txt_output.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txt_output.Text = $dialog.FileName; Update-CommandPreview }
}

function Load-Still([bool]$Original) {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = if ($Original) { 'Load original still' } else { 'Load processed still' }
    $dialog.Filter = 'Image files|*.png;*.jpg;*.jpeg;*.bmp;*.webp|All files|*.*'
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit(); $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = [Uri]$dialog.FileName; $bitmap.EndInit(); $bitmap.Freeze()
        if ($Original) { $img_original.Source = $bitmap } else { $img_processed.Source = $bitmap }
        Update-Comparison
    } catch { [System.Windows.MessageBox]::Show("Could not load image: $_", 'Preview', 'OK', 'Warning') | Out-Null }
}

function Update-Comparison {
    if (-not $preview_grid.ActualWidth) { return }
    $split = [double]$sl_split.Value
    $clip_original.Rect = New-Object System.Windows.Rect(0, 0, ($preview_grid.ActualWidth * $split), $preview_grid.ActualHeight)
    $divider.Margin = New-Object System.Windows.Thickness(($preview_grid.ActualWidth * $split - 1.5), 0, 0, 0)
    $divider.HorizontalAlignment = 'Left'
}

function Start-Encoding {
    if ($Script:Process -and -not $Script:Process.HasExited) { return }
    if (-not (Test-Path -LiteralPath $txt_input.Text)) {
        [System.Windows.MessageBox]::Show('Select a valid input video first.', 'Missing input', 'OK', 'Warning') | Out-Null; return
    }
    if ([string]::IsNullOrWhiteSpace($txt_output.Text)) {
        [System.Windows.MessageBox]::Show('Choose an output file.', 'Missing output', 'OK', 'Warning') | Out-Null; return
    }
    $exe = Resolve-NVEncC
    if ($exe -eq 'NVEncC64.exe' -and -not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        [System.Windows.MessageBox]::Show('NVEncC64.exe was not found. Put it beside this script or add it to PATH.', 'Missing NVEncC', 'OK', 'Error') | Out-Null; return
    }
    $encoderArgs = @(Get-EncoderArguments)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $exe
    $start.Arguments = (($encoderArgs | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # Redirect through temp files so WPF remains responsive without a job/runspace.
    $start.RedirectStandardOutput = $false
    $start.RedirectStandardError = $false
    $Script:ReadOut = 0L; $Script:ReadErr = 0L
    Set-Content -LiteralPath $Script:StdoutPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $Script:StderrPath -Value '' -Encoding UTF8
    # Start-Process owns output redirection while a DispatcherTimer tails the files.
    $Script:Process = Start-Process -FilePath $exe -ArgumentList $start.Arguments -PassThru -NoNewWindow -RedirectStandardOutput $Script:StdoutPath -RedirectStandardError $Script:StderrPath
    $btn_start.IsEnabled = $false; $btn_stop.IsEnabled = $true
    $lbl_status.Text = 'Encoding…'
    $txt_log.Clear(); Add-Log "NVEncC started:`r`n$txt_command.Text"
    $Script:PollTimer.Start()
}

function Stop-Encoding {
    if ($Script:Process -and -not $Script:Process.HasExited) {
        try { $Script:Process.Kill() } catch { }
        $lbl_status.Text = 'Stopped'
        Add-Log 'Stop requested.'
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VapourBox · HWEnc" Width="1180" Height="820" MinWidth="900" MinHeight="650"
        WindowStartupLocation="CenterScreen" Background="#111318" Foreground="#E8EAF0">
  <Grid Margin="12">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#1A1D24" CornerRadius="8" Padding="14" Margin="0,0,0,10">
      <DockPanel><StackPanel Orientation="Horizontal"><TextBlock Text="◈  VAPOURBOX" FontSize="17" FontWeight="Bold" Foreground="#A99AFF"/><TextBlock Text="  /  NVENC" FontSize="14" VerticalAlignment="Center" Foreground="#9BA0AE"/></StackPanel><TextBlock x:Name="lbl_status" DockPanel.Dock="Right" Text="Ready" VerticalAlignment="Center" Foreground="#B7BBC6"/></DockPanel>
    </Border>
    <Grid Grid.Row="1"><Grid.ColumnDefinitions><ColumnDefinition Width="1.7*"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>
      <Grid Grid.Column="0" Margin="0,0,10,0"><Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="155"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#1A1D24" CornerRadius="8" Padding="12" Margin="0,0,0,10">
          <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,9"><TextBlock Text="COMPARATIVE PREVIEW" FontWeight="Bold" FontSize="11" Foreground="#A8ACB7"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_original" Content="Load original" Margin="0,0,6,0" Padding="8,4"/><Button x:Name="btn_processed" Content="Load processed" Padding="8,4"/></StackPanel></DockPanel>
            <Border Grid.Row="1" Background="#252A33" CornerRadius="6" ClipToBounds="True"><Grid x:Name="preview_grid" SizeChanged="PreviewSizeChanged">
              <Image x:Name="img_processed" Stretch="Uniform"/><Image x:Name="img_original" Stretch="Uniform"><Image.Clip><RectangleGeometry x:Name="clip_original" Rect="0,0,0,0"/></Image.Clip></Image>
              <Border x:Name="divider" Width="3" Background="White" HorizontalAlignment="Left" IsHitTestVisible="False"/>
              <TextBlock Text="Original" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="10" Padding="7,4" Background="#AA000000"/>
              <TextBlock Text="Processed" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="10" Padding="7,4" Background="#AA000000"/>
              <TextBlock Text="Load original and processed stills to compare" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#7F8795" IsHitTestVisible="False"/>
            </Grid></Border>
            <DockPanel Grid.Row="2" Margin="0,8,0,0"><TextBlock Text="Original" Foreground="#8C919D" VerticalAlignment="Center"/><Slider x:Name="sl_split" Minimum="0.02" Maximum="0.98" Value="0.5" Margin="8,0"/><TextBlock Text="Processed" Foreground="#8C919D" VerticalAlignment="Center"/></DockPanel>
          </Grid>
        </Border>
        <Border Grid.Row="1" Background="#1A1D24" CornerRadius="8" Padding="10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="NVEncC LOG" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="2,0,0,6"/><TextBox x:Name="txt_log" Grid.Row="1" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#111318" BorderThickness="0" FontFamily="Consolas" FontSize="11"/></Grid></Border>
      </Grid>
      <Border Grid.Column="1" Background="#1A1D24" CornerRadius="8" Padding="12"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
        <TextBlock Text="ENCODE &amp; VPP" FontSize="12" FontWeight="Bold" Foreground="#A99AFF" Margin="0,0,0,10"/>
        <TextBlock Text="Input video" Foreground="#A8ACB7" FontSize="11"/><DockPanel Margin="0,4,0,9"><TextBox x:Name="txt_input"/><Button x:Name="btn_input" Content="Browse…" DockPanel.Dock="Right" Margin="6,0,0,0" Padding="8,4"/></DockPanel>
        <TextBlock Text="Output file" Foreground="#A8ACB7" FontSize="11"/><DockPanel Margin="0,4,0,10"><TextBox x:Name="txt_output"/><Button x:Name="btn_output" Content="Browse…" DockPanel.Dock="Right" Margin="6,0,0,0" Padding="8,4"/></DockPanel>
        <TextBlock Text="Codec" Foreground="#A8ACB7" FontSize="11"/><ComboBox x:Name="cmb_codec" SelectedIndex="1" Margin="0,4,0,10"><ComboBoxItem Content="H.264 / AVC"/><ComboBoxItem Content="HEVC / H.265"/></ComboBox>
        <TextBlock Text="CQP quality" Foreground="#A8ACB7" FontSize="11"/><DockPanel Margin="0,2,0,10"><Slider x:Name="sl_quality" Minimum="1" Maximum="51" Value="20"/><TextBlock x:Name="lbl_quality" Text="20" Width="32" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <Separator Margin="0,4,0,10"/><TextBlock Text="VIDEO PROCESSING FILTERS" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="0,0,0,7"/>
        <CheckBox x:Name="chk_knn" Content="KNN denoise (--vpp-knn)" IsChecked="True" Margin="0,4"/><TextBlock Text="Strength" Foreground="#8C919D" FontSize="10"/><DockPanel><Slider x:Name="sl_knn_strength" Minimum="0" Maximum="1" Value="0.08"/><TextBlock x:Name="lbl_knn_strength" Text="0.08" Width="36" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel><TextBlock Text="Radius" Foreground="#8C919D" FontSize="10"/><DockPanel Margin="0,0,0,7"><Slider x:Name="sl_knn_radius" Minimum="1" Maximum="5" Value="3" TickFrequency="1" IsSnapToTickEnabled="True"/><TextBlock x:Name="lbl_knn_radius" Text="3" Width="36" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <CheckBox x:Name="chk_deband" Content="Deband (--vpp-deband)" Margin="0,4"/><TextBlock Text="Range / threshold / dither" Foreground="#8C919D" FontSize="10"/><DockPanel Margin="0,0,0,7"><Slider x:Name="sl_deband_range" Minimum="0" Maximum="127" Value="15"/><TextBlock x:Name="lbl_deband_range" Text="15" Width="34" VerticalAlignment="Center" TextAlignment="Right"/><Slider x:Name="sl_deband_thre" Minimum="0" Maximum="31" Value="15"/><TextBlock x:Name="lbl_deband_thre" Text="15" Width="30" VerticalAlignment="Center" TextAlignment="Right"/><Slider x:Name="sl_deband_dither" Minimum="0" Maximum="31" Value="15"/><TextBlock x:Name="lbl_deband_dither" Text="15" Width="30" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <CheckBox x:Name="chk_unsharp" Content="Unsharp (--vpp-unsharp)" Margin="0,4"/><DockPanel Margin="0,0,0,7"><Slider x:Name="sl_unsharp" Minimum="0" Maximum="10" Value="0.5"/><TextBlock x:Name="lbl_unsharp" Text="0.50" Width="36" VerticalAlignment="Center" TextAlignment="Right"/></DockPanel>
        <CheckBox x:Name="chk_resize" Content="Resize (--output-res)" Margin="0,4"/><DockPanel Margin="0,0,0,10"><TextBox x:Name="txt_width" Text="1920" ToolTip="Output width"/><TextBlock Text=" × " VerticalAlignment="Center"/><TextBox x:Name="txt_height" Text="1080" ToolTip="Output height"/></DockPanel>
        <TextBlock Text="COMMAND PREVIEW" FontSize="10" FontWeight="Bold" Foreground="#A8ACB7" Margin="0,0,0,6"/><TextBox x:Name="txt_command" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True" MinHeight="65" Background="#111318" BorderThickness="0" FontFamily="Consolas" FontSize="10" Padding="8"/>
      </StackPanel></ScrollViewer></Border>
    </Grid>
    <DockPanel Grid.Row="2" Margin="0,10,0,0"><TextBlock Text="NVEncC Windows • VapourBox-inspired workflow" Foreground="#727987" VerticalAlignment="Center" FontSize="10"/><StackPanel DockPanel.Dock="Right" Orientation="Horizontal"><Button x:Name="btn_stop" Content="Stop" IsEnabled="False" MinWidth="85" Margin="0,0,8,0" Padding="10,7"/><Button x:Name="btn_start" Content="Start encode" MinWidth="115" Padding="12,7" Background="#7564D8" Foreground="White" FontWeight="Bold"/></StackPanel></DockPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$controlNames = @('lbl_status','txt_log','txt_input','txt_output','cmb_codec','sl_quality','lbl_quality','chk_knn','sl_knn_strength','lbl_knn_strength','sl_knn_radius','lbl_knn_radius','chk_deband','sl_deband_range','lbl_deband_range','sl_deband_thre','lbl_deband_thre','sl_deband_dither','lbl_deband_dither','chk_unsharp','sl_unsharp','lbl_unsharp','chk_resize','txt_width','txt_height','txt_command','btn_input','btn_output','btn_original','btn_processed','preview_grid','img_original','img_processed','clip_original','divider','sl_split','btn_start','btn_stop')
foreach ($name in $controlNames) { Set-Variable -Name $name -Value $window.FindName($name) -Scope Script }

$btn_input.Add_Click({ Browse-Input })
$btn_output.Add_Click({ Browse-Output })
$btn_original.Add_Click({ Load-Still $true })
$btn_processed.Add_Click({ Load-Still $false })
$btn_start.Add_Click({ Start-Encoding })
$btn_stop.Add_Click({ Stop-Encoding })
$sl_split.Add_ValueChanged({ Update-Comparison })
$preview_grid.Add_SizeChanged({ Update-Comparison })
$txt_input.Add_TextChanged({ Update-CommandPreview })
$txt_output.Add_TextChanged({ Update-CommandPreview })
$cmb_codec.Add_SelectionChanged({ Update-CommandPreview })
$txt_width.Add_TextChanged({ Update-CommandPreview })
$txt_height.Add_TextChanged({ Update-CommandPreview })
$filterControls = @($chk_knn,$sl_knn_strength,$sl_knn_radius,$chk_deband,$sl_deband_range,$sl_deband_thre,$sl_deband_dither,$chk_unsharp,$sl_unsharp,$chk_resize)
foreach ($control in $filterControls) {
    if ($control -is [System.Windows.Controls.Slider]) { $control.Add_ValueChanged({ Update-CommandPreview }) }
    elseif ($control -is [System.Windows.Controls.CheckBox]) { $control.Add_Checked({ Update-CommandPreview }); $control.Add_Unchecked({ Update-CommandPreview }) }
}
$sl_quality.Add_ValueChanged({ $lbl_quality.Text = [string][int]$sl_quality.Value; Update-CommandPreview })
$sl_knn_strength.Add_ValueChanged({ $lbl_knn_strength.Text = '{0:0.00}' -f $sl_knn_strength.Value })
$sl_knn_radius.Add_ValueChanged({ $lbl_knn_radius.Text = [string][int]$sl_knn_radius.Value })
$sl_deband_range.Add_ValueChanged({ $lbl_deband_range.Text = [string][int]$sl_deband_range.Value })
$sl_deband_thre.Add_ValueChanged({ $lbl_deband_thre.Text = [string][int]$sl_deband_thre.Value })
$sl_deband_dither.Add_ValueChanged({ $lbl_deband_dither.Text = [string][int]$sl_deband_dither.Value })
$sl_unsharp.Add_ValueChanged({ $lbl_unsharp.Text = '{0:0.00}' -f $sl_unsharp.Value })

$Script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$Script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$Script:PollTimer.Add_Tick({
    foreach ($line in (Read-NewLines $Script:StdoutPath ([ref]$Script:ReadOut))) { Add-Log $line }
    foreach ($line in (Read-NewLines $Script:StderrPath ([ref]$Script:ReadErr))) { Add-Log $line }
    if ($Script:Process -and $Script:Process.HasExited) {
        $Script:PollTimer.Stop(); $btn_start.IsEnabled = $true; $btn_stop.IsEnabled = $false
        if ($Script:Process.ExitCode -eq 0) { $lbl_status.Text = 'Completed'; Add-Log 'Encode completed.' }
        else { $lbl_status.Text = "Failed (exit $($Script:Process.ExitCode))"; Add-Log "NVEncC exited with code $($Script:Process.ExitCode)." }
        $Script:Process = $null
    }
})

$window.Add_Closing({
    $Script:Closing = $true
    if ($Script:PollTimer) { $Script:PollTimer.Stop() }
    if ($Script:Process -and -not $Script:Process.HasExited) { try { $Script:Process.Kill() } catch { } }
    Remove-Item $Script:StdoutPath,$Script:StderrPath -Force -ErrorAction SilentlyContinue
})
Update-CommandPreview
$sl_knn_strength.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Slider]::ValueChangedEvent)))
$sl_knn_radius.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Slider]::ValueChangedEvent)))
$sl_deband_range.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Slider]::ValueChangedEvent)))
$sl_deband_thre.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Slider]::ValueChangedEvent)))
$sl_deband_dither.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Slider]::ValueChangedEvent)))
$sl_unsharp.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Slider]::ValueChangedEvent)))
$null = $window.ShowDialog()
