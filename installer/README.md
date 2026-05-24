# LAT Agent Windows Installer

Canonical installer script: `installer/windows/install-lat-agent.ps1`

## End-user command (GUI installer)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm 'https://raw.githubusercontent.com/Synclab-VN/lpm-release/main/install.ps1')"
```

Default behavior:
- Open WPF installer window with progress bar.
- Let user configure install options before running.
- Create Desktop shortcut `LAT.lnk`.
- Enable startup + crash auto-restart via Scheduled Task (`LAT Agent`).
- Start LAT Agent after install.
- Write installer log to `%TEMP%\\lat-installer.log`.

## Silent mode (no GUI)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Synclab-VN/lpm-release/main/install.ps1'))) -Silent"
```

## Optional parameters

```powershell
# Install specific tag
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Synclab-VN/lpm-release/main/install.ps1'))) -Tag v1.0.8"

# Custom install directory
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Synclab-VN/lpm-release/main/install.ps1'))) -InstallDir 'D:\Apps\LAT-Agent'"

# Install only (no desktop shortcut, no auto-start now, no startup task)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Synclab-VN/lpm-release/main/install.ps1'))) -NoDesktopShortcut -NoStart -NoAutoStart"
```

## Sync workflow

Use workflow `Sync Repo Path` with:
- `source_repo=Synclab-VN/lpm`
- `source_branch=main`
- `source_path=installer/windows/install-lat-agent.ps1`
- `target_repo=Synclab-VN/lpm-release`
- `target_branch=main`
- `target_path=install.ps1`
