# lib/core.ps1 —— 路径解析、DSH 探测、业务逻辑（无 UI、无 HTTP）
# 被 web/server.ps1 与 tools/*.ps1 点引用（dot-source）。
# 设计原则：不假设任何绝对路径。所有位置都由脚本自身位置 + 用户配置推导。

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- 配置
$script:Root = Split-Path -Parent $PSScriptRoot          # 仓库根（lib 的上级）

function Get-ManagerHome {
    # 数据目录：优先环境变量，其次 %APPDATA%\dsh-manager
    if ($env:DSH_MANAGER_HOME) { return [IO.Path]::GetFullPath($env:DSH_MANAGER_HOME) }
    $base = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $env:USERPROFILE 'AppData\Roaming' }
    return (Join-Path $base 'dsh-manager')
}

function Get-ConfigFile { Join-Path (Get-ManagerHome) 'config.json' }

function Read-UserConfig {
    $f = Get-ConfigFile
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-UserConfig([hashtable]$patch) {
    $dir = Get-ManagerHome
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $cur = Read-UserConfig
    $obj = [ordered]@{}
    foreach ($k in @('exe', 'instancesRoot')) { $obj[$k] = if ($cur -and $cur.$k) { [string]$cur.$k } else { '' } }
    foreach ($k in $patch.Keys) { $obj[$k] = [string]$patch[$k] }
    [IO.File]::WriteAllText((Get-ConfigFile), ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- DSH 可执行文件探测
function Find-DshExe {
    $cfg = Read-UserConfig
    $candidates = New-Object System.Collections.ArrayList

    # 1) 环境变量（临时覆盖最方便）
    if ($env:DSH_EXE) { [void]$candidates.Add(@{ src = 'DSH_EXE 环境变量'; path = $env:DSH_EXE }) }
    # 2) 用户配置文件里记的
    if ($cfg -and $cfg.exe) { [void]$candidates.Add(@{ src = '配置文件'; path = [string]$cfg.exe }) }
    # 3) 注册表卸载项（官方安装版会登记 InstallLocation）
    foreach ($hive in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        try {
            Get-ItemProperty $hive -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'DeepSeek\s*Harness' } | ForEach-Object {
                if ($_.InstallLocation) { [void]$candidates.Add(@{ src = '注册表'; path = (Join-Path $_.InstallLocation 'DeepSeek Harness.exe') }) }
                if ($_.DisplayIcon) { [void]$candidates.Add(@{ src = '注册表图标'; path = ($_.DisplayIcon -replace ',\d+$', '') }) }
            }
        } catch {}
    }
    # 4) 常见安装位置
    $common = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe')
    )
    foreach ($c in $common) { if ($c) { [void]$candidates.Add(@{ src = '常见位置'; path = $c }) } }
    # 5) 开始菜单 / 桌面快捷方式指向
    foreach ($dir in @(
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:PUBLIC 'Desktop'))) {
        if (-not (Test-Path $dir)) { continue }
        try {
            Get-ChildItem $dir -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'DeepSeek|Harness|dsh' } | ForEach-Object {
                    try {
                        $ws = New-Object -ComObject WScript.Shell
                        $t = $ws.CreateShortcut($_.FullName).TargetPath
                        if ($t) { [void]$candidates.Add(@{ src = '快捷方式'; path = $t }) }
                    } catch {}
                }
        } catch {}
    }

    foreach ($c in $candidates) {
        if ($c.path -and (Test-Path $c.path)) {
            return [pscustomobject]@{ ok = $true; path = [IO.Path]::GetFullPath($c.path); source = $c.src }
        }
    }
    return [pscustomobject]@{ ok = $false; path = ''; source = ''; tried = @($candidates | ForEach-Object { $_.path }) }
}

# ---------------------------------------------------------------- 配置汇总
function Get-Config {
    if ($script:Cfg) { return $script:Cfg }
    $homeDir = Get-ManagerHome
    if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Force -Path $homeDir | Out-Null }
    $cfg = Read-UserConfig
    $instRoot = if ($cfg -and $cfg.instancesRoot) { [string]$cfg.instancesRoot } else { Join-Path $homeDir 'instances' }
    if (-not (Test-Path $instRoot)) { New-Item -ItemType Directory -Force -Path $instRoot | Out-Null }

    $dsh = Find-DshExe
    $script:Cfg = [pscustomobject]@{
        Root          = $script:Root
        Home          = $homeDir
        DataFile      = Join-Path $homeDir 'instances.json'
        LogFile       = Join-Path $homeDir 'dsh-manager.log'
        PortFile      = Join-Path $homeDir 'web.port'
        MarkerFile    = Join-Path $homeDir 'current.json'
        InstancesRoot = $instRoot
        Exe           = $dsh.path
        ExeSource     = $dsh.source
        ProcName      = 'DeepSeek Harness'
    }
    return $script:Cfg
}

# ---------------------------------------------------------------- 日志
function Write-Log([string]$m) {
    $c = Get-Config
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)
    try { Add-Content -Path $c.LogFile -Value $line -Encoding UTF8 } catch {}
    if (-not $script:Quiet) { Write-Host $line }
}
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }

