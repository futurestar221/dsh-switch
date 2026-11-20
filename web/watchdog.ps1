param([int]$IntervalSec = 10)
# web/watchdog.ps1 —— 管理器的看门狗
# 职责：保证后台服务（server.ps1）一直活着。服务无响应就重新拉起，并自动开一个新窗口
#       （旧窗口指向的是已经死掉的端口，不刷新就是僵尸页）。
# 退出条件：UI 上点「退出」会先杀掉本进程（见 server.ps1 的 /api/quit）。

$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\core.ps1')

$cfg = Get-Config
$server = Join-Path $PSScriptRoot 'server.ps1'
$watchPidFile = Join-Path $cfg.Home 'watchdog.pid'

# 去重：已经有一个活着的看门狗就不再起第二个
if (Test-Path $watchPidFile) {
    $oldPid = 0
    try { $oldPid = [int]((Get-Content $watchPidFile -Raw) -replace '\s', '') } catch { $oldPid = 0 }
    if ($oldPid -gt 0 -and $oldPid -ne $PID) {
        if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
            Write-Log "看门狗已在运行 (pid $oldPid)，本次不重复启动"
            exit 0
        }
    }
}
Write-Text $watchPidFile ([string]$PID)
Write-Log "看门狗已启动 (pid $PID)，每 $IntervalSec 秒探活一次"

function Test-Port([int]$port) {
    if ($port -le 0) { return $false }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect('127.0.0.1', $port)
        $c.Close()
        return $true
    } catch { return $false }
}

function Get-LivePort {
    if (-not (Test-Path $cfg.PortFile)) { return 0 }
    $p = 0
    try { $p = [int]((Get-Content $cfg.PortFile -Raw) -replace '\s', '') } catch { return 0 }
    if (Test-Port $p) { return $p }
    return 0
}

function Start-ServerProcess([int]$Port = 0, [switch]$NoBrowser) {
    $sargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $server + '"'), '-Quiet')
    if ($Port -gt 0) { $sargs += @('-Port', [string]$Port) }
    if ($NoBrowser) { $sargs += '-NoBrowser' }
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $sargs
}

$restarts = 0
$windowStart = Get-Date
$firstStart = $true

while ($true) {
    try {
        if ((Get-LivePort) -le 0) {
            if (((Get-Date) - $windowStart).TotalMinutes -gt 10) { $restarts = 0; $windowStart = Get-Date }
            $restarts++
            if ($restarts -gt 6) {
                Write-Log '看门狗: 10 分钟内重启超过 6 次，停止自动重启（请手动排查）'
                break
            }
            $lastPort = 0
            if (Test-Path $cfg.PortFile) { try { $lastPort = [int]((Get-Content $cfg.PortFile -Raw) -replace '\s', '') } catch { $lastPort = 0 } }
            Write-Log ("看门狗: 后台服务没有响应，正在重新拉起（第 $restarts 次，沿用端口 " + $lastPort + "）")
            Remove-Item $cfg.PortFile -Force -ErrorAction SilentlyContinue
            # 窗口由原生 App 管理；后台服务永远不要自行拉起 Edge。
            Start-ServerProcess -Port $lastPort -NoBrowser
            $ok = $false
            for ($i = 0; $i -lt 80; $i++) {
                Start-Sleep -Milliseconds 250
                if ((Get-LivePort) -gt 0) { $ok = $true; break }
            }
            if ($ok) {
                $now = Get-LivePort
                Write-Log ("看门狗: 已恢复，端口 " + $now)
                if ($firstStart) { $firstStart = $false }
                elseif ($lastPort -gt 0 -and $now -ne $lastPort) { Write-Log ('看门狗: 端口变了（' + $lastPort + ' -> ' + $now + '），请重新双击「dsh-switch」') }
            } else { Write-Log '看门狗: 这次没拉起来，稍后重试' }
        }
    } catch {
        Write-Log ("看门狗: 探活出错 " + $_.Exception.Message)
    }
    Start-Sleep -Seconds $IntervalSec
}
