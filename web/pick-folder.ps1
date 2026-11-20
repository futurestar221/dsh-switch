param([string]$Initial = '', [string]$OutFile = '')
# Opens a native folder picker and writes the chosen path (UTF-8 no BOM) to $OutFile.
# Empty result means the user cancelled. ASCII-only source on purpose.
if (-not $OutFile) { exit 2 }
try { [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') } catch {}
$dlg = New-Object System.Windows.Forms.FolderBrowserDialog
$dlg.Description = 'Choose a folder for the new DSH instance home'
$dlg.ShowNewFolderButton = $true
if ($Initial -and (Test-Path -LiteralPath $Initial)) { $dlg.SelectedPath = $Initial }
elseif ($Initial) {
    $p = $Initial
    while ($p -and -not (Test-Path -LiteralPath $p)) { $p = Split-Path -Parent $p }
    if ($p) { $dlg.SelectedPath = $p }
}
$result = ''
if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $result = [string]$dlg.SelectedPath }
[IO.File]::WriteAllText($OutFile, $result, (New-Object Text.UTF8Encoding($false)))
