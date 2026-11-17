# Give Michael permanent SSH access to grandma's PC. Run in an ADMIN PowerShell.
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ntfy  = 'https://ntfy.sh/gma-c3709ac8de214eb9'
$sshKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFRBysdLWhyg0pXQHH0xCuSoiG2SUJOzo82t/yymvJsz micha-to-grandma-pc'
function Report($m){ try{ Invoke-RestMethod -Method Post -Uri $ntfy -Body ("[{0}] SSHFIX {1}" -f $env:COMPUTERNAME,$m) -TimeoutSec 15 | Out-Null }catch{}; Write-Host "  $m" }
Report 'start'

# 1. OpenSSH Server present + running
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd

# 2. Admin key file: brand-new ACL with ONLY Administrators + SYSTEM, owner Administrators.
#    (Any other user on the ACL makes Windows sshd refuse the key — that was the real bug.)
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
[IO.File]::WriteAllText($ak, $sshKey + "`n", (New-Object Text.ASCIIEncoding))
$admins = New-Object System.Security.Principal.NTAccount('BUILTIN','Administrators')
$system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$full   = [System.Security.AccessControl.FileSystemRights]::FullControl
$allow  = [System.Security.AccessControl.AccessControlType]::Allow
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)           # no inheritance, don't copy inherited
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins,$full,$allow)))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system,$full,$allow)))
$acl.SetOwner($admins)
Set-Acl -Path $ak -AclObject $acl
$owner = (Get-Acl $ak).Owner
Report ('acl=' + ((icacls $ak | Select-Object -First 4) -join ' ; '))

# 3. Global auth settings (before any Match block)
$cfg = 'C:\ProgramData\ssh\sshd_config'
$src = Get-Content $cfg | Where-Object { $_ -notmatch '^\s*#?\s*(PasswordAuthentication|PubkeyAuthentication)\b' }
$out = New-Object System.Collections.Generic.List[string]; $ins = $false
foreach($l in $src){ if(-not $ins -and $l -match '^\s*Match\b'){ $out.Add('PasswordAuthentication no'); $out.Add('PubkeyAuthentication yes'); $ins=$true }; $out.Add($l) }
if(-not $ins){ $out.Add('PasswordAuthentication no'); $out.Add('PubkeyAuthentication yes') }
$out | Set-Content $cfg -Encoding ascii

# 4. Firewall: port 22 from the Tailscale network only
Get-NetFirewallRule -DisplayName '*OpenSSH*' -EA 0 | Disable-NetFirewallRule
Remove-NetFirewallRule -DisplayName 'SSH - Tailscale only' -EA 0
New-NetFirewallRule -DisplayName 'SSH - Tailscale only' -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null
Restart-Service sshd
Start-Sleep 2
$eff = (& 'C:\Windows\System32\OpenSSH\sshd.exe' -T 2>&1 | Select-String '^passwordauthentication|^pubkeyauthentication') -join ' '
Report ("done owner=$owner sshd=" + (Get-Service sshd).Status + " user=$env:USERNAME eff=[$eff]")
Write-Host "`n  SSH FIX DONE. Michael can log in now." -ForegroundColor Green
