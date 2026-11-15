# family-pc-helper setup — run by Michael-Helper.exe (already elevated).
# Access only, no cleanup. Order = most important first, each step independent:
#   1. Tailscale (join Michael's network as grandma-pc)  <- the one that matters
#   2. RustDesk (screen access; password saved on this PC)
#   3. SSH (Tailscale-only, key-only)
#   4. No sleep on power, restore point
# Progress goes to a private ntfy topic; secrets stay on this PC.
# $dry = $true      -> rehearsal: no installs or system changes.
# $env:FH_TEST = 1  -> CI test: real installs, but stop once Tailscale asks for approval.

$ntfy    = 'https://ntfy.sh/gma-c3709ac8de214eb9'
$keyUrl  = 'https://gist.githubusercontent.com/mcantow/79bb2da4a8d7871c931bd90da6887bbb/raw/key.txt'     # secret gist holding a one-time Tailscale auth key (may say "none")
$sshKey  = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFRBysdLWhyg0pXQHH0xCuSoiG2SUJOzo82t/yymvJsz micha-to-grandma-pc'
$secrets = 'C:\ProgramData\family-helper'
$ts      = 'C:\Program Files\Tailscale\tailscale.exe'
$test    = ($env:FH_TEST -eq '1')
if ($test) { $ntfy += '-test' }   # keep test runs off grandma's progress page
if (-not (Get-Variable dry -ErrorAction SilentlyContinue)) { $dry = $false }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # makes downloads much faster on PowerShell 5.1

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
function Download($url, $out) {
    for ($i = 1; $i -le 3; $i++) {
        try { Invoke-WebRequest $url -OutFile $out -UseBasicParsing -TimeoutSec 300; if ((Get-Item $out).Length -gt 0) { return } }
        catch { if ($i -eq 3) { throw } ; Start-Sleep 5 }
    }
}

Write-Host "`n  Michael's helper is setting up your computer. Please leave this window open.`n" -ForegroundColor Yellow
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os = (Get-CimInstance Win32_OperatingSystem).Caption
$av = (Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object displayName) -join ', '
Report ("started admin={0} dry={1} test={2} os={3} user={4} av={5}" -f $isAdmin, $dry, $test, $os, $env:USERNAME, $av)
# If launched from a normal PowerShell (irm ... | iex), re-launch elevated. Grandma clicks Yes.
if (-not $isAdmin -and -not $dry -and -not $test) {
    $selfUrl = 'https://raw.githubusercontent.com/mcantow/family-pc-helper/main/setup.ps1'
    Report 'asking for admin (grandma: click YES on the blue box)'
    $inner = "irm '$selfUrl' -UseBasicParsing | iex"
    try {
        Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$inner)
        Write-Host "`n  A blue box will ask permission - click YES. This window can close.`n" -ForegroundColor Yellow
    } catch { Report 'FAIL: admin prompt was declined' }
    return
}

