param(
  [string]$ReleaseRepo = "Synclab-VN/lpm-release",
  [string]$GitHubHost = "github.com",
  [string]$Tag = "",
  [ValidateSet("stable", "prerelease")]
  [string]$Channel = "stable",
  [string]$InstallDir = "$env:LOCALAPPDATA\LAT-Agent",
  [switch]$NoStart,
  [switch]$NoDesktopShortcut,
  [switch]$NoAutoStart,
  [switch]$Silent,
  [switch]$WorkerMode,
  [switch]$Force,
  [string]$LogPath = "",
  [string]$InstallerScriptUrl = "https://raw.githubusercontent.com/Synclab-VN/lpm-release/refs/heads/main/installer/windows/install-lat-agent.ps1",
  [string]$GitHubToken = ""
)

$ErrorActionPreference = "Stop"

$script:ProgressTotal = 100
$script:ProgressCurrent = 0
$script:ProgressCallback = $null
$script:EventPrefix = "__LAT_EVENT__:"
$script:IsWorkerMode = [bool]$WorkerMode
$script:InstallerLogPath = $LogPath
$script:InstallerSessionId = [guid]::NewGuid().ToString("N").Substring(0, 8)
$script:InstallerRole = if ($script:IsWorkerMode) { "WORKER" } else { "GUI" }

function Get-DefaultLogPath {
  return (Join-Path $env:TEMP "lat-installer.log")
}

function Ensure-InstallerLogPath {
  if ([string]::IsNullOrWhiteSpace($script:InstallerLogPath)) {
    $script:InstallerLogPath = Get-DefaultLogPath
  }
  $logDir = Split-Path -Parent $script:InstallerLogPath
  if (-not [string]::IsNullOrWhiteSpace($logDir)) {
    Ensure-Dir $logDir
  }
}

function Append-InstallerLog([string]$Line) {
  if ([string]::IsNullOrWhiteSpace($script:InstallerLogPath)) { return }
  try {
    Add-Content -LiteralPath $script:InstallerLogPath -Value $Line -Encoding UTF8
  } catch {
  }
}

function Emit-InstallerEvent([string]$Kind, [hashtable]$Payload) {
  if (-not $script:IsWorkerMode) { return }
  $event = @{ kind = $Kind }
  foreach ($k in $Payload.Keys) {
    $event[$k] = $Payload[$k]
  }
  $json = $event | ConvertTo-Json -Compress
  Write-Output ($script:EventPrefix + $json)
}

function Write-Info([string]$Message) {
  $line = "[LAT-INSTALL][$($script:InstallerRole)][sid=$($script:InstallerSessionId)][pid=$PID] $Message"
  Write-Host $line
  Append-InstallerLog $line
  Emit-InstallerEvent "log" @{ message = $Message }
}

function Format-ExceptionDetail([System.Management.Automation.ErrorRecord]$ErrorRecord) {
  if ($null -eq $ErrorRecord) { return "Unknown error" }
  $parts = @()
  if ($ErrorRecord.Exception) {
    $parts += ($ErrorRecord.Exception.GetType().FullName + ": " + $ErrorRecord.Exception.Message)
    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.Exception.StackTrace)) {
      $parts += "StackTrace: " + $ErrorRecord.Exception.StackTrace
    }
  } else {
    $parts += $ErrorRecord.ToString()
  }
  if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
    $parts += "ScriptStackTrace: " + $ErrorRecord.ScriptStackTrace
  }
  return ($parts -join "`n")
}

function Set-ProgressCallback([scriptblock]$Callback) {
  $script:ProgressCallback = $Callback
}

function Report-Progress([int]$Percent, [string]$Status) {
  if ($Percent -lt 0) { $Percent = 0 }
  if ($Percent -gt 100) { $Percent = 100 }
  $script:ProgressCurrent = $Percent
  Write-Info $Status
  Emit-InstallerEvent "progress" @{ percent = $Percent; status = $Status }
  if ($script:ProgressCallback) {
    & $script:ProgressCallback $Percent $Status
  }
}

function Get-ApiBase([string]$HostName) {
  if ($HostName -eq "github.com") { return "https://api.github.com" }
  return "https://$HostName/api/v3"
}

