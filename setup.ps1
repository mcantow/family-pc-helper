# family-pc-helper setup — run by GrandmaHelper.exe (already elevated).
# Joins this PC to Michael's Tailscale network, turns on SSH (Tailscale-only, key-only),
# installs RustDesk for screen access over Tailscale, keeps the PC awake on power.
# Access only, no cleanup. Progress goes to a private ntfy topic; secrets stay on this PC.
# $dry = $true -> rehearsal: no installs or system changes.

$ntfy    = 'https://ntfy.sh/gma-c3709ac8de214eb9'
$keyUrl  = 'https://gist.githubusercontent.com/mcantow/79bb2da4a8d7871c931bd90da6887bbb/raw/key.txt'     # secret gist holding a one-time Tailscale auth key (may be empty)
$sshKey  = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFRBysdLWhyg0pXQHH0xCuSoiG2SUJOzo82t/yymvJsz micha-to-grandma-pc'
$secrets = 'C:\ProgramData\family-helper'
if (-not (Get-Variable dry -ErrorAction SilentlyContinue)) { $dry = $false }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Report($msg) {
    try { Invoke-RestMethod -Method Post -Uri $ntfy -Body ("[{0}] {1}" -f $env:COMPUTERNAME, $msg) -TimeoutSec 15 | Out-Null } catch {}
    Write-Host "  $msg"
}
$results = [ordered]@{}
function Step($name, [scriptblock]$body) {
    Write-Host "`n==> $name" -ForegroundColor Cyan
    try { $r = & $body; $results[$name] = if ($r) { "$r" } else { 'OK' } }
    catch { $results[$name] = "FAIL: $($_.Exception.Message)" }
    Report ("{0}: {1}" -f $name, $results[$name])
}

Write-Host "`n  Michael's helper is setting up your computer. Please leave this window open.`n" -ForegroundColor Yellow
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os = (Get-CimInstance Win32_OperatingSystem).Caption
Report ("started admin={0} dry={1} os={2} user={3}" -f $isAdmin, $dry, $os, $env:USERNAME)
if (-not $isAdmin -and -not $dry) { Report 'FAIL: not running as administrator'; Read-Host 'Press Enter to close'; return }

$dl = Join-Path $env:TEMP ('fh-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $dl | Out-Null
if (-not $dry) {
    New-Item -ItemType Directory -Force $secrets | Out-Null
    icacls $secrets /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null
}

# ---- 1. Restore point --------------------------------------------------------
Step 'Restore point' {
    if ($dry) { return 'skipped (dry)' }
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description 'Before Michael remote setup' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
}

# ---- 2. SSH, reachable only over Tailscale, key-only ---------------------------
Step 'SSH' {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($dry) { return "dry: $($cap.Name) state=$($cap.State)" }
    if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
    $sshKey | Set-Content $ak -Encoding ascii
    icacls $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
    $cfg = 'C:\ProgramData\ssh\sshd_config'
    $lines = Get-Content $cfg | Where-Object { $_ -notmatch '^\s*#?\s*(PasswordAuthentication|PubkeyAuthentication)\b' }
    ($lines + 'PasswordAuthentication no' + 'PubkeyAuthentication yes') | Set-Content $cfg -Encoding ascii
    Get-NetFirewallRule -DisplayName '*OpenSSH*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
    Remove-NetFirewallRule -DisplayName 'SSH - Tailscale only' -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'SSH - Tailscale only' -Direction Inbound -Protocol TCP -LocalPort 22 `
        -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null
    Restart-Service sshd
    "on, login user=$env:USERNAME"
}

# ---- 3. RustDesk for screen access over Tailscale (password kept on this PC) ---
Step 'RustDesk' {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
    $asset = $rel.assets | Where-Object { $_.name -match 'x86_64\.exe$' -and $_.name -notmatch 'sciter' } | Select-Object -First 1
    if (-not $asset) { throw 'no x86_64 exe in latest release' }
    if ($dry) { return "dry: would install $($asset.name)" }
    Invoke-WebRequest $asset.browser_download_url -OutFile "$dl\rustdesk.exe" -UseBasicParsing
    Start-Process "$dl\rustdesk.exe" -ArgumentList '--silent-install' -Wait
    $rd = 'C:\Program Files\RustDesk\rustdesk.exe'
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path $rd) -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
    if (-not (Test-Path $rd)) { throw 'rustdesk.exe missing after install' }
    Start-Sleep 5
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $pw = -join (1..16 | ForEach-Object { $chars | Get-Random })
    & $rd --password $pw | Out-Null
    $id = (& $rd --get-id | Out-String).Trim()
    "id=$id`npassword=$pw" | Set-Content "$secrets\rustdesk.txt" -Encoding ascii
    "installed, id=$id (password saved on the PC)"
}

# ---- 4. Stay reachable: no sleep on power -----------------------------------
Step 'No sleep on power' {
    if ($dry) { return 'skipped (dry)' }
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
}

# ---- 5. Tailscale (last network change, so nothing above is lost if it hiccups) --
Step 'Tailscale' {
    $u = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
    $k = ''
    if ($keyUrl -like 'http*') { try { $k = ((Invoke-WebRequest $keyUrl -UseBasicParsing -TimeoutSec 20).Content).Trim() } catch {} }
    if ($k -notlike 'tskey-*') { $k = '' }
    if ($dry) { $h = Invoke-WebRequest $u -Method Head -UseBasicParsing; return "dry: installer $($h.StatusCode), auth key found=$([bool]$k)" }
    Invoke-WebRequest $u -OutFile "$dl\tailscale.msi" -UseBasicParsing
    Start-Process msiexec -ArgumentList "/i `"$dl\tailscale.msi`" /qn TS_UNATTENDEDMODE=always TS_NOLAUNCH=true" -Wait
    $ts = 'C:\Program Files\Tailscale\tailscale.exe'
    if (-not (Test-Path $ts)) { throw 'tailscale.exe missing after install' }
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Service Tailscale -ErrorAction SilentlyContinue).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
    Start-Sleep 3
    if ($k) {
        & $ts up "--auth-key=$k" --unattended --hostname=grandma-pc --timeout=120s 2>&1 | Out-Null
    } else {
        # No key: ask for a sign-in link and send it to Michael to approve from his phone.
        Start-Process $ts -ArgumentList 'up','--unattended','--hostname=grandma-pc' -WindowStyle Hidden
        $sent = $false; $deadline = (Get-Date).AddMinutes(60)
        while ((Get-Date) -lt $deadline) {
            $st = & $ts status --json 2>$null | ConvertFrom-Json
            if ($st.BackendState -eq 'Running') { break }
            if ($st.AuthURL -and -not $sent) { Report "APPROVE: open $($st.AuthURL) and sign in to add grandma-pc"; $sent = $true
                Write-Host "`n  Waiting for Michael to approve. Keep this window open.`n" -ForegroundColor Yellow }
            Start-Sleep 5
        }
    }
    $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
    if (-not $ip) { throw 'not joined' }
    "joined as grandma-pc, ip=$ip"
}

# Access only. Nothing is cleaned here: once Michael is in over SSH, he looks first
# (read-only check) and removes only what the check finds.

Report 'ALL DONE'
Write-Host "`n  ALL DONE. Michael can reach your computer now. You can close this window." -ForegroundColor Green
if (-not $dry) { Read-Host 'Press Enter to close' }
