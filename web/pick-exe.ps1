param([string]$Initial = '', [string]$OutFile = '')
# Opens a native file picker for the DSH executable and writes UTF-8 (no BOM).
# Empty result means the user cancelled. ASCII-only source on purpose.
if (-not $OutFile) { exit 2 }
try { [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') } catch {}
$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = 'Choose DeepSeek Harness.exe'
$dlg.Filter = 'DSH executable (*.exe)|*.exe|All files (*.*)|*.*'
$dlg.CheckFileExists = $true
$dlg.Multiselect = $false
if ($Initial) {
    try {
        if (Test-Path -LiteralPath $Initial -PathType Leaf) { $dlg.InitialDirectory = Split-Path $Initial -Parent; $dlg.FileName = Split-Path $Initial -Leaf }
        elseif (Test-Path -LiteralPath $Initial -PathType Container) { $dlg.InitialDirectory = $Initial }
    } catch {}
}
$result = ''
if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $result = [string]$dlg.FileName }
[IO.File]::WriteAllText($OutFile, $result, (New-Object Text.UTF8Encoding($false)))