function New-Headers([string]$Token) {
  $headers = @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "LAT-Agent-Installer" }
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers["Authorization"] = "Bearer $Token"
  }
  return $headers
}

function Invoke-GhJson([string]$Url, [hashtable]$Headers) {
  return Invoke-RestMethod -Method GET -Uri $Url -Headers $Headers
}

function Ensure-Dir([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Stop-LatAgentInInstall([string]$EngineDir) {
  try {
    $targetExe = [System.IO.Path]::GetFullPath((Join-Path $EngineDir "lat-agent.exe"))
    $procs = Get-Process -Name "lat-agent" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      try {
        if ($p.Path -and ([System.String]::Equals([System.IO.Path]::GetFullPath($p.Path), $targetExe, [System.StringComparison]::OrdinalIgnoreCase))) {
          Write-Info "Stopping existing LAT process PID=$($p.Id)"
          Stop-Process -Id $p.Id -Force
        }
      } catch {
      }
    }
  } catch {
    Write-Info "Warning: failed to stop existing process cleanly: $($_.Exception.Message)"
  }
}

function Get-AssetByNamePattern($Assets, [string]$Pattern) {
  foreach ($asset in $Assets) {
    if ($asset.name -like $Pattern) { return $asset }
  }
  return $null
}

function New-OrUpdateDesktopShortcut([string]$EngineDir) {
  try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($desktop)) {
      Write-Info "Warning: Desktop path not resolved; skip shortcut creation"
      return
    }

    $shortcutPath = Join-Path $desktop "LAT.lnk"
    $launcher = Join-Path $EngineDir "engine_launcher_windows.bat"
    if (-not (Test-Path -LiteralPath $launcher)) {
      Write-Info "Warning: launcher not found; skip shortcut creation ($launcher)"
      return
    }

    $iconPrimary = Join-Path $EngineDir "lat-agent.exe"
    $iconFallback = Join-Path $EngineDir "lat-agent-tray.exe"
    $iconLocation = ""
    if (Test-Path -LiteralPath $iconPrimary) {
      $iconLocation = "$iconPrimary,0"
    } elseif (Test-Path -LiteralPath $iconFallback) {
      $iconLocation = "$iconFallback,0"
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcher
    $shortcut.WorkingDirectory = $EngineDir
    if (-not [string]::IsNullOrWhiteSpace($iconLocation)) {
      $shortcut.IconLocation = $iconLocation
    }
    $shortcut.Save()
    Write-Info "Desktop shortcut created/updated: $shortcutPath"
  } catch {
    Write-Info "Warning: failed to create desktop shortcut: $($_.Exception.Message)"
  }
}

function Register-LatStartupTask([string]$InstallRoot, [string]$EngineDir) {
  try {
    $taskName = "LAT Agent"
    $launcher = Join-Path $EngineDir "engine_launcher_windows.bat"
    if (-not (Test-Path -LiteralPath $launcher)) {
      Write-Info "Warning: launcher not found; skip startup task"
      return
    }

    $action = $null
    try {
      $action = New-ScheduledTaskAction -Execute $launcher -Argument "--tray" -WorkingDirectory $EngineDir
    } catch {
      $cmdArg = "/c `"`"$launcher`" --tray`""
      $action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $cmdArg -WorkingDirectory $EngineDir
    }
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 0)
    $settings.RestartCount = 999
    $settings.RestartInterval = "PT1M"

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "LAT Agent autostart with crash restart" -Force | Out-Null
    Write-Info "Startup task configured: $taskName"
  } catch {
    Write-Info "Warning: failed to configure startup task: $($_.Exception.Message)"
  }
}

function Unregister-LatStartupTask() {
  try {
    Unregister-ScheduledTask -TaskName "LAT Agent" -Confirm:$false -ErrorAction Stop
    Write-Info "Startup task removed: LAT Agent"
  } catch {
    Write-Info "Startup task not present or remove failed: $($_.Exception.Message)"
  }
}

