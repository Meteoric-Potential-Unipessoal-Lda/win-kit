# Приводит файлы к UTF-8 с BOM и CRLF (Windows PowerShell 5.1 читает .ps1 без BOM как ANSI)
$root = Split-Path -Parent $PSScriptRoot
$enc = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -LiteralPath $root -Recurse -File -Include *.ps1, *.tsv, *.txt | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
  $t = [IO.File]::ReadAllText($_.FullName)
  $t = $t -replace "`r?`n", "`r`n"
  [IO.File]::WriteAllText($_.FullName, $t, $enc)
  Write-Host ('normalized ' + $_.Name)
}