# ---------------------------------------------------------------- 实例表
function New-DefaultData {
    $c = Get-Config
    $list = @()
    # 首次运行：如果用户已经有默认 ~/.dsh，自动收编，省得手动添加
    $legacy = Join-Path $env:USERPROFILE '.dsh'
    if (Test-Path $legacy) {
        $agents = Join-Path $env:USERPROFILE '.agents'
        $list += [pscustomobject]@{ name = '默认环境'; home = $legacy; agents = $agents }
    }
    [pscustomobject]@{ lastHome = ''; instances = @($list) }
}
function Load-Data {
    $c = Get-Config
    # 一次性迁移：旧版把 instances.json 放在脚本目录
    $legacyData = Join-Path $c.Root 'instances.json'
    if ((-not (Test-Path $c.DataFile)) -and (Test-Path $legacyData)) {
        try { Copy-Item $legacyData $c.DataFile -Force; Write-Log '已从旧位置迁移 instances.json' } catch {}
    }
    if (Test-Path $c.DataFile) {
        try {
            $d = Get-Content -Raw -Encoding UTF8 -Path $c.DataFile | ConvertFrom-Json
            if (-not ($d.PSObject.Properties.Name -contains 'lastHome')) { $d | Add-Member -NotePropertyName lastHome -NotePropertyValue '' -Force }
            # 展开 %USERPROFILE% 之类的占位符，让同一份实例表可以跨机器复制
            if ($d.instances) {
                foreach ($i in @($d.instances)) {
                    if ($i.home) { $i.home = [Environment]::ExpandEnvironmentVariables([string]$i.home) }
                    if ($i.agents) { $i.agents = [Environment]::ExpandEnvironmentVariables([string]$i.agents) }
                }
                return $d
            }
        } catch { Write-Log "读取实例表失败: $($_.Exception.Message)" }
    }
    $d = New-DefaultData; Save-Data $d; $d
}
function Save-Data($d) {
    # 先写临时文件 → 自校验 → 备份旧文件 → 原子替换；全程 UTF-8 无 BOM。
    # 注意：Windows PowerShell 5.1 的 Set-Content -Encoding UTF8 会写 BOM，
    # 而 DSH 用 JSON.parse 读配置，BOM 会导致解析失败（0.2.1-rc.5 实测）。
    $c = Get-Config
    try {
        $json = ($d | ConvertTo-Json -Depth 6)
        [void]($json | ConvertFrom-Json)                       # 自校验：解析不了就不落盘
        $tmp = $c.DataFile + '.tmp'
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $c.DataFile) {
            Copy-Item -LiteralPath $c.DataFile -Destination ($c.DataFile + '.bak') -Force
        }
        Move-Item -LiteralPath $tmp -Destination $c.DataFile -Force
    } catch { Write-Log "保存实例表失败: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 配置预检（只读）
function Get-ProfileHealth([string]$homeDir) {
    $r = @{ ok = $true; status = 'ok'; summary = ''; errors = @(); warnings = @() }
    if (-not $homeDir -or -not (Test-Path -LiteralPath $homeDir)) {
        $r.ok = $false; $r.status = 'err'; $r.summary = '目录不存在'
        return [pscustomobject]$r
    }
    # 全新环境：还没有 profiles 目录，DSH 首次启动时才会生成配置 —— 这不算错
    if (-not (Test-Path -LiteralPath (Join-Path $homeDir 'profiles'))) {
        $r.status = 'new'; $r.summary = '新环境（首次启动时生成配置）'
        return [pscustomobject]$r
    }
    $prof = Join-Path $homeDir 'profiles\desktop'
    if (-not (Test-Path -LiteralPath $prof)) {
        $r.ok = $false; $r.status = 'err'; $r.summary = '缺少 profiles\desktop'
        return [pscustomobject]$r
    }
    $pj = Join-Path $prof 'package.json'
    if (-not (Test-Path -LiteralPath $pj)) {
        $r.ok = $false; $r.status = 'err'; $r.summary = '缺少 package.json'
        return [pscustomobject]$r
    }
    $bytes = [IO.File]::ReadAllBytes($pj)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $r.errors += 'package.json 带 UTF-8 BOM（升级后 DSH 会解析失败）'
    }
    $j = $null
    try {
        $txt = [IO.File]::ReadAllText($pj).TrimStart([char]0xFEFF)
        $j = $txt | ConvertFrom-Json
    } catch { $r.errors += ('package.json 解析失败: ' + $_.Exception.Message) }

    $cy = Join-Path $prof 'cordis.patch.yml'
    if (Test-Path -LiteralPath $cy) {
        $b2 = [IO.File]::ReadAllBytes($cy)
        if ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF) {
            $r.warnings += 'cordis.patch.yml 带 UTF-8 BOM'
        }
        if ($b2.Length -eq 0) { $r.warnings += 'cordis.patch.yml 是空文件' }
    }
    if ($j -and $j.dsh -and $j.dsh.profile -and $j.dsh.profile.bundles) {
        $nm = Join-Path $prof 'node_modules'
        foreach ($b in @($j.dsh.profile.bundles)) {
            if (-not $b) { continue }
            if ($b -like '@deepseek-ai/*') { continue }        # 官方包从安装目录解析，不在 profile 里
            if (-not (Test-Path -LiteralPath (Join-Path $nm $b))) {
                $r.warnings += ('bundles 里的 ' + $b + ' 在 node_modules 中不存在')
            }
        }
    }
    if ($r.errors.Count -gt 0) { $r.ok = $false; $r.status = 'err'; $r.summary = ($r.errors -join '；') }
    elseif ($r.warnings.Count -gt 0) { $r.status = 'warn'; $r.summary = ($r.warnings -join '；') }
    return [pscustomobject]$r
}

# ---------------------------------------------------------------- 进程
function Get-DshProcs {
    $c = Get-Config
    if (-not $c.Exe) { return @() }
    @(Get-Process -Name $c.ProcName -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -ieq $c.Exe) })
}
function Stop-Dsh([int]$timeoutSec = 4) {
    $c = Get-Config
    try { Remove-Item $c.MarkerFile -Force -ErrorAction SilentlyContinue } catch {}
    $procs = Get-DshProcs
    if ($procs.Count -eq 0) { return @{ ok = $true; message = '当前没有运行中的环境' } }
    # Electron 的子进程没有主窗口，对它们发 CloseMainWindow 没意义。
    # 只礼貌关闭有窗口的进程；若应用确实没响应，再统一强制结束。
    $withWindow = @($procs | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($withWindow.Count -eq 0) { $withWindow = @($procs) }
    foreach ($p in $withWindow) { try { [void]$p.CloseMainWindow() } catch {} }
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) { if ((Get-DshProcs).Count -eq 0) { return @{ ok = $true; message = '已关闭' } }; Start-Sleep -Milliseconds 250 }
    foreach ($p in (Get-DshProcs)) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {} }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) { if ((Get-DshProcs).Count -eq 0) { return @{ ok = $true; message = '已强制结束' } }; Start-Sleep -Milliseconds 250 }
    return @{ ok = $false; message = '有进程没能退出' }
}
function Start-Dsh([string]$homeDir, [string]$agentsDir) {
    $c = Get-Config
    if (-not $c.Exe) { return @{ ok = $false; message = '还没设置 DSH 程序路径，请先在界面上设置' } }
    if (-not $homeDir -or -not (Test-Path $homeDir)) { return @{ ok = $false; message = "环境目录不存在: $homeDir" } }
    $kill = Stop-Dsh
    if (-not $kill.ok) { return @{ ok = $false; message = '旧环境没能完全退出，已中止' } }
    Start-Sleep -Milliseconds 500
    $old = @{ H = $env:DSH_HOME; A = $env:DSH_AGENTS_HOME; P = $env:DSH_PROFILE; N = $env:NODE_OPTIONS }
    try {
        $env:DSH_HOME = $homeDir
        if ($agentsDir) { $env:DSH_AGENTS_HOME = $agentsDir } else { Remove-Item Env:DSH_AGENTS_HOME -ErrorAction SilentlyContinue }
        $env:DSH_PROFILE = 'desktop'; $env:NODE_OPTIONS = ''
        $p = Start-Process -FilePath $c.Exe -PassThru
    } finally {
        $env:DSH_HOME = $old.H; $env:DSH_AGENTS_HOME = $old.A; $env:DSH_PROFILE = $old.P; $env:NODE_OPTIONS = $old.N
    }
    if (-not $p) { return @{ ok = $false; message = '启动失败：没有拿到进程句柄' } }
    try { Write-Text $c.MarkerFile (@{ home = $homeDir; pid = $p.Id; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json) } catch {}
    return @{ ok = $true; message = '已启动，正在打开窗口…' }
}

# ---------------------------------------------------------------- profile
function Get-Profiles([string]$homeDir) {
    if (-not $homeDir) { return @() }
    $pd = Join-Path $homeDir 'profiles'
    if (-not (Test-Path $pd)) { return @() }
    $res = @()
    # 备份/占位目录不是可用配置方案，不能暴露在下拉框里。
    Get-ChildItem $pd -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne 'desktop' -and $_.Name -notlike '*.bak*' -and $_.Name -notlike 'desktop.stub-*' -and $_.Name -notlike 'desktop.bak-*'
    } | ForEach-Object {
        $res += [pscustomobject]@{ name = $_.Name; path = $_.FullName; current = $false }
    }
    $link = Join-Path $pd 'desktop'
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.LinkType -and $item.Target) {
            $leaf = Split-Path -Leaf ($item.Target -join '')
            $hit = $res | Where-Object { $_.name -eq $leaf }
            if ($hit) { $hit.current = $true }
            else { $res += [pscustomobject]@{ name = "$leaf (external)"; path = ($item.Target -join ''); current = $true } }
        } else { $res += [pscustomobject]@{ name = 'desktop'; path = $link; current = $true } }
    }
    @($res | Sort-Object @{ Expression = { if ($_.current) { 0 } else { 1 } } }, name)
}
function New-Profile([string]$homeDir, [string]$name) {
    $dir = Join-Path (Join-Path $homeDir 'profiles') $name
    if (Test-Path $dir) { return @{ ok = $false; message = "已经有一个叫 $name 的配置方案了" } }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pkg = [ordered]@{ name = "dsh-profile-$name"; private = $true; dsh = [ordered]@{ profile = [ordered]@{ bundles = @('@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app') } } } | ConvertTo-Json -Depth 6
    Write-Text (Join-Path $dir 'package.json') $pkg
    Write-Text (Join-Path $dir 'cordis.patch.yml') "# 这一层的加载项覆盖写在这里。`n[]`n"
    Write-Text (Join-Path $dir 'cordis.yml') "# 入口列表，保持空数组即可。`n[]`n"
    Write-Text (Join-Path $dir 'pnpm-workspace.yaml') "packages:`n  - .`n`nnodeLinker: hoisted`nautoInstallPeers: false"
    @{ ok = $true; message = "已新建配置方案: $name" }
}
function Set-CurrentProfile([string]$homeDir, [string]$name) {
    if (-not $name -or $name -notmatch '^[A-Za-z0-9._-]+$' -or $name -eq '.' -or $name -eq '..') {
        return @{ ok = $false; message = '配置方案名不合法' }
    }
    $pd = Join-Path $homeDir 'profiles'
    $target = Join-Path $pd $name
    if (-not (Test-Path $target)) { return @{ ok = $false; message = "没有这个配置方案: $name" } }
    if ((Get-DshProcs).Count -gt 0) { return @{ ok = $false; message = '请先停止运行中的环境，再切换配置方案' } }
    $link = Join-Path $pd 'desktop'
    $targetFull = [IO.Path]::GetFullPath($target).TrimEnd('\')

    # 「desktop」永远代表当前入口，切到自己必须是纯 no-op。
    # 旧实现会先把它改名为 backup，再尝试创建指向自身的 junction，最终把环境弄坏。
    if ($name -eq 'desktop') {
        return @{ ok = $true; message = '当前已经是这个配置方案' }
    }
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.LinkType -and $item.Target) {
            $currentTarget = [IO.Path]::GetFullPath(($item.Target | Select-Object -First 1)).TrimEnd('\')
            if ($currentTarget -ieq $targetFull) { return @{ ok = $true; message = '当前已经是这个配置方案' } }
            cmd /c ('rmdir "' + $link + '"') | Out-Null
        }
        else { $bak = Join-Path $pd ("desktop.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')); Rename-Item -Path $link -NewName (Split-Path -Leaf $bak) }
    }
    if (-not (Test-Path $target)) { return @{ ok = $false; message = '目标配置方案在切换过程中消失了' } }
    if (-not (Test-Path $link)) {
        try { New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null }
        catch { return @{ ok = $false; message = ('创建配置方案入口失败：' + $_.Exception.Message) } }
    }
    @{ ok = $true; message = "已切换到配置方案: $name" }
}
function Remove-Profile([string]$homeDir, [string]$name) {
    if (-not $name) { return @{ ok = $false; message = '没有指定名字' } }
    if ($name -notmatch '^[A-Za-z0-9._-]+$' -or $name -eq '.' -or $name -eq '..') { return @{ ok = $false; message = '配置方案名不合法' } }
    if ($name -eq 'desktop') { return @{ ok = $false; message = 'desktop 是配置方案的保留名' } }
    $dir = Join-Path (Join-Path $homeDir 'profiles') $name
    if (-not (Test-Path $dir)) { return @{ ok = $false; message = "没有这个配置方案: $name" } }
    if (@(Get-Profiles $homeDir | Where-Object { $_.name -eq $name -and $_.current }).Count -gt 0) { return @{ ok = $false; message = "「$name」正在使用中，请先切换到其他方案" } }
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $dir) { return @{ ok = $false; message = '删除失败（可能被占用）' } }
    @{ ok = $true; message = "已删除配置方案: $name" }
}
function Undo-Profile([string]$homeDir) {
    $pd = Join-Path $homeDir 'profiles'; $link = Join-Path $pd 'desktop'
    if ((Get-DshProcs).Count -gt 0) { return @{ ok = $false; message = '请先停止 DSH，再撤销方案切换' } }
    $bak = Get-ChildItem $pd -Directory -Force -ErrorAction SilentlyContinue | Where-Object Name -like 'desktop.bak-*' | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $bak) { return @{ ok = $false; message = '没有可撤销的方案切换' } }
    if (Test-Path $link) {
        $it = Get-Item $link -Force
        if (-not $it.LinkType) { return @{ ok = $false; message = '当前没有可撤销的方案切换' } }
        cmd /c ('rmdir "' + $link + '"') | Out-Null
    }
    Rename-Item $bak.FullName 'desktop'
    @{ ok = $true; message = '已撤销上次方案切换' }
}

