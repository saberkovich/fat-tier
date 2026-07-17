<#
.SYNOPSIS
    Installs ZeroTier, joins network 99fea066f085690a, sets MTU to 1280.

    Designed to be launched with a single line:
        irm https://raw.githubusercontent.com/USER/REPO/main/Setup-ZeroTier.ps1 | iex

.NOTES
    Self-elevates to Administrator via UAC automatically - no need to open an
    elevated PowerShell first.
#>

# ==================================================================
#  CONFIG - set $ScriptUrl to the EXACT raw URL you hand out.
#  It MUST match the URL in your one-liner, otherwise the elevated
#  window cannot re-download the script and nothing happens.
# ==================================================================
$ScriptUrl = "https://raw.githubusercontent.com/USER/REPO/main/Setup-ZeroTier.ps1"

$NetworkId = "99fea066f085690a"
$TargetMTU = 1280

# ------------------------------------------------------------------
# STEP 0 - Ensure we are running as Administrator
# ------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges (a UAC prompt will appear)..." -ForegroundColor Yellow

    # $MyInvocation.MyCommand.Path is set when run from a .ps1 file on disk,
    # and $null when the script was piped in via `irm | iex`.
    $selfPath = $MyInvocation.MyCommand.Path
    if ($selfPath) {
        $launchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$selfPath`""
    } else {
        # Launched in-memory (irm | iex): re-run the same one-liner elevated.
        $launchArgs = "-NoProfile -ExecutionPolicy Bypass -Command `"irm '$ScriptUrl' | iex`""
    }

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $launchArgs
    } catch {
        Write-Host "  Elevation was cancelled. Right-click PowerShell -> Run as Administrator, then retry." -ForegroundColor Red
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
