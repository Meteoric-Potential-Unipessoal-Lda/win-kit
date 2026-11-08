# Собирает архив набора для клиента (без tests/.github/tools) и version.json для автообновления.
# Адрес архива в version.json: https://github.com/<UPDATE_REPO или этот репозиторий>/releases/download/v<версия>/win-kit-<версия>.zip
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\normalize.ps1') | Out-Null
$ver = ([regex]::Match([IO.File]::ReadAllText((Join-Path $root 'winkit.ps1')), "\`$script:Version = '([^']+)'")).Groups[1].Value
if (-not $ver) { throw 'не нашёл версию в winkit.ps1' }
$dist = Join-Path $root 'dist'; $stage = Join-Path $dist 'win-kit'
Remove-Item -LiteralPath $dist -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($f in @('winkit.ps1', 'start.bat', 'start-console.bat', 'README.txt', 'master.txt')) { Copy-Item -LiteralPath (Join-Path $root $f) -Destination $stage }
Copy-Item -LiteralPath (Join-Path $root 'data') -Destination $stage -Recurse
$zip = Join-Path $dist ("win-kit-$ver.zip")
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
$sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
$repo = $env:UPDATE_REPO; if (-not $repo) { $repo = $env:GITHUB_REPOSITORY }
$url = "https://github.com/$repo/releases/download/v$ver/win-kit-$ver.zip"
$notes = "win-kit $ver"
$rm = Join-Path $root 'README.txt'
$m = [regex]::Match([IO.File]::ReadAllText($rm), '(?ms)^Что нового в ' + [regex]::Escape($ver) + '.*?(?=^\S.*\r?\n=|\z)')
if ($m.Success) { $notes = $m.Value.Trim() }
[IO.File]::WriteAllText((Join-Path $dist 'version.json'), (ConvertTo-Json -InputObject ([ordered]@{ version = $ver; url = $url; sha256 = $sha; notes = ("win-kit $ver") }) -Depth 3), (New-Object System.Text.UTF8Encoding $false))
[IO.File]::WriteAllText((Join-Path $dist 'notes.txt'), $notes, (New-Object System.Text.UTF8Encoding $false))
[IO.File]::WriteAllText((Join-Path $dist 'VERSION'), $ver, (New-Object System.Text.UTF8Encoding $false))
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "win-kit $ver -> $zip ($sha)"