function Resolve-Release([string]$ApiBase, [string]$Repo, [string]$ChannelName, [string]$TagName, [hashtable]$Headers) {
  if (-not [string]::IsNullOrWhiteSpace($TagName)) {
    $url = "$ApiBase/repos/$Repo/releases/tags/$TagName"
    Report-Progress 10 "Resolving release by tag: $TagName"
    return Invoke-GhJson -Url $url -Headers $Headers
  }

  if ($ChannelName -eq "stable") {
    $url = "$ApiBase/repos/$Repo/releases/latest"
    Report-Progress 10 "Resolving latest stable release"
    return Invoke-GhJson -Url $url -Headers $Headers
  }

  $url = "$ApiBase/repos/$Repo/releases"
  Report-Progress 10 "Resolving latest prerelease/stable release list"
  $list = Invoke-GhJson -Url $url -Headers $Headers
  if (-not $list -or $list.Count -eq 0) { throw "No releases found in $Repo" }
  return $list[0]
}

function Install-LatAgent([hashtable]$Config) {
  $token = $Config.GitHubToken
  if ([string]::IsNullOrWhiteSpace($token) -and $env:SYNC_GH_TOKEN) { $token = $env:SYNC_GH_TOKEN }
  if ([string]::IsNullOrWhiteSpace($token) -and $env:RELEASE_GH_TOKEN) { $token = $env:RELEASE_GH_TOKEN }

  $apiBase = Get-ApiBase -HostName $Config.GitHubHost
  $headers = New-Headers -Token $token

  Report-Progress 2 "Initializing installer"
  $release = Resolve-Release -ApiBase $apiBase -Repo $Config.ReleaseRepo -ChannelName $Config.Channel -TagName $Config.Tag -Headers $headers
  if (-not $release) { throw "Failed to resolve release" }
  $versionTag = "$($release.tag_name)"
  Report-Progress 15 "Resolved release: $versionTag"

  $zipAsset = Get-AssetByNamePattern -Assets $release.assets -Pattern "lat-engine-windows-x64-v*.zip"
  $metaAsset = Get-AssetByNamePattern -Assets $release.assets -Pattern "lat-release-metadata.json"
  if (-not $zipAsset) { throw "Windows package asset not found" }
  if (-not $metaAsset) { throw "lat-release-metadata.json asset not found" }

  $tempRoot = Join-Path $env:TEMP ("lat-install-" + [guid]::NewGuid().ToString("N"))
  $downloadDir = Join-Path $tempRoot "download"
  $extractDir = Join-Path $tempRoot "extract"
  Ensure-Dir $downloadDir
  Ensure-Dir $extractDir

  $zipPath = Join-Path $downloadDir $zipAsset.name
  $metaPath = Join-Path $downloadDir $metaAsset.name

  Report-Progress 25 "Downloading package"
  Invoke-WebRequest -Uri $zipAsset.browser_download_url -Headers $headers -OutFile $zipPath

  Report-Progress 35 "Downloading metadata"
  Invoke-WebRequest -Uri $metaAsset.browser_download_url -Headers $headers -OutFile $metaPath

  Report-Progress 45 "Verifying package checksum"
  $meta = Get-Content -Raw -LiteralPath $metaPath | ConvertFrom-Json
  $expectedSha = $meta.assets.'windows-x64'.sha256
  if ([string]::IsNullOrWhiteSpace($expectedSha)) { throw "Missing checksum in metadata" }

  $actualSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualSha -ne $expectedSha.ToLowerInvariant()) {
    throw "Checksum mismatch for package. expected=$expectedSha actual=$actualSha"
  }

  Report-Progress 55 "Extracting package"
  Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

  $engineSrc = Join-Path $extractDir "engine"
  if (-not (Test-Path -LiteralPath $engineSrc)) { throw "Invalid package: missing engine directory" }

  $manifestPath = Join-Path $extractDir "lat-engine-package-manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Invalid package: missing manifest" }
  $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
  if (-not $manifest.managed_files -or $manifest.managed_files.Count -eq 0) {
    throw "Invalid package manifest: managed_files missing"
  }

  Report-Progress 65 "Preparing install directory"
  $installRoot = [System.IO.Path]::GetFullPath($Config.InstallDir)
  $engineDst = Join-Path $installRoot "engine"
  Ensure-Dir $installRoot
  Ensure-Dir $engineDst
  Ensure-Dir (Join-Path $installRoot "plugins")
  Ensure-Dir (Join-Path $installRoot "updatedata")

  Stop-LatAgentInInstall -EngineDir $engineDst

  Report-Progress 75 "Installing engine files"
  foreach ($rel in $manifest.managed_files) {
    $src = Join-Path $extractDir $rel
    $dst = Join-Path $installRoot $rel
    if (-not (Test-Path -LiteralPath $src)) {
      throw "Managed file missing in package: $rel"
    }
    Ensure-Dir (Split-Path -Parent $dst)
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }

  $launcher = Join-Path $engineDst "engine_launcher_windows.bat"

  if (-not $Config.NoDesktopShortcut) {
    Report-Progress 85 "Creating desktop shortcut"
    New-OrUpdateDesktopShortcut -EngineDir $engineDst
  }

  if ($Config.NoAutoStart) {
    Report-Progress 90 "Disabling startup task"
    Unregister-LatStartupTask
  } else {
    Report-Progress 90 "Configuring startup and crash restart"
    Register-LatStartupTask -InstallRoot $installRoot -EngineDir $engineDst
  }

  if (-not $Config.NoStart) {
    if (Test-Path -LiteralPath $launcher) {
      Report-Progress 96 "Starting LAT Agent"
      Start-Process -FilePath $launcher -WorkingDirectory $engineDst
    } else {
      Write-Info "Launcher not found, skip auto-start"
    }
  }

  try {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
  } catch {}

  Report-Progress 100 "Install completed. UI expected at: http://127.0.0.1:8788/plugins"
  return @{
    InstallRoot = $installRoot
    Version = $versionTag
  }
}

