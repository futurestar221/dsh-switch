param(
    [string]$WebView2Dir = '',
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$dist = if ($OutputDir) { [IO.Path]::GetFullPath($OutputDir) } else { Join-Path $root 'dist' }
$stage = Join-Path $root ('.build\release\dsh-switch-' + $version + '-win-x64')
$zip = Join-Path $dist ('dsh-switch-' + $version + '-win-x64.zip')

$buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'scripts\build-app.ps1'))
if ($WebView2Dir) { $buildArgs += @('-WebView2Dir', $WebView2Dir) }
& powershell.exe @buildArgs
if ($LASTEXITCODE -ne 0) { throw '构建失败' }

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage, $dist | Out-Null

Copy-Item -LiteralPath (Join-Path $root 'Start.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'Start-Visible.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'CHANGELOG.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'THIRD_PARTY_NOTICES.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'CONTRIBUTING.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'SECURITY.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'VERSION') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'instances.example.json') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'app') -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $root 'lib') -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $root 'docs') -Destination $stage -Recurse

$webStage = Join-Path $stage 'web'
New-Item -ItemType Directory -Force -Path $webStage | Out-Null
foreach ($name in @('ui.html', 'server.ps1', 'start.ps1', 'watchdog.ps1', 'pick-folder.ps1', 'pick-exe.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root ('web\' + $name)) -Destination $webStage
}
Copy-Item -LiteralPath (Join-Path $root 'web\assets') -Destination $webStage -Recurse

if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$utf8 = New-Object Text.UTF8Encoding($false)
$zipStream = [IO.File]::Open($zip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite)
try {
    $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false, $utf8)
    try {
        Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $_.FullName,
                $relative,
                [IO.Compression.CompressionLevel]::Optimal
            )
        }
    }
    finally {
        $archive.Dispose()
    }
}
finally {
    $zipStream.Dispose()
}
Write-Host ('发布包：' + $zip)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = $zip + '.sha256'
Set-Content -LiteralPath $checksum -Value ($hash + '  ' + [IO.Path]::GetFileName($zip)) -Encoding Ascii
Write-Host ('SHA256：' + $hash)
Write-Host ('校验文件：' + $checksum)

