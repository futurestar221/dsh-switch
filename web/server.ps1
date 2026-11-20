param(
    [int]$Port = 0,
    [switch]$NoBrowser,
    [switch]$Quiet
)
$ErrorActionPreference = 'Continue'
$script:Quiet = [bool]$Quiet
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\core.ps1')

$cfg = Get-Config
$script:Data = Load-Data

# ---------------------------------------------------------------- http 帮助
function Send-Json($ctx, $obj) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
function Send-File($ctx, [string]$path, [string]$type) {
    if (-not (Test-Path $path)) { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); return }
    $bytes = [IO.File]::ReadAllBytes($path)
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}
function Read-Body($ctx) {
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd(); $sr.Close()
    if (-not $raw) { return @{} }
    try { return ($raw | ConvertFrom-Json) } catch { return @{} }
}
function Get-QueryValue($ctx, [string]$name) {
    # HttpListener 的 QueryString 在中文 Windows 上会按 GBK 解码；前端 encodeURIComponent 是 UTF-8。
    # 这里直接解析原始查询串并按 UTF-8 解码，避免中文环境目录在 profiles/inventory 中查不到。
    $query = [string]$ctx.Request.Url.Query
    if (-not $query) { return '' }
    foreach ($pair in $query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $eq = $pair.IndexOf('=')
        if ($eq -ge 0) { $rawKey = $pair.Substring(0, $eq); $rawVal = $pair.Substring($eq + 1) }
        else { $rawKey = $pair; $rawVal = '' }
        try { $key = [uri]::UnescapeDataString($rawKey.Replace('+', ' ')) } catch { $key = $rawKey }
        if ($key -eq $name) {
            try { return [uri]::UnescapeDataString($rawVal.Replace('+', ' ')) } catch { return $rawVal }
        }
    }
    return ''
}

