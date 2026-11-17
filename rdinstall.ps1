# Install RustDesk (needs elevation). Sets a fixed password from $env:RDPW, reports the ID.
$ErrorActionPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ntfy = 'https://ntfy.sh/gma-c3709ac8de214eb9'
function Report($m){ try{ Invoke-RestMethod -Method Post -Uri $ntfy -Body ("[{0}] RDINSTALL {1}" -f $env:COMPUTERNAME,$m) -TimeoutSec 15 | Out-Null }catch{}; Write-Host $m }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Report "start admin=$admin"
if(-not $admin){ Report 'NOT ELEVATED - abort'; return }
$dl = Join-Path $env:TEMP ('rd-'+[guid]::NewGuid().ToString('N').Substring(0,8)); New-Item -ItemType Directory -Force $dl | Out-Null
try{
  $rel = Invoke-RestMethod 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest' -UseBasicParsing
  $asset = $rel.assets | ? { $_.name -match 'x86_64\.exe$' -and $_.name -notmatch 'sciter' } | Select-Object -First 1
  Invoke-WebRequest $asset.browser_download_url -OutFile "$dl\rd.exe" -UseBasicParsing
  Start-Process "$dl\rd.exe" -ArgumentList '--silent-install' -Wait
  $rd = 'C:\Program Files\RustDesk\rustdesk.exe'
  $deadline=(Get-Date).AddSeconds(150); while(-not(Test-Path $rd) -and (Get-Date) -lt $deadline){ Start-Sleep 3 }
  if(-not(Test-Path $rd)){ Report 'rustdesk.exe missing after install'; return }
  $deadline=(Get-Date).AddSeconds(60); while((Get-Service RustDesk -EA 0).Status -ne 'Running' -and (Get-Date) -lt $deadline){ Start-Sleep 3 }
  Start-Sleep 5
  $pw = $env:RDPW; if(-not $pw){ $pw = 'Gma-'+([guid]::NewGuid().ToString('N').Substring(0,12)) }
  Start-Process $rd -ArgumentList '--password', $pw -Wait -WindowStyle Hidden
  $id=''
  for($i=0;$i -lt 20 -and -not $id;$i++){ Start-Process $rd -ArgumentList '--get-id' -Wait -WindowStyle Hidden -RedirectStandardOutput "$dl\id.txt"; $id=((Get-Content "$dl\id.txt" -EA 0)|Out-String).Trim(); if(-not $id){ Start-Sleep 3 } }
  $secrets='C:\ProgramData\family-helper'; New-Item -ItemType Directory -Force $secrets | Out-Null
  "id=$id`npassword=$pw" | Set-Content "$secrets\rustdesk.txt" -Encoding ascii
  Report "DONE id=$id svc=$((Get-Service RustDesk -EA 0).Status)"
}catch{ Report ("FAIL: " + $_.Exception.Message) }
