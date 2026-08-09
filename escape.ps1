# escape (Windows) — tunnel all traffic through your server, on any network.
# Auto-selects transport (UDP -> TCP-443) and auto-enrolls on first run.
# Run in an ADMIN PowerShell:  escape_start | escape_status | escape_stop
param([Parameter(Position=0)][string]$Cmd = "help")
# Continue (not Stop): wireguard.exe/route write harmless text to stderr; we check results explicitly.
$ErrorActionPreference = "Continue"

$Dir      = "$env:ProgramData\escape"
$Conf     = "$Dir\escape.conf"
$Wstunnel = "$Dir\wstunnel.exe"
$WgDir    = "$env:ProgramFiles\WireGuard"
$WgExe    = "$WgDir\wg.exe"
$Tunnel   = "$WgDir\wireguard.exe"
$Name     = "escape"
$LocalUdp = 51820
$EnrollPort = 9091

# --- baked into the package (not per-user secrets) ---
$ServerIp     = "40.81.225.20"
$EnrollSecret = "c08dc6a5b168ed6f9e2a3dd086ec65752b87ab932d062e64"

function Test-Admin {
  (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Egress([int]$t = 10) {   # DNS-independent: 1.1.1.1 by IP -> our public IP
  try {
    $r = Invoke-RestMethod -Uri "https://1.1.1.1/cdn-cgi/trace" -TimeoutSec $t
    (($r -split "`n") | Where-Object { $_ -like "ip=*" }) -replace "ip=",""
  } catch { "" }
}
function Stop-Wst { Get-Process wstunnel -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
function Tunnel-Down { if (Test-Path $Tunnel) { & $Tunnel /uninstalltunnelservice $Name 2>$null | Out-Null }; Start-Sleep -Milliseconds 700 }
function Add-Exclude([string]$gw) {
  cmd /c "route delete $ServerIp >nul 2>&1" | Out-Null
  if ($gw) { cmd /c "route add $ServerIp mask 255.255.255.255 $gw metric 1 >nul 2>&1" | Out-Null }
}
function Teardown { Tunnel-Down; Stop-Wst; cmd /c "route delete $ServerIp >nul 2>&1" | Out-Null }

function Enroll {
  Write-Host "escape: first run - registering this device with the server..."
  Stop-Wst
  $a = @("client","-L","tcp://127.0.0.1:$($EnrollPort):127.0.0.1:8080","--tls-sni-override","www.microsoft.com","wss://$($ServerIp):443")
  $p = Start-Process -FilePath $Wstunnel -ArgumentList $a -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 3
  $priv = (& $WgExe genkey).Trim()
  $pub  = ($priv | & $WgExe pubkey).Trim()
  $body = @{ secret = $EnrollSecret; pubkey = $pub } | ConvertTo-Json -Compress
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$EnrollPort/enroll" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 25
  } finally { $p | Stop-Process -Force -ErrorAction SilentlyContinue; Stop-Wst }
  if (-not $r.address) { throw "enrollment failed" }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  @"
[Interface]
PrivateKey = $priv
Address = $($r.address)
DNS = $($r.dns)
MTU = 1280

[Peer]
PublicKey = $($r.server_pubkey)
PresharedKey = $($r.psk)
Endpoint = $($r.endpoint)
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
"@ | Set-Content -Path $Conf -Encoding Ascii
  Write-Host "escape: this device is now registered ($($r.address))."
}

function Write-Conf([string]$Endpoint, [string]$Allowed) {
  $c = Get-Content $Conf -Raw
  $c = [regex]::Replace($c, '(?m)^Endpoint\s*=.*$',   "Endpoint = $Endpoint")
  $c = [regex]::Replace($c, '(?m)^AllowedIPs\s*=.*$', "AllowedIPs = $Allowed")
  $c = [regex]::Replace($c, '(?m)^MTU\s*=.*$',        "MTU = 1280")
  Set-Content -Path $Conf -Value $c -Encoding Ascii
}
function Tunnel-Up { & $Tunnel /installtunnelservice $Conf | Out-Null; Start-Sleep -Seconds 2 }

function Start-Udp {
  Write-Host "escape: trying fast path (WireGuard/UDP)..."
  Tunnel-Down
  Write-Conf "$($ServerIp):443" "0.0.0.0/0, ::/0"
  Tunnel-Up
  Start-Sleep -Seconds 2
  if ((Egress 8) -eq $ServerIp) { return $true }
  Tunnel-Down
  return $false
}

function Start-Tcp {
  Write-Host "escape: UDP blocked - switching to TCP-443 (HTTPS-disguised)..."
  Tunnel-Down
  $gw = $null
  try { $gw = (Find-NetRoute -RemoteIPAddress $ServerIp -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop } catch {}
  if (-not $gw -or $gw -eq "0.0.0.0") {
    try { $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch {}
  }
  if (-not $gw) { Write-Host "escape: could not find your network gateway"; return $false }
  Write-Host "escape: routing $ServerIp directly via $gw (so the tunnel doesn't loop)"
  Add-Exclude $gw
  # split AllowedIPs => WireGuard-for-Windows does NOT enable its kill-switch (which would block wstunnel)
  Write-Conf "127.0.0.1:$LocalUdp" "0.0.0.0/1, 128.0.0.0/1, ::/1, 8000::/1"
  Tunnel-Up
  Add-Exclude $gw
  Stop-Wst
  $a = @("client","-L","udp://127.0.0.1:$($LocalUdp):127.0.0.1:443?timeout_sec=0","--tls-sni-override","www.microsoft.com","wss://$($ServerIp):443")
  Start-Process -FilePath $Wstunnel -ArgumentList $a -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 6; $i++) {
    Add-Exclude $gw
    Start-Sleep -Seconds 3
    if ((Egress 8) -eq $ServerIp) { return $true }
  }
  Write-Host "escape: tunnel up but no traffic (network may block it)."
  return $false
}

function Ensure-Wstunnel {
  if (Test-Path $Wstunnel) { return }
  Write-Host "escape: fetching tunnel engine..."
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  Invoke-WebRequest "https://d-deadric-c.github.io/escape/wstunnel-windows-amd64.exe" -OutFile $Wstunnel
}

function Cmd-Start {
  if (-not (Test-Admin)) { Write-Host "escape: please run in an Administrator PowerShell."; return }
  if (-not (Test-Path $Tunnel)) {
    Write-Host "escape: installing WireGuard for Windows..."
    winget install -e --id WireGuard.WireGuard --accept-source-agreements --accept-package-agreements | Out-Null
    if (-not (Test-Path $Tunnel)) { Write-Host "escape: could not auto-install WireGuard - get it from https://www.wireguard.com/install/"; return }
  }
  Ensure-Wstunnel
  if (-not (Test-Path $Conf)) { Enroll }
  Teardown
  if (Start-Udp) { Write-Host "escape: connected (UDP)  your public IP is now $ServerIp"; return }
  if (Start-Tcp) { Write-Host "escape: connected (TCP-443)  your public IP is now $ServerIp"; return }
  Write-Host "escape: could not establish a tunnel here - rolled back, internet unaffected."
  Teardown
}
function Cmd-Stop  { if (-not (Test-Admin)) { Write-Host "escape: run as Administrator."; return }; Teardown; Write-Host "escape: disconnected - back on the normal network." }
function Cmd-Status {
  $e = Egress 8
  if ($e -eq $ServerIp) {
    Write-Host "escape: UP  (public IP: $e)"
    if (Get-Process wstunnel -ErrorAction SilentlyContinue) { Write-Host "        transport: TCP-443" } else { Write-Host "        transport: UDP" }
  } else { Write-Host "escape: down  (public IP: $e)" }
}

switch ($Cmd) {
  "start"  { Cmd-Start }
  "stop"   { Cmd-Stop }
  "status" { Cmd-Status }
  default  { Write-Host "usage: escape {start|stop|status}" }
}