# ---------------------------------------------------------------- 监听
$listener = $null
try { $listener = New-Object System.Net.HttpListener } catch {
    $inner = $_.Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    Write-Log ("无法创建本地 HTTP 监听器: " + $inner.Message)
    Write-Log '当前环境可能禁用了 Windows HTTP 服务，或运行在限制了网络监听的沙箱中。'
    exit 1
}
$usePort = $Port
if ($usePort -le 0) {
    $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tcp.Start(); $usePort = ([Net.IPEndPoint]$tcp.LocalEndpoint).Port; $tcp.Stop()
}
$prefix = "http://127.0.0.1:$usePort/"
$listener.Prefixes.Add($prefix)
try { $listener.Start() } catch {
    # 指定端口被占用（多半是上一个没退干净的实例）：退回随机端口，别整体失败
    if ($Port -gt 0) {
        Write-Log ("端口 $Port 被占用，改用随机端口")
        $listener = New-Object System.Net.HttpListener
        $tcp = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $tcp.Start(); $usePort = ([Net.IPEndPoint]$tcp.LocalEndpoint).Port; $tcp.Stop()
        $prefix = "http://127.0.0.1:$usePort/"
        $listener.Prefixes.Add($prefix)
        try { $listener.Start() } catch { Write-Log "端口启动失败: $($_.Exception.Message)"; exit 1 }
    } else {
        Write-Log "端口启动失败: $($_.Exception.Message)"; exit 1
    }
}
Write-Log "管理界面已启动: $prefix（数据目录 $($cfg.Home)）"
Write-Text $cfg.PortFile ([string]$usePort)
# 记录本进程的启动时间，start.ps1 用它判断"代码是否比后端新"
Write-Text (Join-Path $cfg.Home 'server.json') (@{ pid = $PID; port = $usePort; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json)

function Open-Window {
    $edge = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($edge) {
        $prof = Join-Path $cfg.Root 'web\edge-profile'
        Start-Process -FilePath $edge -ArgumentList @(
            "--app=$prefix", '--window-size=1100,760', ('--user-data-dir="' + $prof + '"'),
            '--no-first-run', '--no-default-browser-check'
        ) | Out-Null
    } else { Start-Process $prefix | Out-Null }
}
if (-not $NoBrowser) { Open-Window; Write-Log '已打开管理窗口' }

$running = $true
while ($running -and $listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    # ---- 从这里到分发之前都在保护里：任何异常只丢这一个请求，不会带走整个服务
    # （2026-10-31 修复：原先这几行在 try 外面，一个畸形/中断的请求就能让后台静默退出）
    $deny = $false
    try {
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath.ToLowerInvariant()

        # ---- 访问校验：只保护 /api/*，静态页面永远放行
        # 原因：界面本身（/ 与 ui.html）被拦会导致"打开是空白/一串 JSON"，等于管理器打不开。
        # 放行规则：带 X-Dshm: 1 / Sec-Fetch-Site 为 same-origin 或 none /
        #           完全没有 Sec-Fetch-Site 且没有 Origin（curl、脚本等非浏览器客户端）；
        #           Sec-Fetch-Site 缺失但带外来 Origin → 拒绝。
        # 关闭开关：数据目录放一个 disable-auth.txt
        if (-not (Test-Path (Join-Path $cfg.Home 'disable-auth.txt'))) {
            if ($path -like '/api/*') {
                $site = [string]$req.Headers['Sec-Fetch-Site']
                $dshm = [string]$req.Headers['X-Dshm']
                $origin = [string]$req.Headers['Origin']
                $allow = $false
                if ($dshm -eq '1') { $allow = $true }
                elseif ($site -eq 'same-origin' -or $site -eq 'none') { $allow = $true }
                elseif ([string]::IsNullOrEmpty($site)) {
                    if ([string]::IsNullOrEmpty($origin)) { $allow = $true }
                    elseif ($origin -match '^http://(127\.0\.0\.1|localhost)(:\d+)?$') { $allow = $true }
                }
                if (-not $allow) {
                    Write-Log ("拒绝跨站请求: " + $path + "  Sec-Fetch-Site=" + $site + "  Origin=" + $origin)
                    $ctx.Response.StatusCode = 403
                    Send-Json $ctx @{ ok = $false; message = '拒绝跨站请求（需要同源页面或 X-Dshm 头）' }
                    $deny = $true
                }
            }
        }
    } catch {
        # 请求不完整、客户端中途断开等：丢掉这个请求，服务继续跑
        try { $ctx.Response.StatusCode = 400; $ctx.Response.Close() } catch {}
        continue
    }
    if ($deny) { continue }

    try {
        switch -Regex ($path) {
            '^/$' { Send-File $ctx (Join-Path $cfg.Root 'web\ui.html') 'text/html; charset=utf-8'; continue }
            '^/favicon\.ico$' { Send-File $ctx (Join-Path $cfg.Root 'web\assets\dsh-manager.ico') 'image/x-icon'; continue }
            '^/manifest\.webmanifest$' { Send-File $ctx (Join-Path $cfg.Root 'web\assets\site.webmanifest') 'application/manifest+json; charset=utf-8'; continue }
            '^/assets/(dsh-manager-192\.png|dsh-manager-512\.png|dsh-manager\.ico)$' {
                $assetName = $Matches[1]
                $assetType = if ($assetName -like '*.png') { 'image/png' } else { 'image/x-icon' }
                Send-File $ctx (Join-Path (Join-Path $cfg.Root 'web\assets') $assetName) $assetType
                continue
            }

            '^/api/state$' {
                $cfg = Get-Config
                $procs = Get-DshProcs
                $anyRunning = $procs.Count -gt 0
                $curHome = if ($anyRunning) { Get-CurrentHome } else { '' }
                $list = foreach ($i in $script:Data.instances) {
                    $exists = Test-Path $i.home
                    $inst = [pscustomobject]@{ home = $i.home; agents = $i.agents }
                    $health = if ($exists) { Get-ProfileHealth $i.home } else { [pscustomobject]@{ ok = $false; status = 'err'; summary = '目录不存在' } }
                    [pscustomobject]@{
                        name     = $i.name
                        home     = $i.home
                        agents   = $i.agents
                        exists   = $exists
                        running  = ($anyRunning -and $i.home -eq $curHome)
                        plugins  = if ($exists) { Get-PluginCount $inst } else { 0 }
                        skills   = if ($exists) { Get-SkillCount $inst } else { 0 }
                        health   = @{ status = $health.status; summary = $health.summary }
                    }
                }
                Send-Json $ctx @{ ok = $true; data = @{
                        instances = @($list); current = $curHome; anyRunning = $anyRunning
                        exe = $cfg.Exe; exeSource = $cfg.ExeSource
                        home = $cfg.Home; instancesRoot = $cfg.InstancesRoot
                    } }
                continue
            }

            '^/api/config$' {
                if ($req.HttpMethod -eq 'POST') {
                    $b = Read-Body $ctx
                    $patch = @{}
                    if ($b.exe) {
                        $exePath = Resolve-PathExpanded ([string]$b.exe)
                        if (-not $exePath -or -not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
                            Send-Json $ctx @{ ok = $false; message = 'DSH 程序路径不存在' }; continue
                        }
                        $patch['exe'] = $exePath
                    }
                    if ($b.instancesRoot) {
                        $ir = Resolve-PathExpanded ([string]$b.instancesRoot)
                        if (-not $ir) { Send-Json $ctx @{ ok = $false; message = '实例根目录无效：需要绝对路径，且不能用未展开的 %变量%' }; continue }
                        if (-not (Test-Path -LiteralPath $ir)) { New-Item -ItemType Directory -Force -Path $ir | Out-Null }
                        $patch['instancesRoot'] = $ir
                    }
                    if ($patch.Count -gt 0) { Save-UserConfig $patch; $script:Cfg = $null }
                    $cfg = Get-Config
                    Write-Log ("配置已更新: exe=" + $cfg.Exe + " 实例根=" + $cfg.InstancesRoot)
                    Send-Json $ctx @{ ok = $true; message = '配置已保存'; data = @{
                            exe = $cfg.Exe; exeSource = $cfg.ExeSource; instancesRoot = $cfg.InstancesRoot; home = $cfg.Home
                        } }
                    continue
                }
                $cfg = Get-Config
                Send-Json $ctx @{ ok = $true; data = @{
                        exe = $cfg.Exe; exeSource = $cfg.ExeSource
                        instancesRoot = $cfg.InstancesRoot; home = $cfg.Home; found = [bool]$cfg.Exe
                    } }
                continue
            }

            '^/api/detect$' {
                $found = Find-DshExe
                $msg = if ($found.ok) { "找到: $($found.path)（$($found.source)）" } else { '没找到，请手动指定 DSH 程序路径' }
                Send-Json $ctx @{ ok = $true; message = $msg; data = @{ found = $found.ok; exe = $found.path; source = $found.source } }
                continue
            }

            '^/api/profiles$' {
                Send-Json $ctx @{ ok = $true; data = @(Get-Profiles (Get-QueryValue $ctx 'home')) }
                continue
            }

            '^/api/inventory$' {
                $h = Get-QueryValue $ctx 'home'
                $inst = [pscustomobject]@{ home = $h; agents = '' }
                foreach ($i in $script:Data.instances) { if ($i.home -eq $h) { $inst = $i; break } }
                Send-Json $ctx @{ ok = $true; data = @{ plugins = @(Get-Plugins $inst); skills = @(Get-Skills $inst) } }
                continue
            }

            '^/api/start$' {
                $b = Read-Body $ctx
                $inst = $script:Data.instances | Where-Object { $_.home -eq $b.home } | Select-Object -First 1
                if (-not $inst) { Send-Json $ctx @{ ok = $false; message = '找不到这个环境' }; continue }
                # 预检：配置解析不了时不盲启，除非显式 force（界面上的「强制启动」）
                $h = Get-ProfileHealth $inst.home
                if (-not $h.ok -and -not $b.force) {
                    Write-Log ("预检拦截 " + $inst.name + ": " + $h.summary)
                    Send-Json $ctx @{ ok = $false; message = ('配置预检未通过：' + $h.summary + '（确认无误可强制启动）'); data = @{ health = @{ status = $h.status; summary = $h.summary } } }
                    continue
                }
                $r = Start-Dsh $inst.home $inst.agents
                Write-Log ("启动 " + $inst.name + ": " + $r.message)
                Send-Json $ctx $r; continue
            }
            '^/api/stop$' { $r = Stop-Dsh; Write-Log ("停止: " + $r.message); Send-Json $ctx $r; continue }

            '^/api/open$' {
                $b = Read-Body $ctx
                $cfg = Get-Config
                $result = @{ ok = $true; message = '已打开' }
                switch ([string]$b.what) {
                    'log'  { if (-not (Test-Path $cfg.LogFile)) { $result = @{ ok = $false; message = '日志文件还不存在' } } else { Start-Process -FilePath notepad.exe -ArgumentList ('"' + $cfg.LogFile + '"') | Out-Null } }
                    'data' { if (-not (Test-Path $cfg.Home)) { $result = @{ ok = $false; message = '管理器数据目录不存在' } } else { Invoke-Item $cfg.Home } }
                    default {
                        if (-not $b.home) { $result = @{ ok = $false; message = '没有指定环境目录' } }
                        elseif (-not (Test-Path -LiteralPath ([string]$b.home))) { $result = @{ ok = $false; message = '环境目录不存在' } }
                        else { Invoke-Item ([string]$b.home) }
                    }
                }
                Send-Json $ctx $result; continue
            }

            '^/api/profile-use$' { $b = Read-Body $ctx; $r = Set-CurrentProfile $b.home $b.name; Write-Log $r.message; Send-Json $ctx $r; continue }
            '^/api/profile-new$' {
                $b = Read-Body $ctx
                if ($b.name -notmatch '^[A-Za-z0-9._-]+$' -or $b.name -eq '.' -or $b.name -eq '..') { Send-Json $ctx @{ ok = $false; message = '名字只能用英文、数字、点、下划线、横线' }; continue }
                $r = New-Profile $b.home $b.name; Write-Log $r.message; Send-Json $ctx $r; continue
            }
            '^/api/profile-del$' { $b = Read-Body $ctx; $r = Remove-Profile $b.home $b.name; Write-Log $r.message; Send-Json $ctx $r; continue }
            '^/api/profile-rollback$' { $b = Read-Body $ctx; $r = Undo-Profile $b.home; Write-Log $r.message; Send-Json $ctx $r; continue }

            '^/api/instance-add$' {
                $b = Read-Body $ctx
                $cfg0 = Get-Config
                $name = ([string]$b.name).Trim()
                if (-not $name) { Send-Json $ctx @{ ok = $false; message = '名字要填' }; continue }
                if ($name -match '[\\/:*?"<>|]') { Send-Json $ctx @{ ok = $false; message = '名字不能包含 \\ / : * ? " < > |' }; continue }
                if (@($script:Data.instances | Where-Object { $_.name -ieq $name }).Count -gt 0) {
                    Send-Json $ctx @{ ok = $false; message = ('已经有叫「' + $name + '」的环境了') }; continue
                }
                $raw = [string]$b.home
                $existing = [bool]$b.existing
                if ($existing -and [string]::IsNullOrWhiteSpace($raw)) {
                    Send-Json $ctx @{ ok = $false; message = '添加已有环境时要填写目录' }; continue
                }
                if (-not $existing -and [string]::IsNullOrWhiteSpace($raw)) { $raw = Get-DefaultHomePath $name }
                $homeDir = Resolve-PathExpanded $raw
                if (-not $homeDir) { Send-Json $ctx @{ ok = $false; message = '目录无效：要填绝对路径，且不要用未展开的 %变量%' }; continue }
                if (@($script:Data.instances | Where-Object { $_.home -and ([IO.Path]::GetFullPath($_.home).TrimEnd('\') -ieq [IO.Path]::GetFullPath($homeDir).TrimEnd('\')) }).Count -gt 0) {
                    Send-Json $ctx @{ ok = $false; message = '这个目录已经在环境列表里了' }; continue
                }
                $chk = if ($existing) { Test-ExistingHomePath $homeDir } else { Test-NewHomePath $homeDir }
                if (-not $chk.ok) { Send-Json $ctx @{ ok = $false; message = $chk.message }; continue }
                $homeDir = [string]$chk.path
                if (-not $existing -and -not (Test-Path -LiteralPath $homeDir)) { New-Item -ItemType Directory -Force -Path $homeDir | Out-Null }
                $agents = ''
                if ($b.agents) { $agents = Resolve-PathExpanded ([string]$b.agents) }
                if (-not $agents) {
                    if ((Split-Path $homeDir -Leaf) -eq 'home') { $agents = Join-Path (Split-Path $homeDir -Parent) 'agents' }
                    else { $agents = Join-Path $homeDir 'agents' }
                }
                if (-not (Test-Path -LiteralPath $agents)) { New-Item -ItemType Directory -Force -Path $agents | Out-Null }
                $script:Data.instances += [pscustomobject]@{ name = $name; home = $homeDir; agents = $agents }
                Save-Data $script:Data
                $verb = if ($existing) { '导入已有环境: ' } else { '新增环境: ' }
                $done = if ($existing) { '已添加已有环境: ' } else { '已添加环境: ' }
                Write-Log ($verb + $name + ' -> ' + $homeDir)
                Send-Json $ctx @{ ok = $true; message = ($done + $name); data = @{ home = $homeDir; agents = $agents } }; continue
            }
            '^/api/instance-save$' {
                $b = Read-Body $ctx
                $inst = $script:Data.instances | Where-Object { $_.home -eq $b.oldHome } | Select-Object -First 1
                if (-not $inst) { Send-Json $ctx @{ ok = $false; message = '找不到这个环境' }; continue }
                $newName = ([string]$b.name).Trim()
                if (-not $newName) { Send-Json $ctx @{ ok = $false; message = '名字不能为空' }; continue }
                if ($newName -match '[\\/:*?"<>|]') { Send-Json $ctx @{ ok = $false; message = '名字不能包含 \\ / : * ? " < > |' }; continue }
                if (@($script:Data.instances | Where-Object { $_.home -ne $inst.home -and $_.name -ieq $newName }).Count -gt 0) {
                    Send-Json $ctx @{ ok = $false; message = ('已经有叫「' + $newName + '」的环境了') }; continue
                }
                $newHome = [string]$inst.home
                if ($b.home) {
                    $resolvedHome = Resolve-PathExpanded ([string]$b.home)
                    $chkHome = Test-ExistingHomePath $resolvedHome
                    if (-not $chkHome.ok) { Send-Json $ctx @{ ok = $false; message = $chkHome.message }; continue }
                    $newHome = [string]$chkHome.path
                }
                if ($newHome -ne [string]$inst.home -and (Test-HomeInUse ([string]$inst.home))) {
                    Send-Json $ctx @{ ok = $false; message = '这个环境正在运行，先停止再修改目录' }; continue
                }
                if (@($script:Data.instances | Where-Object { $_.home -ne $inst.home -and $_.home -and ([IO.Path]::GetFullPath($_.home).TrimEnd('\') -ieq [IO.Path]::GetFullPath($newHome).TrimEnd('\')) }).Count -gt 0) {
                    Send-Json $ctx @{ ok = $false; message = '这个目录已经被另一个环境使用' }; continue
                }
                $newAgents = [string]$b.agents
                if ($newAgents) {
                    $newAgents = Resolve-PathExpanded $newAgents
                    if (-not $newAgents) { Send-Json $ctx @{ ok = $false; message = '技能目录路径无效' }; continue }
                    if (-not (Test-Path -LiteralPath $newAgents)) { New-Item -ItemType Directory -Force -Path $newAgents | Out-Null }
                }
                $inst.name = $newName
                $inst.home = $newHome
                $inst.agents = $newAgents
                Save-Data $script:Data
                Write-Log ('编辑环境: ' + $newName + ' -> ' + $newHome)
                Send-Json $ctx @{ ok = $true; message = '已保存'; data = @{ home = $newHome; agents = $newAgents } }; continue
            }
            '^/api/instance-remove$' {
                $b = Read-Body $ctx
                if (Test-HomeInUse ([string]$b.home)) { Send-Json $ctx @{ ok = $false; message = '这个环境正在运行，先停止再从列表移除' }; continue }
                $script:Data.instances = @($script:Data.instances | Where-Object { -not ($_.home -eq $b.home -and $_.name -eq $b.name) })
                Save-Data $script:Data
                Write-Log "从列表移除: $($b.name)（文件未动）"
                Send-Json $ctx @{ ok = $true; message = '已移除（文件未动）' }; continue
            }

            '^/api/instance-migrate$' {
                $b = Read-Body $ctx
                $oldHome = [string]$b.oldHome
                $newHome = [string]$b.newHome
                $agents = [string]$b.agents
                $migrateAgents = [bool]$b.migrateAgents
                $retireSource = [bool]$b.retireSource
                # 先只校验，不打断正在使用的 DSH；参数有问题就直接返回。
                $pre = Move-DshEnvironment $oldHome $newHome $agents $migrateAgents $retireSource -ValidateOnly
                if (-not $pre.ok) { Send-Json $ctx $pre; continue }
                # 迁移期间环境不能有进程占用；这里统一先停止所有 DSH 实例。
                $stop = Stop-Dsh
                if (-not $stop.ok) { Send-Json $ctx @{ ok = $false; message = ('停止 DSH 失败，未开始迁移：' + $stop.message) }; continue }
                $r = Move-DshEnvironment $oldHome $newHome $agents $migrateAgents $retireSource
                if ($r.ok) { $script:Data = Load-Data }
                Write-Log ('迁移环境: ' + $r.message)
                Send-Json $ctx $r; continue
            }

            '^/api/pick-folder$' {
                # 系统文件夹选择框跑在独立进程里，结果写文件，避免阻塞主循环
                $b = Read-Body $ctx
                $cfg = Get-Config
                $out = Join-Path $cfg.Home 'pick.out'
                Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                $picker = Join-Path $cfg.Root 'web\pick-folder.ps1'
                if (-not (Test-Path -LiteralPath $picker)) { Send-Json $ctx @{ ok = $false; message = '缺少 web\pick-folder.ps1' }; continue }
                $initial = ''
                if ($b.initial) { $initial = ([string]$b.initial).Trim().Trim('"') }
                $qa = [char]34
                $arg = ('-NoProfile -STA -ExecutionPolicy Bypass -File ' + $qa + $picker + $qa + ' -OutFile ' + $qa + $out + $qa)
                if ($initial) { $arg += (' -Initial ' + $qa + $initial + $qa) }
                try { Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arg | Out-Null }
                catch { Send-Json $ctx @{ ok = $false; message = $_.Exception.Message }; continue }
                Send-Json $ctx @{ ok = $true; pending = $true }; continue
            }
            '^/api/pick-exe$' {
                $b = Read-Body $ctx
                $cfg = Get-Config
                $out = Join-Path $cfg.Home 'pick-exe.out'
                Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                $picker = Join-Path $cfg.Root 'web\pick-exe.ps1'
                if (-not (Test-Path -LiteralPath $picker)) { Send-Json $ctx @{ ok = $false; message = '缺少 web\pick-exe.ps1' }; continue }
                $initial = ''
                if ($b.initial) { $initial = ([string]$b.initial).Trim().Trim('"') }
                $qa = [char]34
                $arg = ('-NoProfile -STA -ExecutionPolicy Bypass -File ' + $qa + $picker + $qa + ' -OutFile ' + $qa + $out + $qa)
                if ($initial) { $arg += (' -Initial ' + $qa + $initial + $qa) }
                try { Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $arg | Out-Null }
                catch { Send-Json $ctx @{ ok = $false; message = $_.Exception.Message }; continue }
                Send-Json $ctx @{ ok = $true; pending = $true }; continue
            }
            '^/api/pick-folder-result$' {
                $cfg = Get-Config
                $out = Join-Path $cfg.Home 'pick.out'
                if (-not (Test-Path -LiteralPath $out)) { Send-Json $ctx @{ ok = $true; pending = $true }; continue }
                $picked = ''
                try { $picked = [IO.File]::ReadAllText($out, (New-Object Text.UTF8Encoding($false))).Trim() } catch {}
                Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                Send-Json $ctx @{ ok = $true; path = $picked }; continue
            }
            '^/api/pick-exe-result$' {
                $cfg = Get-Config
                $out = Join-Path $cfg.Home 'pick-exe.out'
                if (-not (Test-Path -LiteralPath $out)) { Send-Json $ctx @{ ok = $true; pending = $true }; continue }
                $picked = ''
                try { $picked = [IO.File]::ReadAllText($out, (New-Object Text.UTF8Encoding($false))).Trim() } catch {}
                Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
                Send-Json $ctx @{ ok = $true; path = $picked }; continue
            }

            '^/api/shortcuts$' {
                Send-Json $ctx @{ ok = $true; data = @(Get-DshShortcuts) }; continue
            }
            '^/api/shortcuts-toggle$' {
                $b = Read-Body $ctx
                $hide = $true
                if ($null -ne $b.hide) { $hide = [bool]$b.hide }
                $r = Set-DshShortcutHidden ([string]$b.path) $hide
                Write-Log ('快捷方式: ' + $r.message + '  ' + [string]$b.path)
                Send-Json $ctx $r; continue
            }

            '^/api/instance-delete$' {
                # 删除环境目录：先停进程 + 需要输入名字确认；目录一律移到回收站，不直接抹掉
                $b = Read-Body $ctx
                $inst = $script:Data.instances | Where-Object { $_.home -eq $b.home } | Select-Object -First 1
                if (-not $inst) { Send-Json $ctx @{ ok = $false; message = '找不到这个环境' }; continue }
                if (Test-HomeInUse $inst.home) { Send-Json $ctx @{ ok = $false; message = '这个环境正在运行，先停止再删' }; continue }
                if ([string]$b.confirm -ne [string]$inst.name) { Send-Json $ctx @{ ok = $false; message = '确认名字不匹配，已取消' }; continue }
                $r = Move-HomeToTrash $inst.home $inst.name
                if ($r.ok) {
                    $script:Data.instances = @($script:Data.instances | Where-Object { $_.home -ne $inst.home })
                    Save-Data $script:Data
                    Write-Log ('删除环境目录: ' + $inst.name + ' -> ' + $r.trash)
                } else {
                    Write-Log ('删除环境目录失败: ' + $inst.name + ' ' + $r.message)
                }
                Send-Json $ctx $r; continue
            }
            '^/api/trash$' {
                Send-Json $ctx @{ ok = $true; data = @(Get-TrashEntries) }; continue
            }
            '^/api/trash-restore$' {
                $b = Read-Body $ctx
                $r = Restore-TrashEntry ([string]$b.trash)
                Write-Log ('回收站恢复: ' + $r.message)
                Send-Json $ctx $r; continue
            }
            '^/api/trash-clear$' {
                $b = Read-Body $ctx
                if ([string]$b.confirm -ne '清空') { Send-Json $ctx @{ ok = $false; message = '需要输入「清空」两个字确认' }; continue }
                $r = Clear-Trash
                Write-Log ('清空回收站: ' + $r.message)
                Send-Json $ctx $r; continue
            }

            '^/api/quit$' {
                # 先停掉看门狗，否则它会在几秒后把服务重新拉起来
                $wp = Join-Path $cfg.Home 'watchdog.pid'
                if (Test-Path $wp) {
                    try { $wpid = [int]((Get-Content $wp -Raw) -replace '\s', ''); if ($wpid -gt 0) { Stop-Process -Id $wpid -Force -ErrorAction SilentlyContinue } } catch {}
                    Remove-Item $wp -Force -ErrorAction SilentlyContinue
                }
                Send-Json $ctx @{ ok = $true; message = '再见' }; $running = $false; continue
            }
            default { Send-Json $ctx @{ ok = $false; message = 'not found' }; continue }
        }
    } catch {
        try { Send-Json $ctx @{ ok = $false; message = $_.Exception.Message } } catch {}
    }
}
try { $listener.Stop(); $listener.Close() } catch {}
if (Test-Path $cfg.PortFile) { Remove-Item $cfg.PortFile -Force -ErrorAction SilentlyContinue }
Write-Log '管理界面已退出'
