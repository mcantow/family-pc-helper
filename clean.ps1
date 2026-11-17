# Grandma's PC cleanup — run in an ADMINISTRATOR PowerShell.
# Removes Wave Browser + junk programs, clears scam browser-notification spam,
# and runs AdwCleaner + a Defender scan. Reports each step to the private page.
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ntfy = 'https://ntfy.sh/gma-c3709ac8de214eb9'
function Report($m){ try{ Invoke-RestMethod -Method Post -Uri $ntfy -Body ("[{0}] {1}" -f $env:COMPUTERNAME,$m) -TimeoutSec 15 | Out-Null }catch{}; Write-Host "  $m" }
$dl = Join-Path $env:TEMP ('cl-' + [guid]::NewGuid().ToString('N').Substring(0,8)); New-Item -ItemType Directory -Force $dl | Out-Null
Report 'CLEANUP started'

# --- 1. Close the browsers and Wave so we can clean them --------------------
'chrome','msedge','wavebrowser','wave','SWUpdater','WebDiscover','brave' | ForEach-Object { Get-Process -Name $_ -EA 0 | Stop-Process -Force -EA 0 }
Start-Sleep 2
Report 'browsers closed'

# --- 2. Kill Wave Browser persistence, then uninstall -----------------------
Get-ScheduledTask | Where-Object { $_.TaskName -match 'Wave|Wavesor|SWUpdater|WebDiscover|BrowserAssistant' } | Unregister-ScheduledTask -Confirm:$false
foreach($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'){
  (Get-Item $rk -EA 0).Property | Where-Object { $_ -match 'Wave|Wavesor|SWUpdater|WebDiscover' } | ForEach-Object { Remove-ItemProperty $rk $_ -EA 0 }
}
# run Wave's own uninstaller if present
Get-ChildItem "$env:LOCALAPPDATA\WaveBrowser\*\Installer\setup.exe" -EA 0 | Sort-Object FullName -Descending | Select-Object -First 1 | ForEach-Object {
  Start-Process $_.FullName -ArgumentList '--uninstall --force-uninstall --system-level' -Wait
}
# remove leftover folders
'WaveBrowser','Wavesor','WebDiscover' | ForEach-Object { Remove-Item "$env:LOCALAPPDATA\$_" -Recurse -Force -EA 0; Remove-Item "$env:APPDATA\$_" -Recurse -Force -EA 0 }
Report ('Wave Browser removed: ' + (-not (Test-Path "$env:LOCALAPPDATA\WaveBrowser")))

# --- 3. Clear scam notification permissions in Chrome & Edge ----------------
foreach($root in "$env:LOCALAPPDATA\Google\Chrome\User Data","$env:LOCALAPPDATA\Microsoft\Edge\User Data"){
  if(-not (Test-Path $root)){ continue }
  Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Preferences') } | ForEach-Object {
    $pf = Join-Path $_.FullName 'Preferences'
    try{
      $j = Get-Content $pf -Raw | ConvertFrom-Json
      if($j.profile.content_settings.exceptions.notifications){
        $j.profile.content_settings.exceptions.notifications = (New-Object psobject)   # wipe all site notification grants
        ($j | ConvertTo-Json -Depth 50 -Compress) | Set-Content $pf -Encoding utf8
      }
    }catch{}
  }
}
Report 'cleared browser notification permissions'

# --- 4. AdwCleaner: removes Wave remnants, PUPs, resets browser hijacks ------
try{
  Invoke-WebRequest 'https://downloads.malwarebytes.com/file/adwcleaner' -OutFile "$dl\adw.exe" -UseBasicParsing
  Start-Process "$dl\adw.exe" -ArgumentList '/eula /clean /noreboot' -Wait
  $log = Get-ChildItem 'C:\AdwCleaner\Logs' -Filter '*.txt' -EA 0 | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $n = if($log){ (Select-String -Path $log.FullName -Pattern 'Deleted' | Measure-Object).Count } else { 0 }
  Report "AdwCleaner done, $n items removed"
}catch{ Report "AdwCleaner failed: $($_.Exception.Message)" }

# --- 5. Defender quick scan -------------------------------------------------
Update-MpSignature -EA 0
Start-MpScan -ScanType QuickScan -EA 0
Report 'Defender quick scan done'

Report 'CLEANUP ALL DONE'
Write-Host "`n  CLEANUP DONE. Restart her browser; the pop-ups should be gone." -ForegroundColor Green