# ---------------------------------------------------------------- 插件 / 技能
function Get-Plugins($inst) {
    $res = @()
    if (-not $inst -or -not $inst.home) { return $res }
    $pd = Join-Path $inst.home 'profiles'
    if (-not (Test-Path $pd)) { return $res }
    foreach ($prof in (Get-ChildItem $pd -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -notlike '*.bak*' -and $_.Name -notlike 'desktop.stub-*' -and $_.Name -notlike 'desktop.bak-*'
            })) {
        $pj = Join-Path $prof.FullName 'package.json'
        if (Test-Path $pj) {
            try {
                $j = Get-Content $pj -Raw | ConvertFrom-Json
                foreach ($b in @($j.dsh.profile.bundles)) { if ($b) { $res += [pscustomobject]@{ profile = $prof.Name; kind = 'bundle'; name = $b; note = '清单里声明' } } }
                if ($j.dependencies) { foreach ($d in $j.dependencies.PSObject.Properties) { $res += [pscustomobject]@{ profile = $prof.Name; kind = 'dep'; name = $d.Name; note = [string]$d.Value } } }
            } catch {}
        }
        $nm = Join-Path $prof.FullName 'node_modules'
        if (Test-Path $nm) {
            Get-ChildItem $nm -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' } | ForEach-Object {
                $note = if ($_.LinkType -and $_.Target) { '已安装（链接 → ' + ($_.Target -join '') + '）' } else { '已安装' }
                $res += [pscustomobject]@{ profile = $prof.Name; kind = 'installed'; name = $_.Name; note = $note }
            }
        }
    }
    $res
}
function Get-Skills($inst) {
    $res = @()
    if (-not $inst) { return $res }
    $roots = @()
    if ($inst.agents) { $roots += @{ k = 'agents'; p = (Join-Path $inst.agents 'skills') } }
    if ($inst.home) { $roots += @{ k = 'home'; p = (Join-Path $inst.home 'skills') } }
    foreach ($r in $roots) {
        if (-not (Test-Path $r.p)) { continue }
        Get-ChildItem $r.p -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $m = Read-SkillMeta $_.FullName
            $res += [pscustomobject]@{ src = $r.k; name = $m.name; desc = $m.desc }
        }
    }
    $res
}
function Read-SkillMeta([string]$dir) {
    $f = Join-Path $dir 'SKILL.md'; $name = Split-Path -Leaf $dir; $desc = ''
    if (Test-Path $f) {
        $lines = @(Get-Content $f -TotalCount 40 -Encoding UTF8 -ErrorAction SilentlyContinue)
        $inDesc = $false
        foreach ($l in $lines) {
            if ($l -match '^name:\s*(.+)$') { $name = $matches[1].Trim() }
            elseif ($l -match '^description:\s*(.*)$') { $desc = $matches[1].Trim(); $inDesc = $true }
            elseif ($inDesc -and $l -match '^\s+(\S.*)$') { $desc = ($desc + ' ' + $matches[1].Trim()) }
            elseif ($inDesc) { break }
        }
    }
    $desc = $desc -replace '^[>|]\s*', '' -replace '^"', '' -replace '"$', ''
    if ($desc.Length -gt 220) { $desc = $desc.Substring(0, 220) + ' …' }
    [pscustomobject]@{ name = $name; desc = $desc }
}
function Get-PluginCount($inst) {
    # 同一个插件会同时以 bundle/dep/installed 出现；给用户看的是“去重后的插件数”。
    try { @(Get-Plugins $inst | Where-Object { $_.name } | Group-Object name).Count } catch { 0 }
}
function Get-SkillCount($inst) { try { @(Get-Skills $inst).Count } catch { 0 } }

