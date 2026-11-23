<#
  Install our agent on a cyber's Windows computer, once, as an Administrator (PowerShell):

    .\install.ps1 -Code ABCD-EFGH -Platform https://<platform> `
      -AgentUrl <release>/weaverbird-agent-windows-amd64.exe -AgentSha256 <sha256> `
      -SumatraUrl <SumatraPDF portable 64-bit .exe> -SumatraSha256 <sha256>

  It puts the agent (checked against its sha256) and SumatraPDF (checked too; it prints PDFs and photos with the
  printer's own driver) in %ProgramFiles%\Weaverbird, keeps the agent's state in %ProgramData%\weaverbird-agent
  readable by Administrators and the signed-in user only, enrols it with the one-time code from the cyber's Printers
  page, and starts it at every sign-in of this user (printers installed for the user are visible to it). Nothing here
  runs anything a caller typed: the agent only does the fixed, signed verbs.

  Network printers can be added after: & "$env:ProgramFiles\Weaverbird\weaverbird-agent.exe" printer add Front ipp://192.168.1.50/ipp/print
#>
param(
  [Parameter(Mandatory = $true)][string]$Code,
  [Parameter(Mandatory = $true)][string]$Platform,
  [string]$Api = "/api/plugins/kijicyber/agent/v1",
  [Parameter(Mandatory = $true)][string]$AgentUrl,
  [Parameter(Mandatory = $true)][string]$AgentSha256,
  [Parameter(Mandatory = $true)][string]$SumatraUrl,
  [Parameter(Mandatory = $true)][string]$SumatraSha256
)
$ErrorActionPreference = "Stop"

$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Run PowerShell as Administrator." }
if (-not $Platform.StartsWith("https://")) { throw "-Platform must be https://" }
foreach ($u in @($AgentUrl, $SumatraUrl)) { if (-not $u.StartsWith("https://")) { throw "Downloads come over https only: $u" } }
if (-not [Environment]::Is64BitOperatingSystem) { throw "A 64-bit Windows is needed." }

$dir = Join-Path $env:ProgramFiles "Weaverbird"
$state = Join-Path $env:ProgramData "weaverbird-agent"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wb-install-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $dir, $state, $tmp | Out-Null

function Get-Checked([string]$url, [string]$sha, [string]$out) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out
  $got = (Get-FileHash -Algorithm SHA256 -Path $out).Hash.ToLower()
  if ($got -ne $sha.ToLower()) { Remove-Item $out -Force; throw "$url did not match its sha256: not installed" }
}

try {
  Get-Checked $AgentUrl $AgentSha256 (Join-Path $tmp "weaverbird-agent.exe")
  Get-Checked $SumatraUrl $SumatraSha256 (Join-Path $tmp "SumatraPDF.exe")
  Copy-Item -Force (Join-Path $tmp "weaverbird-agent.exe") (Join-Path $dir "weaverbird-agent.exe")
  Copy-Item -Force (Join-Path $tmp "SumatraPDF.exe") (Join-Path $dir "SumatraPDF.exe")
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# The state folder (its keys) for Administrators, SYSTEM and this user only.
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$signedIn = (Get-CimInstance Win32_ComputerSystem).UserName
if ($signedIn) { $user = $signedIn }
# By SID (names can be ambiguous or translated), on the folder and every file already in it (/T); the task below runs
# with this user's filtered token, so it must read its own state without Administrators.
$sid = (New-Object Security.Principal.NTAccount($user)).Translate([Security.Principal.SecurityIdentifier]).Value
icacls $state /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*${sid}:(OI)(CI)M" /T | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not give $user access to $state (icacls $LASTEXITCODE)." }

$agent = Join-Path $dir "weaverbird-agent.exe"
$version = & $agent version
if (-not $version) { throw "The agent did not say its version." }
& $agent enrol $Code --platform $Platform --api $Api
if ($LASTEXITCODE -ne 0) { throw "Enrolment refused. Make a new code on the Printers page and run this again." }

# Start it at this user's sign-in, hidden, and again if it stops.
$action = New-ScheduledTaskAction -Execute $agent -Argument "run"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 `
  -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
Register-ScheduledTask -TaskName "Weaverbird agent" -Action $action -Trigger $trigger -Settings $settings `
  -User $user -RunLevel Limited -Force | Out-Null
Start-ScheduledTask -TaskName "Weaverbird agent"
Write-Host "Installed weaverbird-agent $version and enrolled it. It starts at every sign-in of $user."
