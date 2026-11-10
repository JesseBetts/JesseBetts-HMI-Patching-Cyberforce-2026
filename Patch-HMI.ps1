<#
.SYNOPSIS
    Remediates the vulnerabilities reported for the HMI host:
      - Windows Server 2019 Datacenter build 10.0.17763.8755 (May 2026 patch level)  -> 2,104 findings
      - Google Chrome 156.0.8078.82                                                   -> 24 findings

.DESCRIPTION
    Online mode  : installs all pending Windows updates via PSWindowsUpdate and
                   updates Chrome with Google's enterprise MSI.
    Offline mode : (-OfflinePath) installs .msu / .msi files you staged in a folder.
                   Use this when the HMI has no internet access (typical for OT networks).

    Nothing reboots unless you pass -AutoReboot.

.EXAMPLE
    # Dry run: show what is installed and what is missing, change nothing
    .\Patch-HMI.ps1 -ReportOnly

.EXAMPLE
    # Online patching, reboot yourself afterwards
    .\Patch-HMI.ps1

.EXAMPLE
    # Offline patching from a folder of .msu/.msi files
    .\Patch-HMI.ps1 -OfflinePath D:\patches

.NOTES
    Run from an elevated PowerShell (Run as administrator).
    TAKE A VM SNAPSHOT / IMAGE BACKUP FIRST, and confirm your HMI/SCADA vendor
    supports the update before running this on a production control system.
#>
[CmdletBinding()]
param(
    [switch]$ReportOnly,
    [switch]$SkipWindows,
    [switch]$SkipChrome,
    [switch]$AutoReboot,
    [string]$OfflinePath,
    [string]$LogDir = 'C:\Temp\HMI-Patch'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- helpers ----------------------------------------------------------
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OsBuild {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    "{0}.{1}" -f $cv.CurrentBuildNumber, $cv.UBR      # e.g. 17763.8755
}

function Get-ChromeVersion {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return (Get-Item $p).VersionInfo.ProductVersion }
    }
    return $null
}

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    $null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
}

function Test-Internet {
    try {
        $null = Invoke-WebRequest -Uri 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 8
        $true
    } catch { $false }
}

# Exit codes that mean success: 0 = ok, 3010 = ok but reboot needed,
# 2359302 (0x240006) = update already installed
function Test-InstallExit([int]$code) { $code -in 0, 3010, 2359302 }

# ---------- start ------------------------------------------------------------
if (-not (Test-Admin)) { throw 'Run this script from an elevated (administrator) PowerShell.' }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Start-Transcript -Path (Join-Path $LogDir "patch-$stamp.log") | Out-Null

$rebootNeeded = $false
try {
    $before = [pscustomobject]@{
        OS     = (Get-CimInstance Win32_OperatingSystem).Caption
        Build  = Get-OsBuild
        Chrome = Get-ChromeVersion
        FreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 1)
        PendingReboot = Test-PendingReboot
    }
    Write-Host "`n=== BEFORE ===" -ForegroundColor Cyan
    $before | Format-List

    if ($before.FreeGB -lt 10) { Write-Warning 'Less than 10 GB free on C: - cumulative updates may fail.' }
    if ($before.PendingReboot) { Write-Warning 'A reboot is already pending. Reboot first, then re-run for best results.' }

    if ($ReportOnly) {
        Write-Host 'ReportOnly set - no changes made.' -ForegroundColor Yellow
        return
    }

    $offline = [bool]$OfflinePath
    if (-not $offline -and -not (Test-Internet)) {
        throw 'No internet access. Stage the patches and re-run with -OfflinePath <folder> (see notes).'
    }

    # ---------- Windows ------------------------------------------------------
    if (-not $SkipWindows) {
        Write-Host "`n=== Windows Server 2019 updates ===" -ForegroundColor Cyan

        if ($offline) {
            # Install in file-name order: put the servicing stack update first
            # (e.g. name it 01-ssu.msu, 02-cumulative.msu).
            $msus = Get-ChildItem $OfflinePath -Filter *.msu | Sort-Object Name
            if (-not $msus) { Write-Warning "No .msu files found in $OfflinePath" }
            foreach ($m in $msus) {
                Write-Host "Installing $($m.Name) ..."
                $p = Start-Process wusa.exe -ArgumentList "`"$($m.FullName)`" /quiet /norestart" -Wait -PassThru
                if (-not (Test-InstallExit $p.ExitCode)) { Write-Warning "$($m.Name) exit code $($p.ExitCode)" }
                if ($p.ExitCode -eq 3010) { $rebootNeeded = $true }
            }
        }
        else {
            if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module PSWindowsUpdate -Force -Scope AllUsers
            }
            Import-Module PSWindowsUpdate

            $pending = Get-WindowsUpdate -MicrosoftUpdate -NotCategory 'Drivers'
            Write-Host "Pending updates: $(@($pending).Count)"
            $pending | Format-Table KB, Size, Title -AutoSize

            if ($pending) {
                Install-WindowsUpdate -MicrosoftUpdate -NotCategory 'Drivers' -AcceptAll -IgnoreReboot -Verbose
            }
            if (Get-WURebootStatus -Silent) { $rebootNeeded = $true }
        }
    }

    # ---------- Chrome -------------------------------------------------------
    if (-not $SkipChrome) {
        Write-Host "`n=== Google Chrome ===" -ForegroundColor Cyan
        $msi = $null

        if ($offline) {
            $msi = Get-ChildItem $OfflinePath -Filter '*chrome*.msi' | Select-Object -First 1 -ExpandProperty FullName
            if (-not $msi) { Write-Warning "No Chrome .msi found in $OfflinePath - skipping Chrome." }
        }
        else {
            $msi = Join-Path $env:TEMP 'googlechromestandaloneenterprise64.msi'
            Invoke-WebRequest -UseBasicParsing -OutFile $msi `
                -Uri 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
        }

        if ($msi) {
            if (Get-Process chrome -ErrorAction SilentlyContinue) {
                Write-Warning 'Chrome is running. The update is applied now, but running windows keep the old version until Chrome is restarted.'
            }
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
            if (-not (Test-InstallExit $p.ExitCode)) { Write-Warning "Chrome MSI exit code $($p.ExitCode)" }
            if ($p.ExitCode -eq 3010) { $rebootNeeded = $true }
        }
    }

    # ---------- After --------------------------------------------------------
    $after = [pscustomobject]@{
        Build         = Get-OsBuild
        Chrome        = Get-ChromeVersion
        PendingReboot = ((Test-PendingReboot) -or $rebootNeeded)
    }
    Write-Host "`n=== AFTER ===" -ForegroundColor Cyan
    $after | Format-List

    if ($after.PendingReboot) {
        if ($AutoReboot) {
            Write-Host 'Rebooting in 60 seconds...' -ForegroundColor Yellow
            shutdown.exe /r /t 60 /c 'HMI patching complete - restarting'
        } else {
            Write-Host 'REBOOT REQUIRED. The new build will not show (and findings will not clear) until you reboot.' -ForegroundColor Yellow
        }
    }
    Write-Host "`nLog saved to $LogDir. After rebooting, run this script with -ReportOnly to confirm the build, then rescan." -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}