function Test-WpfAvailable {
  try {
    Add-Type -AssemblyName PresentationFramework | Out-Null
    Add-Type -AssemblyName PresentationCore | Out-Null
    Add-Type -AssemblyName WindowsBase | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Show-InstallerWindow {
  [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LAT Installer" Height="430" Width="640"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="LAT Agent Installer" FontSize="22" FontWeight="SemiBold" />

    <StackPanel Grid.Row="1" Margin="0,14,0,0">
      <TextBlock Text="Install directory" Margin="0,0,0,6" />
      <DockPanel>
        <Button x:Name="BrowseButton" Content="Browse" Width="88" DockPanel.Dock="Right" Margin="8,0,0,0"/>
        <TextBox x:Name="InstallDirBox" Height="30" />
      </DockPanel>
    </StackPanel>

    <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,14,0,0">
      <TextBlock Text="Channel" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <ComboBox x:Name="ChannelBox" Width="150" Height="30">
        <ComboBoxItem Content="stable"/>
        <ComboBoxItem Content="prerelease"/>
      </ComboBox>
      <TextBlock Text="Tag (optional)" VerticalAlignment="Center" Margin="20,0,8,0"/>
      <TextBox x:Name="TagBox" Width="220" Height="30"/>
    </StackPanel>

    <StackPanel Grid.Row="3" Margin="0,14,0,0">
      <CheckBox x:Name="DesktopShortcutCheck" Content="Create desktop shortcut (LAT)" IsChecked="True" />
      <CheckBox x:Name="AutoStartCheck" Content="Start LAT Agent after install" IsChecked="True" Margin="0,6,0,0"/>
      <CheckBox x:Name="StartupTaskCheck" Content="Run at startup and auto-restart after crash" IsChecked="True" Margin="0,6,0,0"/>
    </StackPanel>

    <StackPanel Grid.Row="4" Margin="0,14,0,0">
      <ProgressBar x:Name="InstallProgress" Height="18" Minimum="0" Maximum="100" Value="0"/>
      <TextBlock x:Name="StatusText" Margin="0,6,0,0" Text="Ready" />
    </StackPanel>

    <TextBox Grid.Row="5" x:Name="LogBox" Margin="0,14,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>

    <TextBlock Grid.Row="6" Text="Tip: You can still run silent mode with -Silent" Foreground="Gray" Margin="0,10,0,0"/>

    <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="InstallButton" Content="Install" Width="110" Height="34" />
      <Button x:Name="CloseButton" Content="Close" Width="110" Height="34" Margin="10,0,0,0" />
    </StackPanel>
  </Grid>
</Window>
'@

  try {
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
  } catch {
    throw "Failed to load installer GUI XAML: $($_.Exception.Message)"
  }

  $installDirBox = $window.FindName("InstallDirBox")
  $channelBox = $window.FindName("ChannelBox")
  $tagBox = $window.FindName("TagBox")
  $desktopShortcutCheck = $window.FindName("DesktopShortcutCheck")
  $autoStartCheck = $window.FindName("AutoStartCheck")
  $startupTaskCheck = $window.FindName("StartupTaskCheck")
  $progressBar = $window.FindName("InstallProgress")
  $statusText = $window.FindName("StatusText")
  $logBox = $window.FindName("LogBox")
  $installButton = $window.FindName("InstallButton")
  $closeButton = $window.FindName("CloseButton")
  $browseButton = $window.FindName("BrowseButton")
  if ($null -eq $window -or $null -eq $installButton -or $null -eq $statusText -or $null -eq $logBox -or $null -eq $channelBox) {
    throw "Installer GUI is missing required controls after XAML load."
  }

  try {
    $unhandledHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler]{
      param($sender, $e)
      Write-Info ("GUI unhandled exception: " + $e.Exception.Message)
      if ($null -ne $e.Exception) {
        if (-not [string]::IsNullOrWhiteSpace($e.Exception.StackTrace)) {
          Append-InstallerLog ("UnhandledStackTrace: " + $e.Exception.StackTrace)
        }
      }
      $e.Handled = $true
    }
    $window.Dispatcher.add_UnhandledException($unhandledHandler)
  } catch {
    Write-Info ("Warning: failed to hook GUI unhandled exception handler: " + $_.Exception.Message)
  }

  $installDirBox.Text = $InstallDir
  $channelBox.SelectedIndex = if ($Channel -eq "prerelease") { 1 } else { 0 }
  $tagBox.Text = $Tag
  $desktopShortcutCheck.IsChecked = (-not $NoDesktopShortcut)
  $autoStartCheck.IsChecked = (-not $NoStart)
  $startupTaskCheck.IsChecked = (-not $NoAutoStart)

  $appendLog = {
    param([string]$line)
    $now = Get-Date -Format "HH:mm:ss"
    $entry = "[$now] $line"
    $logBox.AppendText("$entry`r`n")
    $logBox.ScrollToEnd()
    Append-InstallerLog $entry
  }

  $browseButton.Add_Click({
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.SelectedPath = $installDirBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      $installDirBox.Text = $dialog.SelectedPath
    }
  }.GetNewClosure())

  $closeButton.Add_Click({ $window.Close() }.GetNewClosure())

  $installButton.Add_Click({
    try {
      $installButton.IsEnabled = $false
      $closeButton.IsEnabled = $false
      $progressBar.Value = 0
      $statusText.Text = "Starting installer worker..."

      $selectedItem = [System.Windows.Controls.ComboBoxItem]$channelBox.SelectedItem
      $selectedChannel = if ($null -ne $selectedItem -and -not [string]::IsNullOrWhiteSpace($selectedItem.Content)) { $selectedItem.Content.ToString() } else { "stable" }
      $config = @{
        ReleaseRepo = $ReleaseRepo
        GitHubHost = $GitHubHost
        Tag = $tagBox.Text.Trim()
        Channel = $selectedChannel
        InstallDir = $installDirBox.Text.Trim()
        NoStart = (-not [bool]$autoStartCheck.IsChecked)
        NoDesktopShortcut = (-not [bool]$desktopShortcutCheck.IsChecked)
        NoAutoStart = (-not [bool]$startupTaskCheck.IsChecked)
        GitHubToken = $GitHubToken
      }

      $scriptPath = $PSCommandPath
      if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $MyInvocation.MyCommand.Path
      }
      $useRemoteWorkerScript = [string]::IsNullOrWhiteSpace($scriptPath)
      if ($useRemoteWorkerScript -and [string]::IsNullOrWhiteSpace($InstallerScriptUrl)) {
        $msg = "Cannot resolve installer script path for worker mode and InstallerScriptUrl is empty."
        $statusText.Text = "Failed"
        & $appendLog "ERROR: $msg"
        $installButton.IsEnabled = $true
        $closeButton.IsEnabled = $true
        [System.Windows.MessageBox]::Show($msg, "LAT Installer", "OK", "Error") | Out-Null
        return
      }

      $workerStdOut = Join-Path $env:TEMP ("lat-installer-worker-out-" + [guid]::NewGuid().ToString("N") + ".log")
      $workerStdErr = Join-Path $env:TEMP ("lat-installer-worker-err-" + [guid]::NewGuid().ToString("N") + ".log")
      $workerLog = if ([string]::IsNullOrWhiteSpace($script:InstallerLogPath)) { Get-DefaultLogPath } else { $script:InstallerLogPath }

      $commonArgs = @(
        "-WorkerMode",
        "-Silent",
        "-ReleaseRepo", $config.ReleaseRepo,
        "-GitHubHost", $config.GitHubHost,
        "-Channel", $config.Channel,
        "-InstallDir", $config.InstallDir,
        "-LogPath", $workerLog
      )
      if (-not [string]::IsNullOrWhiteSpace($config.Tag)) { $commonArgs += @("-Tag", $config.Tag) }
      if ($config.NoStart) { $commonArgs += "-NoStart" }
      if ($config.NoDesktopShortcut) { $commonArgs += "-NoDesktopShortcut" }
      if ($config.NoAutoStart) { $commonArgs += "-NoAutoStart" }
      if (-not [string]::IsNullOrWhiteSpace($config.GitHubToken)) { $commonArgs += @("-GitHubToken", $config.GitHubToken) }

      $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass"
      )
      if ($useRemoteWorkerScript) {
        $workerCommand = "& ([scriptblock]::Create((Invoke-RestMethod -Uri '" + $InstallerScriptUrl.Replace("'", "''") + "'))) " + (($commonArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_.Replace('"', '""') + '"' } else { $_ } }) -join " ")
        $args += @("-Command", $workerCommand)
      } else {
        $args += @("-File", $scriptPath)
        $args += $commonArgs
      }

      try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $workerStdOut -RedirectStandardError $workerStdErr
      } catch {
        $msg = "Failed to start installer worker: $($_.Exception.Message)"
        $statusText.Text = "Failed"
        & $appendLog "ERROR: $msg"
        $installButton.IsEnabled = $true
        $closeButton.IsEnabled = $true
        [System.Windows.MessageBox]::Show($msg, "LAT Installer", "OK", "Error") | Out-Null
        return
      }

      & $appendLog ("Worker started. PID=" + $proc.Id)

      $timer = New-Object System.Windows.Threading.DispatcherTimer
      $timer.Interval = [TimeSpan]::FromMilliseconds(300)
      $state = @{
        LastOutLine = 0
        LastErrLine = 0
        Completed = $false
        ResultVersion = ""
        ResultInstallRoot = ""
        ErrorMessage = ""
      }

      $timer.Add_Tick({
        try {
          if (Test-Path -LiteralPath $workerStdOut) {
            $outLines = @(Get-Content -LiteralPath $workerStdOut)
            for ($i = $state.LastOutLine; $i -lt $outLines.Count; $i++) {
              $line = [string]$outLines[$i]
              if ([string]::IsNullOrWhiteSpace($line)) { continue }
              if ($line.StartsWith($script:EventPrefix)) {
                $json = $line.Substring($script:EventPrefix.Length)
                try {
                  $evt = $json | ConvertFrom-Json
                  if ($evt.kind -eq "progress") {
                    $progressBar.Value = [double]$evt.percent
                    $statusText.Text = [string]$evt.status
                  } elseif ($evt.kind -eq "log") {
                    & $appendLog ([string]$evt.message)
                  } elseif ($evt.kind -eq "result") {
                    $state.ResultVersion = [string]$evt.version
                    $state.ResultInstallRoot = [string]$evt.install_root
                  } elseif ($evt.kind -eq "error") {
                    $state.ErrorMessage = [string]$evt.message
                  }
                } catch {
                  & $appendLog ("WARN: Failed to parse worker event line: " + $line)
                }
              } else {
                & $appendLog $line
              }
            }
            $state.LastOutLine = $outLines.Count
          }

          if (Test-Path -LiteralPath $workerStdErr) {
            $errLines = @(Get-Content -LiteralPath $workerStdErr)
            for ($j = $state.LastErrLine; $j -lt $errLines.Count; $j++) {
              $errLine = [string]$errLines[$j]
              if (-not [string]::IsNullOrWhiteSpace($errLine)) {
                & $appendLog ("STDERR: " + $errLine)
              }
            }
            $state.LastErrLine = $errLines.Count
          }

          if ($proc.HasExited -and -not $state.Completed) {
            $state.Completed = $true
            $timer.Stop()
            if ($proc.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($state.ErrorMessage)) {
              $progressBar.Value = 100
              $statusText.Text = if ([string]::IsNullOrWhiteSpace($state.ResultVersion)) { "Done" } else { "Done: " + $state.ResultVersion }
              if (-not [string]::IsNullOrWhiteSpace($state.ResultInstallRoot)) {
                & $appendLog ("Install success at " + $state.ResultInstallRoot)
              } else {
                & $appendLog "Install success."
              }
              [System.Windows.MessageBox]::Show("Install completed successfully.", "LAT Installer", "OK", "Information") | Out-Null
            } else {
              $msg = if ([string]::IsNullOrWhiteSpace($state.ErrorMessage)) { "Installer worker failed with exit code $($proc.ExitCode). See log: $workerLog" } else { $state.ErrorMessage }
              $statusText.Text = "Failed"
              & $appendLog ("ERROR: " + $msg)
              [System.Windows.MessageBox]::Show("Install failed: $msg", "LAT Installer", "OK", "Error") | Out-Null
            }
            $installButton.IsEnabled = $true
            $closeButton.IsEnabled = $true
            try { Remove-Item -LiteralPath $workerStdOut -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $workerStdErr -Force -ErrorAction SilentlyContinue } catch {}
          }
        } catch {
          if ($null -ne $timer) {
            try { $timer.Stop() } catch {}
          }
          $msg = "GUI worker monitor failed: $($_.Exception.Message)"
          $statusText.Text = "Failed"
          & $appendLog ("ERROR: " + $msg)
          & $appendLog (Format-ExceptionDetail $_)
          $installButton.IsEnabled = $true
          $closeButton.IsEnabled = $true
          [System.Windows.MessageBox]::Show($msg, "LAT Installer", "OK", "Error") | Out-Null
        }
      }.GetNewClosure())
      $timer.Start()
    } catch {
      $statusText.Text = "Failed"
      & $appendLog ("ERROR: Install click handler failed: " + $_.Exception.Message)
      & $appendLog (Format-ExceptionDetail $_)
      $installButton.IsEnabled = $true
      $closeButton.IsEnabled = $true
      [System.Windows.MessageBox]::Show("Install failed: " + $_.Exception.Message, "LAT Installer", "OK", "Error") | Out-Null
    }
  }.GetNewClosure())

  $window.ShowDialog() | Out-Null
}