$dl = Join-Path $env:TEMP ('fh-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $dl | Out-Null
if (-not $dry) {
    New-Item -ItemType Directory -Force $secrets | Out-Null
    icacls $secrets /inheritance:r /grant 'Administrators:(OI)(CI)F' /grant 'SYSTEM:(OI)(CI)F' | Out-Null
}

# ---- 1. Tailscale: install and start joining (approval may come later) --------
$authKey = ''
Step 'Tailscale install' {
    if ($keyUrl -like 'http*') { try { $script:authKey = ((Invoke-WebRequest $keyUrl -UseBasicParsing -TimeoutSec 20).Content).Trim() } catch {} }
    if ($script:authKey -notlike 'tskey-*') { $script:authKey = '' }
    $u = 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi'
    if ($dry) { $h = Invoke-WebRequest $u -Method Head -UseBasicParsing; return "dry: installer $($h.StatusCode), auth key=$([bool]$script:authKey)" }
    if (-not (Test-Path $ts)) {
        Download $u "$dl\tailscale.msi"
        $p = Start-Process msiexec -ArgumentList "/i `"$dl\tailscale.msi`" /qn /norestart TS_UNATTENDEDMODE=always TS_NOLAUNCH=true" -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec exit $($p.ExitCode)" }
    }
    if (-not (Test-Path $ts)) { throw 'tailscale.exe missing after install' }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Service Tailscale -ErrorAction SilentlyContinue).Status -ne 'Running' -and (Get-Date) -lt $deadline) {
        Start-Service Tailscale -ErrorAction SilentlyContinue; Start-Sleep 3 }
    if ((Get-Service Tailscale).Status -ne 'Running') { throw 'Tailscale service not running' }
    Start-Sleep 3
    $upArgs = @('up', '--unattended', '--hostname=grandma-pc', '--reset')
    if ($script:authKey) { $upArgs += "--auth-key=$($script:authKey)" }
    Start-Process $ts -ArgumentList $upArgs -WindowStyle Hidden
    "installed, joining with " + $(if ($script:authKey) { 'one-time key' } else { 'approval link' })
}

function TsState { try { & $ts status --json 2>$null | ConvertFrom-Json } catch { $null } }
$approvalSent = $false
function CheckJoin {
    if ($dry -or -not (Test-Path $ts)) { return $false }
    $st = TsState
    if ($st.BackendState -eq 'Running') { return $true }
    if ($st.AuthURL -and -not $script:approvalSent) {
        Report "APPROVE grandma-pc: open $($st.AuthURL) and sign in"
        $script:approvalSent = $true
    }
    return $false
}
# give it a moment to produce the approval link, so Michael gets it early
for ($i = 0; $i -lt 12 -and -not (CheckJoin) -and -not $approvalSent; $i++) { Start-Sleep 5 }

# ---- 2. RustDesk for screen access over Tailscale (password kept on this PC) ---
Step 'RustDesk' {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
    $asset = $rel.assets | Where-Object { $_.name -match 'x86_64\.exe$' -and $_.name -notmatch 'sciter' } | Select-Object -First 1
    if (-not $asset) { throw 'no x86_64 exe in latest release' }
    if ($dry) { return "dry: would install $($asset.name)" }
    Download $asset.browser_download_url "$dl\rustdesk.exe"
    $rd = 'C:\Program Files\RustDesk\rustdesk.exe'
    if (-not (Test-Path $rd)) { Start-Process "$dl\rustdesk.exe" -ArgumentList '--silent-install' }
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-Path $rd) -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
    if (-not (Test-Path $rd)) { throw 'rustdesk.exe missing after install' }
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Service RustDesk -ErrorAction SilentlyContinue).Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
    Start-Sleep 5
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
    $pw = -join (1..16 | ForEach-Object { $chars | Get-Random })
    # rustdesk.exe is a GUI program: run it to completion and capture output via files
    Start-Process $rd -ArgumentList '--password', $pw -Wait -WindowStyle Hidden
    $id = ''
    for ($i = 0; $i -lt 20 -and -not $id; $i++) {
        Start-Process $rd -ArgumentList '--get-id' -Wait -WindowStyle Hidden -RedirectStandardOutput "$dl\rdid.txt"
        $id = ((Get-Content "$dl\rdid.txt" -ErrorAction SilentlyContinue) | Out-String).Trim()
        if (-not $id) { Start-Sleep 3 }
    }
    "id=$id`npassword=$pw" | Set-Content "$secrets\rustdesk.txt" -Encoding ascii
    "installed, id=$id (password saved on the PC)"
}
$null = CheckJoin

# ---- 3. SSH, reachable only over Tailscale, key-only (time-limited) ------------
Step 'SSH' {
    if ($dry) { return 'skipped (dry)' }
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        $job = Start-Job { $c = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
                           if ($c.State -ne 'Installed') { Add-WindowsCapability -Online -Name $c.Name | Out-Null } }
        if (-not (Wait-Job $job -Timeout 900)) { Stop-Job $job; throw 'OpenSSH install timed out (15 min)' }
        Receive-Job $job -ErrorAction Stop | Out-Null
    }
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
$null = CheckJoin

# ---- 4. Stay reachable + undo point -----------------------------------------
Step 'No sleep on power' {
    if ($dry) { return 'skipped (dry)' }
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /change hibernate-timeout-ac 0 | Out-Null
}
Step 'Restore point' {
    if ($dry) { return 'skipped (dry)' }
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description 'Michael remote setup' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
}

# ---- 5. Wait for the Tailscale join ------------------------------------------
Step 'Tailscale join' {
    if ($dry) { return 'skipped (dry)' }
    if ($test) { $st = TsState; return "test stop: state=$($st.BackendState) approvalLink=$([bool]$st.AuthURL)" }
    Write-Host "`n  Almost done - waiting for Michael. Keep this window open.`n" -ForegroundColor Yellow
    $deadline = (Get-Date).AddHours(3); $nudge = (Get-Date).AddMinutes(10)
    while (-not (CheckJoin) -and (Get-Date) -lt $deadline) {
        if ((Get-Date) -gt $nudge) { $script:approvalSent = $false; $nudge = (Get-Date).AddMinutes(10) }  # re-send the link
        Start-Sleep 5
    }
    $ip = (& $ts ip -4 2>$null | Select-Object -First 1)
    if (-not $ip) { throw 'not approved yet; her PC keeps waiting and joins once approved' }
    "JOINED as grandma-pc, ip=$ip"
}

Report 'ALL DONE'
Write-Host "`n  ALL DONE. Michael can reach your computer now. You can close this window." -ForegroundColor Green
if (-not $dry -and -not $test) { Read-Host 'Press Enter to close' }