# ---------------------------------------------------------------- 当前运行的是哪套
function Get-CurrentHome {
    $c = Get-Config
    if (Test-Path $c.MarkerFile) {
        try {
            $m = Get-Content $c.MarkerFile -Raw | ConvertFrom-Json
            if ($m.home -and $m.pid -and (Get-Process -Id ([int]$m.pid) -ErrorAction SilentlyContinue)) { return [string]$m.home }
        } catch {}
    }
    $best = ''; $bestTime = [datetime]::MinValue
    foreach ($inst in $script:Data.instances) {
        foreach ($sub in @('sessions', 'storages', 'cache')) {
            $dir = Join-Path $inst.home $sub
            if (-not (Test-Path $dir)) { continue }
            $f = @(Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            if ($f.Count -gt 0 -and $f[0].LastWriteTime -gt $bestTime) { $bestTime = $f[0].LastWriteTime; $best = $inst.home }
        }
    }
    if ($best -and ((Get-Date) - $bestTime).TotalHours -lt 24) { return $best }
    ''
}

# ---------------------------------------------------------------- 路径处理（新建环境用）
function Resolve-PathExpanded([string]$p) {
    if (-not $p) { return '' }
    $p = $p.Trim().Trim('"')
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '%[^%]+%') { return '' }              # 还有展开不了的占位符
    if (-not [IO.Path]::IsPathRooted($p)) { return '' } # 相对路径不接受
    try { $p = [IO.Path]::GetFullPath($p) } catch { return '' }
    $p = $p.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { $p = $p + '\' }      # 盘符根保留反斜杠，交给 Test-NewHomePath 拒绝
    return $p
}

function Test-NewHomePath([string]$path) {
    if (-not $path) { return @{ ok = $false; message = '目录不能为空' } }
    if (-not [IO.Path]::IsPathRooted($path)) { return @{ ok = $false; message = '请填绝对路径，例如 D:\dsh\work\home' } }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') { return @{ ok = $false; message = '不能直接放在盘符根目录' } }
    foreach ($s in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($s -and $full.StartsWith($s.TrimEnd('\'), 'OrdinalIgnoreCase')) {
            return @{ ok = $false; message = ('不能放在系统目录：' + $s) }
        }
    }
    if (Test-Path -LiteralPath $full) {
        $it = Get-Item -LiteralPath $full -Force
        if (-not $it.PSIsContainer) { return @{ ok = $false; message = '这个路径已经是一个文件' } }
        $n = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { return @{ ok = $false; message = '目录已存在且非空，请换一个（或先清空）' } }
    }

    # ---- 卷是否存在 / 可写 / 空间够不够（用户随便填路径时最常踩的三个坑）
    $root = [IO.Path]::GetPathRoot($full)
    if (-not $root) { return @{ ok = $false; message = '路径不合法' } }
    $drive = $null
    try { $drive = New-Object System.IO.DriveInfo($root) } catch { return @{ ok = $false; message = ('盘符无法识别：' + $root) } }
    if (-not $drive.IsReady) { return @{ ok = $false; message = ('磁盘不可用（没插/没连上）：' + $root) } }
    if ($drive.AvailableFreeSpace -lt 500MB) {
        return @{ ok = $false; message = ('该盘剩余空间不足 500 MB（当前 ' + [math]::Round($drive.AvailableFreeSpace / 1MB) + ' MB），DSH 首次启动要装依赖') }
    }
    # 找到最近的已存在祖先目录做写权限探测
    $probe = $full
    while ($probe -and -not (Test-Path -LiteralPath $probe)) { $probe = Split-Path $probe -Parent }
    if (-not $probe) { $probe = $root }
    $tmpFile = Join-Path $probe ('.dshm-write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [IO.File]::WriteAllText($tmpFile, 'ok')
        Remove-Item -LiteralPath $tmpFile -Force
    } catch {
        return @{ ok = $false; message = ('没有写入权限：' + $probe) }
    }
    $warn = ''
    if ($full.Length -gt 200) { $warn = '路径偏长（超过 200 字符），个别工具可能出错' }
    return @{ ok = $true; path = $full; warning = $warn }
}

function Test-ExistingHomePath([string]$path) {
    if (-not $path) { return @{ ok = $false; message = '目录不能为空' } }
    if (-not [IO.Path]::IsPathRooted($path)) { return @{ ok = $false; message = '请填绝对路径' } }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') { return @{ ok = $false; message = '不能直接使用盘符根目录' } }
    if (-not (Test-Path -LiteralPath $full)) { return @{ ok = $false; message = '目录不存在' } }
    $it = Get-Item -LiteralPath $full -Force
    if (-not $it.PSIsContainer) { return @{ ok = $false; message = '这个路径不是目录' } }
    foreach ($s in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($s -and $full.StartsWith($s.TrimEnd('\'), 'OrdinalIgnoreCase')) {
            return @{ ok = $false; message = ('不能使用系统目录：' + $s) }
        }
    }
    return @{ ok = $true; path = $full }
}

function Get-DefaultHomePath([string]$name) {
    $c = Get-Config
    return (Join-Path (Join-Path $c.InstancesRoot $name) 'home')
}

# ---------------------------------------------------------------- 环境迁移
# 迁移原则：先复制到临时目录并校验，成功后再切换记录；原目录默认保留。
# 复制时保留 junction / symlink，并只把“指向源环境内部”的链接改指向新环境。
function Get-DshNormalizedPath([string]$path) {
    if (-not $path) { return '' }
    try {
        $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($path)).TrimEnd('\')
        if ($full -match '^[A-Za-z]:$') { $full += '\' }
        return $full
    } catch { return '' }
}

function Test-DshPathWithin([string]$child, [string]$parent) {
    $c = Get-DshNormalizedPath $child
    $p = Get-DshNormalizedPath $parent
    if (-not $c -or -not $p) { return $false }
    if ($c -ieq $p) { return $true }
    $prefix = if ($p.EndsWith('\')) { $p } else { $p + '\' }
    return $c.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-DshTreeStats([string]$root) {
    $files = 0; $dirs = 0; $links = 0; $errors = 0
    $bytes = [long]0
    if (-not (Test-Path -LiteralPath $root)) {
        return [pscustomobject]@{ files = 0; dirs = 0; links = 0; bytes = 0; errors = 1 }
    }
    $stack = New-Object System.Collections.Stack
    $stack.Push([IO.Path]::GetFullPath($root))
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        try { $items = [IO.Directory]::GetFileSystemEntries($dir) } catch { $errors++; continue }
        foreach ($full in $items) {
            try {
                $attr = [IO.File]::GetAttributes($full)
                if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $links++
                } elseif (($attr -band [IO.FileAttributes]::Directory) -ne 0) {
                    $dirs++; $stack.Push($full)
                } else {
                    $files++; $bytes += [long]([IO.FileInfo]$full).Length
                }
            } catch { $errors++ }
        }
    }
    return [pscustomobject]@{ files = $files; dirs = $dirs; links = $links; bytes = $bytes; errors = $errors }
}

function Test-DshTreeStatsEqual($a, $b) {
    return ($a.errors -eq 0 -and $b.errors -eq 0 -and
        $a.files -eq $b.files -and $a.dirs -eq $b.dirs -and
        $a.links -eq $b.links -and $a.bytes -eq $b.bytes)
}

function Get-DshReparseEntries([string]$root) {
    $out = @()
    if (-not (Test-Path -LiteralPath $root)) { return $out }
    $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
    $stack = New-Object System.Collections.Stack
    $stack.Push($fullRoot)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        try { $items = [IO.Directory]::GetFileSystemEntries($dir) } catch { continue }
        foreach ($full in $items) {
            try {
                $attr = [IO.File]::GetAttributes($full)
                if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
                    $target = @($item.Target) | Select-Object -First 1
                    $out += [pscustomobject]@{
                        path = $full
                        rel = $full.Substring($fullRoot.Length).TrimStart('\')
                        target = [string]$target
                        isDir = (($attr -band [IO.FileAttributes]::Directory) -ne 0)
                    }
                } elseif (($attr -band [IO.FileAttributes]::Directory) -ne 0) {
                    $stack.Push($full)
                }
            } catch {}
        }
    }
    return $out
}

function Invoke-DshTreeCopy([string]$source, [string]$dest) {
    $robo = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    if (-not (Test-Path -LiteralPath $robo)) { return @{ ok = $false; message = '系统缺少 robocopy.exe，无法安全复制大目录' } }
    if (Test-Path -LiteralPath $dest) {
        if (@(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            return @{ ok = $false; message = ('临时目录已存在且非空：' + $dest) }
        }
    } else {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
    }
    $log = Join-Path (Get-Config).Home 'migration.log'
    $args = @($source, $dest, '/E', '/COPY:DAT', '/DCOPY:DAT', '/SJ', '/SL', '/R:1', '/W:1',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP', ('/LOG+:' + $log))
    & $robo @args | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { return @{ ok = $false; message = ('复制失败（robocopy 返回 ' + $code + '），详情见 ' + $log) } }
    return @{ ok = $true; code = $code }
}

function Remove-DshTreeSafe([string]$root) {
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { return }
    $full = [IO.Path]::GetFullPath($root)
    foreach ($link in @(Get-DshReparseEntries $full | Sort-Object { $_.rel.Length } -Descending)) {
        try {
            if ($link.isDir) { cmd /c ('rmdir "' + $link.path + '"') | Out-Null }
            else { Remove-Item -LiteralPath $link.path -Force -ErrorAction Stop }
        } catch {}
    }
    try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop } catch {}
}

function Repair-DshInternalLinks([string]$sourceRoot, [string]$targetRoot, $links) {
    $warnings = @()
    $src = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
    foreach ($link in @($links)) {
        if (-not $link -or -not $link.target) { continue }
        $target = [string]$link.target
        if (-not [IO.Path]::IsPathRooted($target)) {
            try { $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $link.path) $target)) } catch { continue }
        }
        if (-not (Test-DshPathWithin $target $src)) { continue }
        if ([IO.Path]::GetFullPath($target).TrimEnd('\') -ieq $src) { continue }
        $rel = $target.Substring($src.Length).TrimStart('\')
        if (-not $rel) { continue }
        $newTarget = Join-Path $targetRoot $rel
        if (-not (Test-Path -LiteralPath $newTarget)) {
            $warnings += ('链接目标不在新环境里：' + $newTarget)
            continue
        }
        $destLink = Join-Path $targetRoot $link.rel
        if (Test-Path -LiteralPath $destLink) {
            $it = Get-Item -LiteralPath $destLink -Force -ErrorAction SilentlyContinue
            if (-not $it -or -not $it.LinkType) {
                $warnings += ('目标位置的同名条目不是链接，已跳过：' + $destLink)
                continue
            }
            try {
                if ($link.isDir) { cmd /c ('rmdir "' + $destLink + '"') | Out-Null }
                else { Remove-Item -LiteralPath $destLink -Force -ErrorAction Stop }
            } catch {
                $warnings += ('无法更新链接：' + $destLink)
                continue
            }
        }
        try {
            if ($link.isDir) { New-Item -ItemType Junction -Path $destLink -Target $newTarget -ErrorAction Stop | Out-Null }
            else { New-Item -ItemType SymbolicLink -Path $destLink -Target $newTarget -ErrorAction Stop | Out-Null }
        } catch { $warnings += ('无法重建链接：' + $destLink + '（' + $_.Exception.Message + '）') }
    }
    return $warnings
}

function Move-DshEnvironment([string]$oldHome, [string]$newHome, [string]$agentsTarget, [bool]$migrateAgents, [bool]$retireSource, [switch]$ValidateOnly) {
    $inst = $script:Data.instances | Where-Object { $_.home -and ((Get-DshNormalizedPath $_.home) -ieq (Get-DshNormalizedPath $oldHome)) } | Select-Object -First 1
    if (-not $inst) { return @{ ok = $false; message = '找不到这个环境' } }
    $src = Get-DshNormalizedPath $inst.home
    if (-not $src -or -not (Test-Path -LiteralPath $src)) { return @{ ok = $false; message = '当前环境目录不存在' } }
    $srcChk = Test-ExistingHomePath $src
    if (-not $srcChk.ok) { return $srcChk }

    $new = Resolve-PathExpanded $newHome
    if (-not $new) { return @{ ok = $false; message = '新环境目录无效：请填写绝对路径，且不要使用未展开的 %变量%' } }
    $new = Get-DshNormalizedPath $new
    if ($new -ieq $src) { return @{ ok = $false; message = '新目录和当前目录相同，不需要迁移' } }
    if ((Test-DshPathWithin $new $src) -or (Test-DshPathWithin $src $new)) {
        return @{ ok = $false; message = '新目录不能放在当前环境里面，也不能包含当前环境' }
    }
    $newChk = Test-NewHomePath $new
    if (-not $newChk.ok) { return $newChk }
    $new = [string]$newChk.path

    foreach ($other in $script:Data.instances) {
        if ($other.home -and ((Get-DshNormalizedPath $other.home) -ieq (Get-DshNormalizedPath $inst.home))) { continue }
        $oh = Get-DshNormalizedPath $other.home
        $oa = Get-DshNormalizedPath $other.agents
        if ($oh -and ((Test-DshPathWithin $new $oh) -or (Test-DshPathWithin $oh $new))) {
            return @{ ok = $false; message = ('新目录与已有环境「' + $other.name + '」重叠') }
        }
        if ($oa -and ((Test-DshPathWithin $new $oa) -or (Test-DshPathWithin $oa $new))) {
            return @{ ok = $false; message = ('新目录与已有环境「' + $other.name + '」的技能目录重叠') }
        }
        if (($oh -and (Test-DshPathWithin $oh $src)) -or ($oa -and (Test-DshPathWithin $oa $src))) {
            return @{ ok = $false; message = ('当前目录里还有另一个环境「' + $other.name + '」，不能整体迁移') }
        }
    }

    $oldAgents = Get-DshNormalizedPath $inst.agents
    $agentsInsideHome = [bool]($oldAgents -and (Test-DshPathWithin $oldAgents $src))
    $agentsFinal = $oldAgents
    $copyAgents = $false
    if ($agentsInsideHome) {
        $relAgents = $oldAgents.Substring($src.Length).TrimStart('\')
        $agentsFinal = if ($relAgents) { Join-Path $new $relAgents } else { $new }
    } elseif ($migrateAgents) {
        if (-not $oldAgents -or -not (Test-Path -LiteralPath $oldAgents)) {
            return @{ ok = $false; message = '当前技能目录不存在，无法一起迁移' }
        }
        $ag = Resolve-PathExpanded $agentsTarget
        if (-not $ag) { return @{ ok = $false; message = '新技能目录无效，请填写绝对路径' } }
        $agentsFinal = Get-DshNormalizedPath $ag
        if ($agentsFinal -ieq $oldAgents) { return @{ ok = $false; message = '新技能目录和当前技能目录相同' } }
        if ((Test-DshPathWithin $agentsFinal $oldAgents) -or (Test-DshPathWithin $oldAgents $agentsFinal)) {
            return @{ ok = $false; message = '新技能目录不能与当前技能目录互相包含' }
        }
        if (Test-DshPathWithin $agentsFinal $new) {
            return @{ ok = $false; message = '技能目录不能放进新环境目录里；请放在它的旁边，例如 D:\dsh\work\agents' }
        }
        if ((Test-DshPathWithin $new $agentsFinal)) {
            return @{ ok = $false; message = '新技能目录不能包含新环境目录' }
        }
        $agChk = Test-NewHomePath $agentsFinal
        if (-not $agChk.ok) { return $agChk }
        $agentsFinal = [string]$agChk.path
        $copyAgents = $true
        $shared = @($script:Data.instances | Where-Object {
            $_ -and $_.name -ne $inst.name -and $_.agents -and ((Get-DshNormalizedPath $_.agents) -ieq $oldAgents)
        })
        if ($shared.Count -gt 0) { return @{ ok = $false; message = ('技能目录与「' + $shared[0].name + '」共用，不能单独迁走') } }
        foreach ($other in $script:Data.instances) {
            $oh = Get-DshNormalizedPath $other.home
            $oa = Get-DshNormalizedPath $other.agents
            if ($oa -and ($oa -ieq $agentsFinal)) { return @{ ok = $false; message = ('新技能目录已被环境「' + $other.name + '」使用') } }
            if ($oa -and ((Test-DshPathWithin $agentsFinal $oa) -or (Test-DshPathWithin $oa $agentsFinal))) {
                return @{ ok = $false; message = ('新技能目录与已有环境「' + $other.name + '」的技能目录重叠') }
            }
            if ($oh -and ((Test-DshPathWithin $agentsFinal $oh) -or (Test-DshPathWithin $oh $agentsFinal))) {
                return @{ ok = $false; message = ('新技能目录与已有环境「' + $other.name + '」的环境目录重叠') }
            }
        }
    }

    if ($ValidateOnly) {
        return @{ ok = $true; message = '迁移参数校验通过'; data = @{ home = $new; agents = $agentsFinal; migrateAgents = $copyAgents } }
    }
    if ((Get-DshProcs).Count -gt 0) { return @{ ok = $false; message = '还有 DSH 实例在运行，请先停止后再迁移' } }

    $homeLinks = @(Get-DshReparseEntries $src)
    $homeStats = Get-DshTreeStats $src
    if ($homeStats.errors -gt 0) { return @{ ok = $false; message = '有文件无法读取，迁移已中止（源目录未改动）' } }
    $needBytes = [long]$homeStats.bytes
    $agentsStats = $null
    $agentsLinks = @()
    if ($copyAgents) {
        $agentsStats = Get-DshTreeStats $oldAgents
        if ($agentsStats.errors -gt 0) { return @{ ok = $false; message = '技能目录里有文件无法读取，迁移已中止' } }
        $agentsLinks = @(Get-DshReparseEntries $oldAgents)
        $needBytes += [long]$agentsStats.bytes
    }
    try {
        $root = [IO.Path]::GetPathRoot($new)
        $drive = New-Object System.IO.DriveInfo($root)
        if (-not $drive.IsReady) { return @{ ok = $false; message = ('目标磁盘不可用：' + $root) } }
        if ($drive.AvailableFreeSpace -lt ($needBytes + 200MB)) {
            $needMb = [math]::Ceiling($needBytes / 1MB)
            $freeMb = [math]::Floor($drive.AvailableFreeSpace / 1MB)
            return @{ ok = $false; message = ('目标磁盘空间不足：预计需要 ' + $needMb + ' MB，当前剩余 ' + $freeMb + ' MB') }
        }
    } catch { return @{ ok = $false; message = ('无法检查目标磁盘：' + $_.Exception.Message) } }

    $stamp = Get-Date -Format 'yyyyMMddHHmmssfff'
    $tmpHome = $new + '.dsh-switch-tmp-' + $stamp
    $tmpAgents = if ($copyAgents) { $agentsFinal + '.dsh-switch-tmp-' + $stamp } else { '' }
    $newParent = Split-Path -Parent $new
    try { if (-not (Test-Path -LiteralPath $newParent)) { New-Item -ItemType Directory -Force -Path $newParent | Out-Null } } catch {
        return @{ ok = $false; message = ('无法创建目标上级目录：' + $_.Exception.Message) }
    }

    $r = Invoke-DshTreeCopy $src $tmpHome
    if (-not $r.ok) { Remove-DshTreeSafe $tmpHome; return $r }
    $tmpStats = Get-DshTreeStats $tmpHome
    if (-not (Test-DshTreeStatsEqual $homeStats $tmpStats)) {
        Remove-DshTreeSafe $tmpHome
        return @{ ok = $false; message = '复制校验失败（文件数量或大小不一致），源目录未改动' }
    }
    if ($copyAgents) {
        try { if (-not (Test-Path -LiteralPath (Split-Path -Parent $agentsFinal))) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $agentsFinal) | Out-Null } } catch {
            Remove-DshTreeSafe $tmpHome; return @{ ok = $false; message = ('无法创建技能目录的上级目录：' + $_.Exception.Message) }
        }
        $r = Invoke-DshTreeCopy $oldAgents $tmpAgents
        if (-not $r.ok) { Remove-DshTreeSafe $tmpHome; Remove-DshTreeSafe $tmpAgents; return $r }
        if (-not (Test-DshTreeStatsEqual $agentsStats (Get-DshTreeStats $tmpAgents))) {
            Remove-DshTreeSafe $tmpHome; Remove-DshTreeSafe $tmpAgents
            return @{ ok = $false; message = '技能目录复制校验失败，源目录未改动' }
        }
    }

    $movedHome = $false; $movedAgents = $false
    try {
        if (Test-Path -LiteralPath $new) {
            if (@(Get-ChildItem -LiteralPath $new -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw '目标目录在复制期间变成了非空目录' }
            Remove-Item -LiteralPath $new -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $tmpHome -Destination $new -ErrorAction Stop
        $movedHome = $true
        $warnings = @(Repair-DshInternalLinks $src $new $homeLinks)
        if ($copyAgents) {
            if (Test-Path -LiteralPath $agentsFinal) {
                if (@(Get-ChildItem -LiteralPath $agentsFinal -Force -ErrorAction SilentlyContinue).Count -gt 0) { throw '技能目标目录在复制期间变成了非空目录' }
                Remove-Item -LiteralPath $agentsFinal -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $tmpAgents -Destination $agentsFinal -ErrorAction Stop
            $movedAgents = $true
            $warnings += @(Repair-DshInternalLinks $oldAgents $agentsFinal $agentsLinks)
        }
    } catch {
        if ($movedAgents) { Remove-DshTreeSafe $agentsFinal }
        if ($movedHome) { Remove-DshTreeSafe $new }
        Remove-DshTreeSafe $tmpHome; if ($tmpAgents) { Remove-DshTreeSafe $tmpAgents }
        return @{ ok = $false; message = ('切换新目录失败，已取消并保留原环境：' + $_.Exception.Message) }
    }

    $oldHomeValue = [string]$inst.home
    $oldAgentsValue = [string]$inst.agents
    $oldLastHome = [string]$script:Data.lastHome
    $inst.home = $new
    $inst.agents = $agentsFinal
    if ($oldLastHome -and ((Get-DshNormalizedPath $oldLastHome) -ieq $src)) { $script:Data.lastHome = $new }
    Save-Data $script:Data

    $savedOk = $false
    try {
        $saved = Get-Content -LiteralPath (Get-Config).DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $hit = @($saved.instances | Where-Object { $_.home -and ((Get-DshNormalizedPath $_.home) -ieq $new) }) | Select-Object -First 1
        $savedOk = [bool]($hit -and ((Get-DshNormalizedPath $hit.agents) -ieq (Get-DshNormalizedPath $agentsFinal)))
    } catch {}
    if (-not $savedOk) {
        $inst.home = $oldHomeValue; $inst.agents = $oldAgentsValue; $script:Data.lastHome = $oldLastHome
        Save-Data $script:Data
        if ($movedHome) { Remove-DshTreeSafe $new }
        if ($movedAgents) { Remove-DshTreeSafe $agentsFinal }
        Remove-DshTreeSafe $tmpHome; if ($tmpAgents) { Remove-DshTreeSafe $tmpAgents }
        return @{ ok = $false; message = '环境记录保存失败，已回退到原目录' }
    }

    $retire = $null
    if ($retireSource) {
        $retire = Move-HomeToTrash $src $inst.name
    }
    $msg = ('已迁移「' + $inst.name + '」到 ' + $new)
    if ($copyAgents) { $msg += '；技能目录也已迁移到 ' + $agentsFinal }
    if ($warnings.Count -gt 0) { $msg += '；有 ' + $warnings.Count + ' 个链接需要留意（详情见日志）'; foreach ($w in $warnings) { Write-Log ('迁移链接提醒: ' + $w) } }
    if ($retireSource) {
        if ($retire -and $retire.ok) { $msg += '；原目录已移入回收站' }
        else { $msg += '；原目录保留（未能移入回收站：' + $(if ($retire) { $retire.message } else { '未知原因' }) + '）' }
    } else { $msg += '；原目录保留，可在确认无误后手动清理' }
    Write-Log $msg
    return @{ ok = $true; message = $msg; data = @{ home = $new; agents = $agentsFinal; oldHome = $src; retired = [bool]($retire -and $retire.ok) } }
}

# ---------------------------------------------------------------- 桌面快捷方式（DSH 相关）
function Get-ShortcutDirs {
    @(
        @{ key = '桌面';     path = [Environment]::GetFolderPath('Desktop') },
        @{ key = '公共桌面'; path = [Environment]::GetFolderPath('CommonDesktopDirectory') }
    )
}
function Get-ShortcutStashDir {
    $c = Get-Config
    $d = Join-Path $c.Home 'shortcuts-hidden'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}
function Get-ShortcutManifestFile { Join-Path (Get-Config).Home 'shortcuts.json' }
function Read-ShortcutManifest {
    $f = Get-ShortcutManifestFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $raw = $null
    try { $raw = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    $res = @()
    foreach ($x in @($raw)) {
        if (-not $x) { continue }
        # 兼容旧版本写坏的形状：{ value: [ {...} ], Count: n }
        if (($x.PSObject.Properties.Name -contains 'value') -and $x.value) {
            foreach ($y in @($x.value)) { if ($y -and $y.stash) { $res += $y } }
        } elseif ($x.stash) { $res += $x }
    }
    return $res
}
function Save-ShortcutManifest($list) {
    # 逐条序列化再拼数组：ConvertTo-Json -InputObject 在 PS5.1 里会把单元素数组包成 {value,Count}
    $f = Get-ShortcutManifestFile
    $items = @()
    foreach ($x in @($list)) {
        if (-not $x -or -not $x.stash) { continue }
        $obj = [pscustomobject]@{
            stash    = [string]$x.stash
            original = [string]$x.original
            area     = [string]$x.area
            name     = [string]$x.name
            target   = [string]$x.target
        }
        $items += (ConvertTo-Json -InputObject $obj -Compress -Depth 3)
    }
    $json = '[' + ($items -join ',') + ']'
    [IO.File]::WriteAllText($f, $json, (New-Object Text.UTF8Encoding($false)))
}
function Test-DshShortcut([string]$name, [string]$target) {
    if ($name -match '(?i)dsh|deepseek|harness') { return $true }
    if ($target -and ($target -match '(?i)deepseek|dsh-switch|dsh-super|\.dsh\\')) { return $true }
    return $false
}
function Test-ManagerShortcut([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
        $target = [string]$sc.TargetPath
        $args = [string]$sc.Arguments
        if ($target -and ($target -match '(?i)\\(DshManagerApp|dsh-switch)\.exe$')) { return $true }
        if ($target -match '(?i)powershell(\.exe)?$' -and $args -match '(?i)dsh-switch.*web\\start\.ps1') { return $true }
        if ($args -match '(?i)dsh-switch.*web\\start\.ps1') { return $true }
    } catch {}
    return $false
}
function Get-DshShortcuts {
    $out = @()
    $ws = $null
    try { $ws = New-Object -ComObject WScript.Shell } catch {}
    foreach ($d in Get-ShortcutDirs) {
        if (-not $d.path -or -not (Test-Path -LiteralPath $d.path)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d.path -Filter *.lnk -File -Force -ErrorAction SilentlyContinue)) {
            $t = ''
            if ($ws) { try { $t = [string]$ws.CreateShortcut($f.FullName).TargetPath } catch {} }
            if (Test-DshShortcut $f.Name $t) {
                $out += [pscustomobject]@{ area = $d.key; name = $f.Name; path = $f.FullName; target = $t; hidden = $false; self = (Test-ManagerShortcut $f.FullName) }
            }
        }
    }
    $stashDir = Get-ShortcutStashDir
    foreach ($m in (Read-ShortcutManifest)) {
        if (-not $m -or -not $m.stash) { continue }
        if (Test-Path -LiteralPath (Join-Path $stashDir $m.stash)) {
            $out += [pscustomobject]@{ area = $m.area; name = $m.name; path = $m.original; target = $m.target; hidden = $true; self = $false }
        }
    }
    return $out
}
function Set-DshShortcutHidden([string]$path, [bool]$hide) {
    $dirs = @(Get-ShortcutDirs | ForEach-Object { $_.path })
    $manifest = @(Read-ShortcutManifest)
    if (-not $path) { return @{ ok = $false; message = '没有指定快捷方式' } }
    $p = [IO.Path]::GetFullPath($path)
    if ($hide) {
        if (-not (Test-Path -LiteralPath $p)) { return @{ ok = $false; message = '快捷方式不存在' } }
        if ([IO.Path]::GetExtension($p) -ne '.lnk') { return @{ ok = $false; message = '只处理 .lnk 文件' } }
        if (Test-ManagerShortcut $p) { return @{ ok = $false; message = '不能隐藏管理器自己的快捷方式' } }
        $parent = Split-Path $p -Parent
        if ($dirs -notcontains $parent) { return @{ ok = $false; message = '只能操作桌面上的快捷方式' } }
        $area = ($(Get-ShortcutDirs | Where-Object { $_.path -eq $parent } | Select-Object -First 1).key)
        $target = ''
        try { $target = [string](New-Object -ComObject WScript.Shell).CreateShortcut($p).TargetPath } catch {}
        $stashName = (($(if ($area -eq '公共桌面') { 'p-' } else { 'u-' })) + [IO.Path]::GetFileName($p))
        $stash = Join-Path (Get-ShortcutStashDir) $stashName
        if (Test-Path -LiteralPath $stash) { $stash = Join-Path (Get-ShortcutStashDir) ((Get-Date -Format 'HHmmss') + '-' + $stashName) }
        Move-Item -LiteralPath $p -Destination $stash -Force
        $manifest += [pscustomobject]@{ stash = (Split-Path $stash -Leaf); original = $p; area = $area; name = [IO.Path]::GetFileName($p); target = $target }
        Save-ShortcutManifest $manifest
        return @{ ok = $true; message = '已隐藏（移到管理器备份目录，可随时恢复）' }
    }
    $found = @($manifest | Where-Object { $_ -and $_.original -eq $p }) | Select-Object -First 1
    if (-not $found) { return @{ ok = $false; message = '没有这条隐藏记录' } }
    $stash = Join-Path (Get-ShortcutStashDir) $found.stash
    if (-not (Test-Path -LiteralPath $stash)) { return @{ ok = $false; message = '备份文件已丢失' } }
    $parent = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $parent)) { return @{ ok = $false; message = '原来的桌面目录不存在' } }
    Move-Item -LiteralPath $stash -Destination $p -Force
    Save-ShortcutManifest (@($manifest | Where-Object { $_ -and $_.original -ne $p }))
    return @{ ok = $true; message = '已恢复显示' }
}

# ---------------------------------------------------------------- 删除环境目录（先进回收站）
# 设计：永远不直接抹掉，一律移到 %APPDATA%\dsh-manager\trash，可恢复；清空回收站要再确认一次。
function Get-TrashDir {
    $c = Get-Config
    $d = Join-Path $c.Home 'trash'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}
function Get-TrashManifestFile { Join-Path (Get-Config).Home 'trash.json' }
function Read-TrashManifest {
    $f = Get-TrashManifestFile
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    $raw = $null
    try { $raw = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    $res = @()
    foreach ($x in @($raw)) {
        if (-not $x) { continue }
        if (($x.PSObject.Properties.Name -contains 'value') -and $x.value) {
            foreach ($y in @($x.value)) { if ($y -and $y.trash) { $res += $y } }
        } elseif ($x.trash) { $res += $x }
    }
    return $res
}
function Save-TrashManifest($list) {
    $f = Get-TrashManifestFile
    $items = @()
    foreach ($x in @($list)) {
        if (-not $x -or -not $x.trash) { continue }
        $obj = [pscustomobject]@{
            name      = [string]$x.name
            original  = [string]$x.original
            trash     = [string]$x.trash
            at        = [string]$x.at
            sizeBytes = [double]$x.sizeBytes
        }
        $items += (ConvertTo-Json -InputObject $obj -Compress -Depth 3)
    }
    [IO.File]::WriteAllText($f, ('[' + ($items -join ',') + ']'), (New-Object Text.UTF8Encoding($false)))
}
function Get-DirSizeBytes([string]$path) {
    $sum = 0
    try { $sum = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum } catch {}
    if (-not $sum) { return [double]0 }
    return [double]$sum
}
function Test-HomeDeletable([string]$homePath) {
    if (-not $homePath -or -not (Test-Path -LiteralPath $homePath)) { return @{ ok = $false; message = '目录不存在' } }
    $full = [IO.Path]::GetFullPath($homePath).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') { return @{ ok = $false; message = '不能删除盘符根目录' } }
    $c = Get-Config
    $guard = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
               $env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $c.Home, $c.Root)
    foreach ($g in $guard) {
        if (-not $g) { continue }
        $gg = [IO.Path]::GetFullPath($g).TrimEnd('\')
        if ($full -eq $gg) { return @{ ok = $false; message = ('这是受保护的目录，不能删：' + $gg) } }
        if ($gg.StartsWith($full + '\', 'OrdinalIgnoreCase')) {
            return @{ ok = $false; message = ('这个目录里包含受保护路径 ' + $gg + '，拒绝删除') }
        }
    }
    foreach ($i in $script:Data.instances) {
        if (-not $i.home) { continue }
        $h = [IO.Path]::GetFullPath($i.home).TrimEnd('\')
        if ($h -ne $full -and $h.StartsWith($full + '\', 'OrdinalIgnoreCase')) {
            return @{ ok = $false; message = ('这个目录里还有别的环境：' + $i.name) }
        }
    }
    return @{ ok = $true; path = $full }
}
function Test-HomeInUse([string]$homePath) {
    # 只有"当前真正在跑的那套"才拦；别的环境在跑不影响删这个
    $c = Get-Config
    if (-not (Test-Path -LiteralPath $c.MarkerFile)) { return $false }
    try {
        $m = Get-Content $c.MarkerFile -Raw | ConvertFrom-Json
        if (-not $m.home -or -not $m.pid) { return $false }
        if (-not (Get-Process -Id ([int]$m.pid) -ErrorAction SilentlyContinue)) { return $false }
        return ([IO.Path]::GetFullPath([string]$m.home).TrimEnd('\') -ieq [IO.Path]::GetFullPath($homePath).TrimEnd('\'))
    } catch { return $false }
}
function Move-HomeToTrash([string]$homePath, [string]$name) {    $chk = Test-HomeDeletable $homePath
    if (-not $chk.ok) { return $chk }
    $full = $chk.path
    $trash = Get-TrashDir
    $safe = ($name -replace '[\\/:*?"<>|]', '_')
    if (-not $safe) { $safe = 'instance' }
    $dest = Join-Path $trash ($safe + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $dest) { $dest = Join-Path $trash ($safe + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
    $size = Get-DirSizeBytes $full
    try { Move-Item -LiteralPath $full -Destination $dest -Force -ErrorAction Stop }
    catch { return @{ ok = $false; message = ('移动到回收站失败：' + $_.Exception.Message) } }
    $m = @(Read-TrashManifest)
    $m += [pscustomobject]@{ name = $name; original = $full; trash = $dest; at = (Get-Date).ToString('o'); sizeBytes = $size }
    Save-TrashManifest $m
    return @{ ok = $true; message = '已移入回收站（可在管理器里恢复）'; trash = $dest; sizeBytes = $size }
}
function Get-TrashEntries {
    $res = @()
    foreach ($e in (Read-TrashManifest)) {
        if (-not $e -or -not $e.trash) { continue }
        $exists = Test-Path -LiteralPath $e.trash
        $res += [pscustomobject]@{
            name = [string]$e.name; original = [string]$e.original; trash = [string]$e.trash
            at = [string]$e.at; sizeBytes = [double]$e.sizeBytes; exists = $exists
        }
    }
    return $res
}
function Restore-TrashEntry([string]$trashPath) {
    if (-not $trashPath) { return @{ ok = $false; message = '没指定要恢复的项' } }
    $m = @(Read-TrashManifest)
    $e = @($m | Where-Object { $_ -and $_.trash -eq $trashPath }) | Select-Object -First 1
    if (-not $e) { return @{ ok = $false; message = '回收站里没有这一项' } }
    if (-not (Test-Path -LiteralPath $e.trash)) { return @{ ok = $false; message = '回收站里的文件已经不在了' } }
    if (Test-Path -LiteralPath $e.original) { return @{ ok = $false; message = ('原位置已经有同名目录：' + $e.original) } }
    $parent = Split-Path $e.original -Parent
    try { if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null } } catch {}
    try { Move-Item -LiteralPath $e.trash -Destination $e.original -Force -ErrorAction Stop }
    catch { return @{ ok = $false; message = ('恢复失败：' + $_.Exception.Message) } }
    Save-TrashManifest (@($m | Where-Object { $_ -and $_.trash -ne $trashPath }))
    return @{ ok = $true; message = '已恢复到原位置' }
}
function Clear-Trash {
    $trashRoot = [IO.Path]::GetFullPath((Get-TrashDir)).TrimEnd('\')
    $m = @(Read-TrashManifest)
    $n = 0; $fail = 0
    foreach ($e in $m) {
        if (-not $e -or -not $e.trash) { continue }
        $p = [IO.Path]::GetFullPath($e.trash)
        # 只允许删回收站目录里的东西
        if (-not $p.StartsWith($trashRoot + '\', 'OrdinalIgnoreCase')) { $fail++; continue }
        if (Test-Path -LiteralPath $p) {
            try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; $n++ } catch { $fail++ }
        }
    }
    Save-TrashManifest @()
    return @{ ok = $true; message = ('回收站已清空（删除 ' + $n + ' 项，失败 ' + $fail + ' 项）') }
}
