param([switch]$ForceNew, [switch]$NoWindow)
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\core.ps1')

$cfg = Get-Config
$server = Join-Path $PSScriptRoot 'server.ps1'

function Get-LivePort {
    if (-not (Test-Path $cfg.PortFile)) { return 0 }
    $p = 0
    try { $p = [int]((Get-Content $cfg.PortFile -Raw) -replace '\s', '') } catch { return 0 }
    if ($p -le 0) { return 0 }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $p); $c.Close()
        return $p
    } catch { return 0 }
}

# 代码被改过（比运行中的服务新）就重启服务，避免"界面是新版、后端是旧版"
function Test-ServerStale([int]$port) {
    $info = Join-Path $cfg.Home 'server.json'
    if (-not (Test-Path $info)) { return $true }
    $started = $null
    try { $started = [datetime](Get-Content $info -Raw | ConvertFrom-Json).startedAt } catch { return $true }
    if (-not $started) { return $true }
    $newest = $started
    foreach ($f in @((Join-Path $cfg.Root 'lib\core.ps1'), (Join-Path $PSScriptRoot 'server.ps1'),
                     (Join-Path $PSScriptRoot 'ui.html'), (Join-Path $PSScriptRoot 'start.ps1'))) {
        if (Test-Path $f) {
            $t = (Get-Item $f).LastWriteTime
            if ($t -gt $newest) { $newest = $t }
        }
    }
    return (($newest - $started).TotalSeconds -gt 2)
}

function Stop-LiveServer([int]$port) {
    try {
        Invoke-WebRequest ("http://127.0.0.1:$port/api/quit") -Method POST -Body '{}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 5 -Headers @{ 'X-Dshm' = '1' } | Out-Null
    } catch {}
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close() } catch { return $true }
    }
    return $false
}

function Open-Edge([int]$port) {
    $edge = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $url = "http://127.0.0.1:$port/"
    if ($edge) {
        $prof = Join-Path $cfg.Root 'web\edge-profile'
        Start-Process -FilePath $edge -ArgumentList @(
            "--app=$url", '--window-size=1100,760', ('--user-data-dir="' + $prof + '"'),
            '--no-first-run', '--no-default-browser-check'
        ) | Out-Null
    } else {
        Start-Process $url | Out-Null
    }
}

$port = if ($ForceNew) { 0 } else { Get-LivePort }
if ($port -gt 0 -and (Test-ServerStale $port)) {
    # 代码比运行中的后端新：先优雅关掉旧服务，再拉一个新的，避免新旧混用
    [void](Stop-LiveServer $port)
    $port = 0
}
if ($port -le 0) {
    # 服务没在跑：拉起看门狗（负责启动服务，并在服务死掉时自动重启）
    $watchdog = Join-Path $PSScriptRoot 'watchdog.ps1'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"' + $watchdog + '"')
    )
    # 等服务把端口写好；原生 App 也通过这条路径取得端口
    $port = 0
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        $port = Get-LivePort
        if ($port -gt 0) { break }
    }
    if ($port -le 0) { exit 1 }
}
if (-not $NoWindow) { Open-Edge $port }
