param(
    [switch]$BuildApp,
    [switch]$SkipSmoke,
    [string]$WebView2Dir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$failed = $false

function Pass([string]$message) { Write-Host ("  OK    " + $message) -ForegroundColor Green }
function Fail([string]$message) { Write-Host ("  FAIL  " + $message) -ForegroundColor Red; $script:failed = $true }
function Head([string]$message) { Write-Host ''; Write-Host ("== " + $message + " ==") -ForegroundColor Cyan }

Head '必需文件'
$required = @(
    'README.md', 'LICENSE', 'VERSION', 'Start.cmd', 'Start-Visible.cmd',
    'instances.example.json', 'lib\core.ps1', 'web\ui.html', 'web\server.ps1',
    'web\start.ps1', 'web\watchdog.ps1', 'web\pick-folder.ps1', 'web\pick-exe.ps1',
    'web\assets\site.webmanifest', 'web\assets\dsh-manager.ico',
    'web\assets\dsh-manager-192.png', 'web\assets\dsh-manager-512.png',
    'src\native\Program.cs', 'src\native\app.manifest', 'src\native\App.config',
    'src\native\app.ico', 'scripts\build-app.ps1', 'scripts\smoke-test.ps1',
    'docs\ARCHITECTURE.md', 'docs\USAGE.md', 'docs\PRIVACY.md', 'docs\screenshot.png',
    'CONTRIBUTING.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md'
)
foreach ($relative in $required) {
    $full = Join-Path $root $relative
    if (Test-Path -LiteralPath $full) { Pass $relative } else { Fail ("缺少 " + $relative) }
}

Head 'PowerShell 语法'
$scripts = Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\(\.build|\.local-archive[^\\]*|app)\\' }
foreach ($script in $scripts) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors)
    if (@($errors).Count -eq 0) { Pass $script.FullName.Substring($root.Length + 1) }
    else { Fail ($script.FullName.Substring($root.Length + 1) + ' 有 ' + @($errors).Count + ' 个语法错误') }
}

Head '版本一致性'
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$program = Get-Content -LiteralPath (Join-Path $root 'src\native\Program.cs') -Raw
if ($version -match '^\d+\.\d+\.\d+$') { Pass ("VERSION = " + $version) } else { Fail 'VERSION 不是 x.y.z' }
if ($program -match '\[assembly: AssemblyVersion\("' + [regex]::Escape($version) + '\.0"\)\]') { Pass 'Program.cs AssemblyVersion 与 VERSION 一致' }
else { Fail 'Program.cs AssemblyVersion 与 VERSION 不一致' }

Head '路径与隐私'
$textFiles = Get-ChildItem -LiteralPath $root -File -Recurse -Include *.ps1,*.md,*.txt,*.json,*.html,*.cmd,*.cs,*.yml,*.yaml |
    Where-Object { $_.FullName -notmatch '\\(\.build|\.local-archive[^\\]*|app|preview)\\' }
$pathLeaks = @()
foreach ($file in $textFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match 'C:\\Users\\[^\\\r\n]+' -or $text -match 'D:\\dsh-switch' -or $text -match 'D:\\deepseek') {
        $pathLeaks += $file.FullName.Substring($root.Length + 1)
    }
}
if ($pathLeaks.Count -eq 0) { Pass '没有个人绝对路径' } else { Fail ('包含个人绝对路径: ' + ($pathLeaks -join ', ')) }

$secretHits = @()
foreach ($file in $textFiles) {
    # verify.ps1 自己包含密钥特征的正则文本，不应把它算成泄漏。
    if ($file.FullName -eq (Join-Path $root 'verify.ps1')) { continue }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if ($text -match '(?i)(api[_-]?key|client_secret|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,})') {
        $secretHits += $file.FullName.Substring($root.Length + 1)
    }
}
if ($secretHits.Count -eq 0) { Pass '没有常见密钥特征' } else { Fail ('疑似密钥: ' + ($secretHits -join ', ')) }

Head '静态资源'
$manifestPath = Join-Path $root 'web\assets\site.webmanifest'
try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($icon in @($manifest.icons)) {
        $asset = Join-Path (Join-Path $root 'web') $icon.src.TrimStart('/').Replace('/', '\')
        if (Test-Path -LiteralPath $asset) { Pass ('manifest: ' + $icon.src) } else { Fail ('manifest 引用缺失: ' + $icon.src) }
    }
} catch { Fail ('manifest 无法解析: ' + $_.Exception.Message) }

Head '本地服务边界'
$server = Get-Content -LiteralPath (Join-Path $root 'web\server.ps1') -Raw
if ($server -match 'http://127\.0\.0\.1:') { Pass '服务只使用 127.0.0.1' } else { Fail '没有找到 127.0.0.1 监听地址' }
if ($server -match '0\.0\.0\.0') { Fail '服务中出现 0.0.0.0' } else { Pass '没有公网监听地址' }
if ($server -match 'Sec-Fetch-Site') { Pass '存在跨站请求检查' } else { Fail '缺少跨站请求检查' }

if (-not $SkipSmoke) {
    Head '本地服务冒烟测试'
    $smoke = Join-Path $root 'scripts\smoke-test.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $smoke
    if ($LASTEXITCODE -ne 0) { Fail '冒烟测试失败' } else { Pass '冒烟测试通过' }
}

if ($BuildApp) {
    Head '原生桌面程序构建'
    $build = Join-Path $root 'scripts\build-app.ps1'
    $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $build)
    if ($WebView2Dir) { $buildArgs += @('-WebView2Dir', $WebView2Dir) }
    & powershell.exe @buildArgs
    if ($LASTEXITCODE -ne 0) { Fail '原生桌面程序构建失败' } else { Pass '原生桌面程序构建通过' }
}

Write-Host ''
if ($failed) {
    Write-Host '结果：未通过' -ForegroundColor Red
    exit 1
}
Write-Host '结果：通过' -ForegroundColor Green
exit 0
