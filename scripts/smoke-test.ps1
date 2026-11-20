$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-switch-smoke-' + [Guid]::NewGuid().ToString('N'))
$managerHome = Join-Path $tempRoot 'manager'
$instanceRoot = Join-Path $tempRoot 'instances'
$instanceHome = Join-Path $instanceRoot 'demo\home'
$agentsHome = Join-Path $instanceRoot 'demo\agents'
$fakeExe = Join-Path $tempRoot 'DeepSeek Harness.exe'
$oldManagerHome = $env:DSH_MANAGER_HOME
$process = $null
$stdoutLog = Join-Path $tempRoot 'server.stdout.log'
$stderrLog = Join-Path $tempRoot 'server.stderr.log'

function Get-ServerOutput {
    $parts = @()
    foreach ($path in @($stderrLog, $stdoutLog, (Join-Path $managerHome 'dsh-manager.log'))) {
        if (Test-Path -LiteralPath $path) {
            $raw = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
            $text = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
            if ($text) { $parts += $text }
        }
    }
    return ($parts -join "`n")
}

try {
    New-Item -ItemType Directory -Force -Path $managerHome, $instanceRoot, (Join-Path $instanceHome 'profiles\desktop'), $agentsHome | Out-Null
    Set-Content -LiteralPath $fakeExe -Value 'smoke-test fixture' -Encoding ASCII

    $config = [ordered]@{ exe = $fakeExe; instancesRoot = $instanceRoot }
    [IO.File]::WriteAllText((Join-Path $managerHome 'config.json'), ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $data = [ordered]@{
        lastHome = $instanceHome
        instances = @([ordered]@{ name = 'Demo'; home = $instanceHome; agents = $agentsHome })
    }
    [IO.File]::WriteAllText((Join-Path $managerHome 'instances.json'), ($data | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    $env:DSH_MANAGER_HOME = $managerHome
    $server = Join-Path $root 'web\server.ps1'
    $process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $server + '"'), '-Port', '0', '-NoBrowser', '-Quiet'
    ) -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

    $portFile = Join-Path $managerHome 'web.port'
    $port = 0
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $portFile) {
            $raw = (Get-Content -LiteralPath $portFile -Raw).Trim()
            if ($raw -match '^\d+$') { $port = [int]$raw; break }
        }
        if ($process.HasExited) {
            $detail = Get-ServerOutput
            if ($detail) { throw ('服务进程提前退出：' + "`n" + $detail) }
            throw '服务进程提前退出（没有输出诊断信息）'
        }
    }
    if ($port -le 0) {
        $detail = Get-ServerOutput
        if ($detail) { throw ('服务没有写出可用端口：' + "`n" + $detail) }
        throw '服务没有写出可用端口'
    }

    $base = "http://127.0.0.1:$port"
    $headers = @{ 'X-Dshm' = '1' }
    $state = Invoke-RestMethod -Uri ($base + '/api/state') -Headers $headers -TimeoutSec 10
    if (-not $state.ok) { throw '/api/state 返回失败' }
    if (@($state.data.instances).Count -ne 1) { throw '实例数量不正确' }
    if ($state.data.instances[0].name -ne 'Demo') { throw '实例名称不正确' }

    $page = Invoke-WebRequest -Uri ($base + '/') -UseBasicParsing -TimeoutSec 10
    if ($page.StatusCode -ne 200 -or $page.Content -notmatch '<title>dsh-switch</title>') { throw '首页未正常返回' }

    $icon = Invoke-WebRequest -Uri ($base + '/favicon.ico') -UseBasicParsing -TimeoutSec 10
    if ($icon.StatusCode -ne 200 -or $icon.RawContentLength -le 0) { throw 'favicon 未正常返回' }

    $manifest = Invoke-RestMethod -Uri ($base + '/manifest.webmanifest') -TimeoutSec 10
    if ($manifest.name -ne 'dsh-switch') { throw 'manifest 名称不正确' }

    $quoted = $false
    try {
        Invoke-WebRequest -Uri ($base + '/api/state') -Method GET -Headers @{ Origin = 'https://example.com' } -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) { $quoted = $true }
    }
    if (-not $quoted) { throw '跨站请求没有被拒绝' }

    Invoke-WebRequest -Uri ($base + '/api/quit') -Method POST -Headers $headers -Body '{}' -ContentType 'application/json' -UseBasicParsing -TimeoutSec 10 | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 200
        if ($process.HasExited) { break }
    }
    Write-Host ("  smoke ok: port={0}, envs={1}" -f $port, @($state.data.instances).Count)
    exit 0
} catch {
    Write-Host ("  smoke failed: " + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
} finally {
    if ($process -and -not $process.HasExited) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($null -eq $oldManagerHome) { Remove-Item Env:DSH_MANAGER_HOME -ErrorAction SilentlyContinue }
    else { $env:DSH_MANAGER_HOME = $oldManagerHome }
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
