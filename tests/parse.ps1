$root = Split-Path -Parent $PSScriptRoot
$bad = 0
Write-Host ('PowerShell ' + $PSVersionTable.PSVersion)
foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
  $tok = $null; $err = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
  foreach ($e in $err) { $bad++; Write-Host ('{0}:{1}: {2}' -f $f.Name, $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
  $b = [IO.File]::ReadAllBytes($f.FullName)
  if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $bad++; Write-Host ($f.Name + ': нет BOM') -ForegroundColor Red }
}
Write-Host "parse errors: $bad"
if ($bad) { exit 1 }
