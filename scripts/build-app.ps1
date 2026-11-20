param(
    [string]$WebView2Dir = '',
    [string]$OutputDir = '',
    [ValidateSet('x64', 'x86')]
    [string]$Architecture = 'x64',
    [switch]$ForceRestore
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'src\native'
$output = if ($OutputDir) { [IO.Path]::GetFullPath($OutputDir) } else { Join-Path $root 'app' }
$webView2Version = '1.0.2903.40'

function Get-CompilerPath {
    $framework = if ($Architecture -eq 'x64') { 'Framework64' } else { 'Framework' }
    $path = Join-Path $env:WINDIR "Microsoft.NET\$framework\v4.0.30319\csc.exe"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "找不到 .NET Framework 编译器：$path。请确认系统已安装 .NET Framework 4.8。"
    }
    return $path
}

function Find-WebView2Set([string]$directory) {
    if (-not $directory -or -not (Test-Path -LiteralPath $directory)) { return $null }
    $core = Get-ChildItem -LiteralPath $directory -Recurse -Filter 'Microsoft.Web.WebView2.Core.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $winforms = Get-ChildItem -LiteralPath $directory -Recurse -Filter 'Microsoft.Web.WebView2.WinForms.dll' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $loaders = @(Get-ChildItem -LiteralPath $directory -Recurse -Filter 'WebView2Loader.dll' -File -ErrorAction SilentlyContinue)
    $loader = $loaders | Where-Object { $_.FullName -match [regex]::Escape("win-$Architecture") } | Select-Object -First 1
    if (-not $loader) { $loader = $loaders | Select-Object -First 1 }
    if ($core -and $winforms -and $loader) {
        return [pscustomobject]@{ Core = $core.FullName; WinForms = $winforms.FullName; Loader = $loader.FullName }
    }
    return $null
}

function Restore-WebView2 {
    $cacheRoot = Join-Path $root '.build\webview2'
    $versionDir = Join-Path $cacheRoot $webView2Version
    $found = Find-WebView2Set $versionDir
    if ($found) { return $found }

    New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
    $nupkg = Join-Path $cacheRoot "Microsoft.Web.WebView2.$webView2Version.nupkg"
    $zip = Join-Path $cacheRoot "Microsoft.Web.WebView2.$webView2Version.zip"
    if ($ForceRestore -or -not (Test-Path -LiteralPath $nupkg)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$webView2Version/microsoft.web.webview2.$webView2Version.nupkg"
        Write-Host "下载 WebView2 SDK $webView2Version ..."
        Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
    }
    Copy-Item -LiteralPath $nupkg -Destination $zip -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $versionDir) { Get-ChildItem -LiteralPath $versionDir -Force | Remove-Item -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $versionDir)
    Remove-Item -LiteralPath $zip -Force

    $found = Find-WebView2Set $versionDir
    if (-not $found) { throw 'WebView2 NuGet 包中缺少编译所需程序集。' }
    return $found
}

if ($WebView2Dir) {
    $webview = Find-WebView2Set $WebView2Dir
    if (-not $webview) { throw "在 $WebView2Dir 中没有找到 WebView2 Core/WinForms/Loader 程序集。" }
} else {
    $webview = Find-WebView2Set (Join-Path $root '.build\webview2')
    if (-not $webview) { $webview = Find-WebView2Set (Join-Path $root 'app') }
    if (-not $webview) { $webview = Restore-WebView2 }
}

$csc = Get-CompilerPath
New-Item -ItemType Directory -Force -Path $output | Out-Null
$exe = Join-Path $output 'dsh-switch.exe'
$refs = @(
    '/r:System.dll',
    '/r:System.Core.dll',
    '/r:System.Drawing.dll',
    '/r:System.Windows.Forms.dll',
    ('/r:' + $webview.Core),
    ('/r:' + $webview.WinForms)
)
$args = @(
    '/nologo',
    '/target:winexe',
    ('/platform:' + $Architecture.ToLowerInvariant()),
    '/langversion:5',
    '/optimize+',
    ('/out:' + $exe),
    ('/win32manifest:' + (Join-Path $source 'app.manifest')),
    ('/win32icon:' + (Join-Path $source 'app.ico'))
) + $refs + @((Join-Path $source 'Program.cs'))

Write-Host "编译 dsh-switch ($Architecture) ..."
& $csc $args
if ($LASTEXITCODE -ne 0) { throw "编译失败，csc 退出码 $LASTEXITCODE" }

Copy-Item -LiteralPath (Join-Path $source 'App.config') -Destination ($exe + '.config') -Force
Copy-Item -LiteralPath $webview.Core -Destination (Join-Path $output 'Microsoft.Web.WebView2.Core.dll') -Force
Copy-Item -LiteralPath $webview.WinForms -Destination (Join-Path $output 'Microsoft.Web.WebView2.WinForms.dll') -Force
Copy-Item -LiteralPath $webview.Loader -Destination (Join-Path $output 'WebView2Loader.dll') -Force

$file = Get-Item -LiteralPath $exe
Write-Host ("完成：{0} ({1:N0} bytes)" -f $file.FullName, $file.Length)