$configDefault = @{
  ReleaseRepo = $ReleaseRepo
  GitHubHost = $GitHubHost
  Tag = $Tag
  Channel = $Channel
  InstallDir = $InstallDir
  NoStart = [bool]$NoStart
  NoDesktopShortcut = [bool]$NoDesktopShortcut
  NoAutoStart = [bool]$NoAutoStart
  GitHubToken = $GitHubToken
}

Ensure-InstallerLogPath
Append-InstallerLog ("[LAT-INSTALL][$($script:InstallerRole)][sid=$($script:InstallerSessionId)][pid=$PID] Session started at " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

try {
  if (($Silent -or -not (Test-WpfAvailable)) -and -not $WorkerMode) {
    Set-ProgressCallback {
      param($pct, $status)
      Write-Progress -Activity "LAT Installer" -Status $status -PercentComplete $pct
    }
  }

  if ($WorkerMode -or $Silent -or -not (Test-WpfAvailable)) {
    $result = Install-LatAgent -Config $configDefault
    if ($WorkerMode) {
      Emit-InstallerEvent "result" @{
        version = [string]$result.Version
        install_root = [string]$result.InstallRoot
      }
    }
  } else {
    Show-InstallerWindow
  }
} catch {
  $msg = Format-ExceptionDetail $_
  Write-Info "ERROR: $msg"
  if ($WorkerMode) {
    Emit-InstallerEvent "error" @{ message = $msg }
    throw
  }
}
