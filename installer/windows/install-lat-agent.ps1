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
$script:InstallerVersion = "1.0.5"
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
  $line = "[LAT-INSTALL][$($script:InstallerRole)][installer_version=$($script:InstallerVersion)][sid=$($script:InstallerSessionId)][pid=$PID] $Message"
  if (-not $script:IsWorkerMode) {
    Write-Host $line
  }
  Append-InstallerLog $line
  Emit-InstallerEvent "log" @{ message = $Message }
}

function Add-LatInstallerGuiLog($LogBox, [string]$Line) {
  $now = Get-Date -Format "HH:mm:ss"
  $entry = "[$now] $Line"
  try {
    if ($null -ne $LogBox) {
      $LogBox.AppendText("$entry`r`n")
      $LogBox.ScrollToEnd()
    }
  } catch {
  }
  Append-InstallerLog $entry
}

function Set-LatInstallerControlText($Control, [string]$Value) {
  if ($null -eq $Control) { return $false }
  try {
    $Control.Text = $Value
    return $true
  } catch {
  }
  try {
    $Control.Content = $Value
    return $true
  } catch {
  }
  return $false
}

function Set-LatInstallerStatus($StatusText, $LogBox, [string]$Value) {
  [void](Set-LatInstallerControlText $StatusText $Value)
}

function Set-LatInstallerResult($ResultText, [string]$Value, [string]$Kind) {
  if (-not (Set-LatInstallerControlText $ResultText $Value)) { return }
  try {
    if ($Kind -eq "success") {
      $ResultText.Foreground = [System.Windows.Media.Brushes]::ForestGreen
    } elseif ($Kind -eq "error") {
      $ResultText.Foreground = [System.Windows.Media.Brushes]::Firebrick
    } else {
      $ResultText.Foreground = [System.Windows.Media.Brushes]::Gray
    }
  } catch {
  }
}

function Set-LatInstallerProgressState($ProgressBar, [double]$Value, [Nullable[bool]]$Indeterminate) {
  if ($null -eq $ProgressBar) { return }
  if ($Indeterminate -ne $null) {
    try {
      $ProgressBar.IsIndeterminate = [bool]$Indeterminate
    } catch {
    }
  }
  try {
    $next = [Math]::Max(0, [Math]::Min(100, $Value))
    $ProgressBar.Value = $next
  } catch {
  }
}

function Set-LatInstallerControlEnabled($Control, [bool]$Enabled) {
  if ($null -eq $Control) { return }
  try {
    $Control.IsEnabled = $Enabled
  } catch {
  }
}

function ConvertFrom-LatInstallerEventLine([string]$Line) {
  $prefix = "__LAT_EVENT__:"
  if ([string]::IsNullOrWhiteSpace($Line) -or -not $Line.StartsWith($prefix)) {
    return [pscustomobject]@{ IsEvent = $false; Event = $null; Error = $null }
  }
  try {
    $json = $Line.Substring($prefix.Length)
    return [pscustomobject]@{ IsEvent = $true; Event = ($json | ConvertFrom-Json); Error = $null }
  } catch {
    return [pscustomobject]@{ IsEvent = $true; Event = $null; Error = $_.Exception.Message }
  }
}

