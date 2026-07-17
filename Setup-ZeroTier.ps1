<#
.SYNOPSIS
    Installs ZeroTier, joins network 99fea066f085690a, sets MTU to 1280.

    Designed to be launched with a single line:
        irm https://raw.githubusercontent.com/saberkovich/fat-tier/main/Setup-ZeroTier.ps1 | iex

.NOTES
    Self-elevates to Administrator via UAC automatically - no need to open an
    elevated PowerShell first.
#>

# ==================================================================
#  CONFIG - $ScriptUrl MUST be the EXACT raw URL you distribute
#  (the same URL as in your one-liner). It is used to re-fetch the
#  script for the elevated (admin) run, because a script piped through
#  `iex` cannot recover its own text.
# ==================================================================
$ScriptUrl = "https://raw.githubusercontent.com/saberkovich/fat-tier/main/Setup-ZeroTier.ps1"

$NetworkId = "99fea066f085690a"
$TargetMTU = 1280

# ------------------------------------------------------------------
# STEP 0 - Ensure we are running as Administrator (self-elevate)
# ------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    # $MyInvocation.MyCommand.Path is set when run from a .ps1 file on disk,
    # and $null when the script was piped in via `irm | iex`.
    $selfPath = $MyInvocation.MyCommand.Path

    if ($selfPath) {
        # Real file on disk (e.g. launched from Run-ZeroTier.bat): relaunch it elevated.
        Write-Host "Requesting administrator privileges (a UAC prompt will appear)..." -ForegroundColor Yellow
        Start-Process powershell.exe -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`""
        return
    }

    # In-memory (irm | iex): download the script ONCE here in this visible window
    # (so any error is readable), then hand it to the elevated process via a temp
    # file. The admin window then needs no network access at all.
    if ($ScriptUrl -match 'USER/REPO') {
        Write-Host "[ERROR] `$ScriptUrl is still the placeholder 'USER/REPO'." -ForegroundColor Red
        Write-Host "        Set it to your real raw URL and re-upload the script to GitHub." -ForegroundColor Yellow
        return
    }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    Write-Host "Downloading script for the elevated run..." -ForegroundColor Yellow
    try {
        $code = Invoke-RestMethod -Uri $ScriptUrl -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Could not download the script from:" -ForegroundColor Red
        Write-Host "        $ScriptUrl" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Check that `$ScriptUrl matches your one-liner and the repo is public." -ForegroundColor Yellow
        return
    }

    $tmp = Join-Path $env:TEMP ("Setup-ZeroTier_{0}.ps1" -f [guid]::NewGuid())
    Set-Content -LiteralPath $tmp -Value $code -Encoding UTF8

    Write-Host "Requesting administrator privileges (a UAC prompt will appear)..." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
    } catch {
        Write-Host "Elevation was cancelled. Run PowerShell as Administrator and retry." -ForegroundColor Red
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return
}

# ==================================================================
#  From here on we are guaranteed to be elevated.
#  Everything is wrapped so the window stays open on success OR error.
# ==================================================================
try {
    Write-Host "=== ZeroTier Setup Script ===" -ForegroundColor Cyan

    # --------------------------------------------------------------
    # STEP 1 - Check / install ZeroTier
    # --------------------------------------------------------------
    Write-Host "`n[1/3] Checking ZeroTier installation..." -ForegroundColor Yellow

    $ztInstalled = $false
    try {
        $ztVersion = & zerotier-cli -v 2>&1
        if ($ztVersion -match '\d+\.\d+\.\d+') {
            Write-Host "  ZeroTier already installed: $ztVersion" -ForegroundColor Green
            $ztInstalled = $true
        }
    } catch {
        $ztInstalled = $false
    }

    if (-not $ztInstalled) {
        Write-Host "  ZeroTier not found. Installing via winget..." -ForegroundColor Yellow
        winget install --id=ZeroTier.ZeroTierOne -e `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [ERROR] winget exited with code $LASTEXITCODE" -ForegroundColor Red
            return
        }
        Write-Host "  ZeroTier installed." -ForegroundColor Green

        # Refresh PATH without restarting the session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("Path","User")

        # Wait for the service to start
        Write-Host "  Waiting for ZeroTierOneService to start..." -ForegroundColor Yellow
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            $svc = Get-Service "ZeroTierOneService" -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Write-Host "  Service is running." -ForegroundColor Green; break
            }
            Start-Sleep -Seconds 2
        }
    }

    # --------------------------------------------------------------
    # STEP 2 - Join the network
    # --------------------------------------------------------------
    Write-Host "`n[2/3] Joining network $NetworkId..." -ForegroundColor Yellow

    $joinOut = & zerotier-cli join $NetworkId 2>&1
    Write-Host "  zerotier-cli: $joinOut"

    $networks = & zerotier-cli listnetworks 2>&1
    if ($networks -match $NetworkId) {
        Write-Host "  Network $NetworkId is listed." -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] Network not found in listnetworks." -ForegroundColor Yellow
        Write-Host "  Device authorization on my.zerotier.com may be required." -ForegroundColor Yellow
    }

    # --------------------------------------------------------------
    # STEP 3 - Wait for adapter and set MTU
    # --------------------------------------------------------------
    Write-Host "`n[3/3] Waiting for ZeroTier network adapter..." -ForegroundColor Yellow

    $adapter  = $null
    $deadline = (Get-Date).AddSeconds(90)

    while ((Get-Date) -lt $deadline) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.InterfaceDescription -like "*ZeroTier*" } |
                   Select-Object -First 1
        if ($adapter) { break }
        Write-Host "  Adapter not found, retrying in 3s..." -ForegroundColor Gray
        Start-Sleep -Seconds 3
    }

    if (-not $adapter) {
        Write-Host "  [ERROR] ZeroTier adapter did not appear within 90s." -ForegroundColor Red
        Write-Host "  Authorize the device on my.zerotier.com and try again." -ForegroundColor Yellow
        return
    }

    Write-Host "  Adapter found: '$($adapter.Name)'" -ForegroundColor Green
    Write-Host "  Setting MTU = $TargetMTU..." -ForegroundColor Yellow

    netsh interface ipv4 set subinterface "$($adapter.Name)" mtu=$TargetMTU store=persistent | Out-Null
    netsh interface ipv6 set subinterface "$($adapter.Name)" mtu=$TargetMTU store=persistent 2>$null | Out-Null

    # Verify via PowerShell (no localized headers)
    $iface = Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $mtuActual = if ($iface) { $iface.NlMtu } else { "unknown" }

    Write-Host "`n  Verification:" -ForegroundColor Cyan
    Write-Host "    Adapter : $($adapter.Name)"
    Write-Host "    MTU     : $mtuActual"

    Write-Host "`n=== Done ===" -ForegroundColor Cyan
    Write-Host "  Network : $NetworkId"
    Write-Host "  Adapter : $($adapter.Name)"
    Write-Host "  MTU     : $TargetMTU"
}
finally {
    # Keep the elevated window open so the user can read the result / errors.
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host "`nPress Enter to close this window..." -ForegroundColor DarkGray
        try { Read-Host | Out-Null } catch {}
    }
}