function Set-LatInstallerCompletedUi($Window, [string]$Version, [string]$InstallRoot, [bool]$Success, [string]$Message) {
  $logBox = $null
  if ($null -eq $Window) {
    Add-LatInstallerGuiLog $logBox "ERROR: Completed UI update skipped: window is null"
    return
  }

  try {
    $logBox = $Window.FindName("LogBox")
  } catch {
  }

  try {
    $progress = $Window.FindName("InstallProgress")
    $status = $Window.FindName("StatusText")
    $result = $Window.FindName("ResultText")
    $install = $Window.FindName("InstallButton")
    $close = $Window.FindName("CloseButton")

    $statusTextValue = "Failed"
    $resultTextValue = $Message
    $resultBrush = [System.Windows.Media.Brushes]::Firebrick
    $progressValue = 0
    if ($Success) {
      $statusTextValue = "Done"
      if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $statusTextValue = "Done: " + $Version
      }
      $resultTextValue = "Installation completed successfully. You can close this window."
      $resultBrush = [System.Windows.Media.Brushes]::ForestGreen
      $progressValue = 100
    }

    Set-LatInstallerProgressState $progress $progressValue $false
    Set-LatInstallerStatus $status $logBox $statusTextValue
    Set-LatInstallerControlText $result $resultTextValue | Out-Null
    try {
      if ($null -ne $result) {
        $result.Foreground = $resultBrush
      }
    } catch {
    }
    Set-LatInstallerControlEnabled $install $true
    Set-LatInstallerControlEnabled $close $true

    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
      Add-LatInstallerGuiLog $logBox ("Install success at " + $InstallRoot)
    }
  } catch {
    Add-LatInstallerGuiLog $logBox ("ERROR: Completed UI update failed: " + $_.Exception.Message)
  }

  try {
    if ($null -ne $Window -and $null -ne $Window.Dispatcher) {
      [void]$Window.Dispatcher.Invoke([System.Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
  } catch {
  }
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
    $targets = @(
      [System.IO.Path]::GetFullPath((Join-Path $EngineDir "lat-agent.exe")),
      [System.IO.Path]::GetFullPath((Join-Path $EngineDir "lat-agent-tray.exe"))
    )
    $procs = Get-Process -Name "lat-agent","lat-agent-tray" -ErrorAction SilentlyContinue
    foreach ($p in @($procs | Where-Object { $_ -ne $null } | Sort-Object Id -Unique)) {
      try {
        if ($p.Path) {
          $procPath = [System.IO.Path]::GetFullPath($p.Path)
          $matched = $false
          foreach ($target in $targets) {
            if ([System.String]::Equals($procPath, $target, [System.StringComparison]::OrdinalIgnoreCase)) {
              $matched = $true
              break
            }
          }
          if (-not $matched) { continue }
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

function Copy-WithRetry([string]$Source, [string]$Destination, [string]$EngineDir) {
  $maxAttempts = 6
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      Copy-Item -LiteralPath $Source -Destination $Destination -Force
      return
    } catch {
      if ($attempt -eq $maxAttempts) { throw }
      Write-Info ("Copy retry {0}/{1} for {2}: {3}" -f $attempt, $maxAttempts, $Destination, $_.Exception.Message)
      Stop-LatAgentInInstall -EngineDir $EngineDir
      Start-Sleep -Milliseconds (450 * $attempt)
    }
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
    Copy-WithRetry -Source $src -Destination $dst -EngineDir $engineDst
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

    <StackPanel Grid.Row="6" Margin="0,10,0,0">
      <TextBlock Text="Tip: You can still run silent mode with -Silent" Foreground="Gray"/>
      <TextBlock x:Name="ResultText" Margin="0,6,0,0" Text="" FontWeight="SemiBold"/>
    </StackPanel>

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
  $resultText = $window.FindName("ResultText")
  $logBox = $window.FindName("LogBox")
  $installButton = $window.FindName("InstallButton")
  $closeButton = $window.FindName("CloseButton")
  $browseButton = $window.FindName("BrowseButton")
  if ($null -eq $window -or $null -eq $installButton -or $null -eq $statusText -or $null -eq $resultText -or $null -eq $logBox -or $null -eq $channelBox) {
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

  $window.Title = "LAT Installer $script:InstallerVersion"
  $installDirBox.Text = $InstallDir
  $channelBox.SelectedIndex = if ($Channel -eq "prerelease") { 1 } else { 0 }
  $tagBox.Text = $Tag
  $desktopShortcutCheck.IsChecked = (-not $NoDesktopShortcut)
  $autoStartCheck.IsChecked = (-not $NoStart)
  $startupTaskCheck.IsChecked = (-not $NoAutoStart)

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
      Set-LatInstallerControlEnabled $installButton $false
      Set-LatInstallerControlEnabled $closeButton $false
      Set-LatInstallerProgressState $progressBar 0 $true
      Set-LatInstallerStatus $statusText $logBox "Starting installer worker..."
      Set-LatInstallerResult $resultText "Installing... please wait." "info"

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
        Set-LatInstallerStatus $statusText $logBox "Failed"
        Add-LatInstallerGuiLog $logBox "ERROR: $msg"
        Set-LatInstallerResult $resultText ("Installation failed: " + $msg) "error"
        Set-LatInstallerControlEnabled $installButton $true
        Set-LatInstallerControlEnabled $closeButton $true
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
        Set-LatInstallerStatus $statusText $logBox "Failed"
        Add-LatInstallerGuiLog $logBox "ERROR: $msg"
        Set-LatInstallerResult $resultText ("Installation failed: " + $msg) "error"
        Set-LatInstallerControlEnabled $installButton $true
        Set-LatInstallerControlEnabled $closeButton $true
        [System.Windows.MessageBox]::Show($msg, "LAT Installer", "OK", "Error") | Out-Null
        return
      }

      Add-LatInstallerGuiLog $logBox ("Worker started. PID=" + $proc.Id)

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
              $parsed = ConvertFrom-LatInstallerEventLine $line
              if ($parsed.IsEvent) {
                if (-not [string]::IsNullOrWhiteSpace([string]$parsed.Error)) {
                  Add-LatInstallerGuiLog $logBox ("WARN: Invalid worker event JSON: " + $parsed.Error)
                  continue
                }
                $evt = $parsed.Event
                if ($evt.kind -eq "progress") {
                  Set-LatInstallerProgressState $progressBar ([double]$evt.percent) $false
                  Set-LatInstallerStatus $statusText $logBox ([string]$evt.status)
                } elseif ($evt.kind -eq "log") {
                  Add-LatInstallerGuiLog $logBox ([string]$evt.message)
                } elseif ($evt.kind -eq "result") {
                  $state.ResultVersion = [string]$evt.version
                  $state.ResultInstallRoot = [string]$evt.install_root
                } elseif ($evt.kind -eq "error") {
                  $state.ErrorMessage = [string]$evt.message
                }
              } else {
                Add-LatInstallerGuiLog $logBox $line
              }
            }
            $state.LastOutLine = $outLines.Count
          }

          if (Test-Path -LiteralPath $workerStdErr) {
            $errLines = @(Get-Content -LiteralPath $workerStdErr)
            for ($j = $state.LastErrLine; $j -lt $errLines.Count; $j++) {
              $errLine = [string]$errLines[$j]
              if (-not [string]::IsNullOrWhiteSpace($errLine)) {
                Add-LatInstallerGuiLog $logBox ("STDERR: " + $errLine)
              }
            }
            $state.LastErrLine = $errLines.Count
          }

          if ($proc.HasExited -and -not $state.Completed) {
            $state.Completed = $true
            $timer.Stop()
            try { $proc.Refresh() } catch {}
            $exitCodeText = [string]$proc.ExitCode
            $hasResult = (-not [string]::IsNullOrWhiteSpace($state.ResultVersion)) -or (-not [string]::IsNullOrWhiteSpace($state.ResultInstallRoot))
            $isSuccess = [string]::IsNullOrWhiteSpace($state.ErrorMessage) -and (($proc.ExitCode -eq 0) -or ([string]::IsNullOrWhiteSpace($exitCodeText) -and $hasResult))
            if ($isSuccess) {
              Set-LatInstallerCompletedUi $window $state.ResultVersion $state.ResultInstallRoot $true ""
              [System.Windows.MessageBox]::Show("Install completed successfully.", "LAT Installer", "OK", "Information") | Out-Null
            } else {
              $displayExitCode = if ([string]::IsNullOrWhiteSpace($exitCodeText)) { "unknown" } else { $exitCodeText }
              $msg = if ([string]::IsNullOrWhiteSpace($state.ErrorMessage)) { "Installer worker failed with exit code $displayExitCode. See log: $workerLog" } else { $state.ErrorMessage }
              Add-LatInstallerGuiLog $logBox ("ERROR: " + $msg)
              Set-LatInstallerCompletedUi $window "" "" $false ("Installation failed: " + $msg)
              [System.Windows.MessageBox]::Show("Install failed: $msg", "LAT Installer", "OK", "Error") | Out-Null
            }
            try { Remove-Item -LiteralPath $workerStdOut -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item -LiteralPath $workerStdErr -Force -ErrorAction SilentlyContinue } catch {}
          }
        } catch {
          if ($null -ne $timer) {
            try { $timer.Stop() } catch {}
          }
          $msg = "GUI worker monitor failed: $($_.Exception.Message)"
          Add-LatInstallerGuiLog $logBox ("ERROR: " + $msg)
          Add-LatInstallerGuiLog $logBox (Format-ExceptionDetail $_)
          Set-LatInstallerCompletedUi $window "" "" $false ("Installation failed: " + $msg)
          [System.Windows.MessageBox]::Show($msg, "LAT Installer", "OK", "Error") | Out-Null
        }
  }.GetNewClosure())
      $timer.Start()
    } catch {
      Set-LatInstallerProgressState $progressBar 0 $false
      Set-LatInstallerStatus $statusText $logBox "Failed"
      Add-LatInstallerGuiLog $logBox ("ERROR: Install click handler failed: " + $_.Exception.Message)
      Add-LatInstallerGuiLog $logBox (Format-ExceptionDetail $_)
      Set-LatInstallerResult $resultText ("Installation failed: " + $_.Exception.Message) "error"
      Set-LatInstallerControlEnabled $installButton $true
      Set-LatInstallerControlEnabled $closeButton $true
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
Write-Info ("Session started at " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

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
