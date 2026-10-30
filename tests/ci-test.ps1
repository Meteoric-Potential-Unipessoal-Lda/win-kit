# Проверка win-kit на настоящей Windows (GitHub Actions): диагностика -> оптимизация -> проверка -> откат -> проверка
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$kit = Join-Path $root 'winkit.ps1'
$out = Join-Path $root 'ci-reports'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$fail = New-Object System.Collections.ArrayList
function Check($cond, [string]$msg) {
  if ($cond) { Write-Host "OK   $msg" -ForegroundColor Green } else { Write-Host "FAIL $msg" -ForegroundColor Red; [void]$fail.Add($msg) }
}
function Run-Kit([string[]]$a) {
  Write-Host ('>>> winkit.ps1 ' + ($a -join ' ')) -ForegroundColor Cyan
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $kit @a -ReportDir $out -CurrentUser | Out-Host
  return $LASTEXITCODE
}
function Get-SA([string]$key, [string]$name) {
  try { $k = Get-Item -LiteralPath $key -ErrorAction Stop; if (@($k.GetValueNames()) -contains $name) { return ,([byte[]]$k.GetValue($name)) } } catch {}
  return $null
}
function Get-ActivePlan { return ([regex]::Match(((powercfg.exe /getactivescheme) -join ' '), '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}')).Value.ToLower() }
function Get-SvcMode([string]$n) { return (Get-CimInstance Win32_Service -Filter "Name='$n'").StartMode }

$saU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$saM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$saF = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$startupDir = [Environment]::GetFolderPath('Startup')
$saver = 'a1841308-3541-4fab-bc81-f71556f20b4a'; $bal = '381b4222-f694-41f0-9685-ff5bb260df2e'

# ---------- 0. только диагностика
$rc = Run-Kit @('-Mode', 'diag')
Check ($rc -eq 0) "diag: код выхода $rc"
Check (@(Get-ChildItem -LiteralPath $out -Filter '*_diag_*.zip').Count -ge 1) 'diag: архив отчёта создан'

# ---------- 1. подготовка «мусора»
foreach ($rk in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) { if (-not (Test-Path $rk)) { New-Item -Path $rk -Force | Out-Null } }
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'WinKitTestJunk' -Value '"C:\Windows\System32\cmd.exe" /c rem winkit-test' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'WinKitTestJunk2' -Value '"C:\Windows\System32\cmd.exe" /c rem winkit-test' -Force | Out-Null
New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
Set-Content -LiteralPath (Join-Path $startupDir 'winkit-test.cmd') -Value '@echo off' -Encoding ASCII
$act = New-ScheduledTaskAction -Execute 'C:\Windows\System32\cmd.exe' -Argument '/c rem winkit-test'
Register-ScheduledTask -TaskName 'WinKitTestTask' -TaskPath '\WinKitTest\' -Action $act -Trigger (New-ScheduledTaskTrigger -AtLogOn) -Force | Out-Null
& sc.exe create WinKitTestSvc binPath= 'C:\winkit-test\fake.exe' start= auto | Out-Host
& sc.exe create WinKitTestSvc2 binPath= 'C:\winkit-test\fake2.exe' start= delayed-auto | Out-Host
$tmp = Join-Path $env:LOCALAPPDATA 'Temp'
$oldF = Join-Path $tmp 'winkit-old.tmp'; [IO.File]::WriteAllBytes($oldF, (New-Object byte[] 2097152));  # 2 МБ: пункт очистки появляется от 1 МБ
 (Get-Item -LiteralPath $oldF).LastWriteTime = (Get-Date).AddDays(-3)
$newF = Join-Path $tmp 'winkit-new.tmp'; Set-Content -LiteralPath $newF -Value 'x'
New-Item -ItemType Directory -Force -Path 'C:\winkit-precious' | Out-Null
$prec = 'C:\winkit-precious\keep.txt'; Set-Content -LiteralPath $prec -Value 'precious'; (Get-Item -LiteralPath $prec).LastWriteTime = (Get-Date).AddDays(-3)
& cmd.exe /c mklink /J "$tmp\winkit-junction" "C:\winkit-precious" | Out-Host
$origPlan = Get-ActivePlan
$plans = ((powercfg.exe /list) -join "`n").ToLower()
$powerTest = ($plans.Contains($saver) -and $plans.Contains($bal))
if ($powerTest) { & powercfg.exe /setactive $saver; Check ((Get-ActivePlan) -eq $saver) 'подготовка: включена «Экономия энергии»' } else { Write-Host 'нет схемы Экономия — проверку питания пропускаю' }

Check ($null -eq (Get-SA $saU 'WinKitTestJunk')) 'до: StartupApproved HKCU пуст'
Check ((Get-SvcMode 'WinKitTestSvc') -eq 'Auto') 'до: служба 1 Auto'
Check ((Get-SvcMode 'WinKitTestSvc2') -eq 'Auto') 'до: служба 2 Auto (delayed)'
Check ((Get-ScheduledTask -TaskPath '\WinKitTest\' -TaskName 'WinKitTestTask').State -ne 'Disabled') 'до: задача включена'

# настройки Windows (v0.3): запомнить как было
function Get-RV([string]$k, [string]$n) { try { $i = Get-Item -LiteralPath $k -ErrorAction Stop; if (@($i.GetValueNames()) -contains $n) { return [string]$i.GetValue($n) } } catch {}; return '<нет>' }
$advK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; $cdmK = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$advKeyBefore = Test-Path $advK; $cdmKeyBefore = Test-Path $cdmK
$advBefore = Get-RV $advK 'Enabled'; $cdmBefore = Get-RV $cdmK 'SilentInstalledAppsEnabled'
$defK = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'; $defKeyBefore = Test-Path $defK
New-Item -Path $defK -Force | Out-Null; New-ItemProperty -Path $defK -Name 'DisableAntiSpyware' -Value 1 -PropertyType DWord -Force | Out-Null
Write-Host ("до: AdvertisingInfo.Enabled={0}, SilentInstalledAppsEnabled={1}, ключ AdvertisingInfo есть={2}" -f $advBefore, $cdmBefore, $advKeyBefore)

# ---------- 2. оптимизация (план по умолчанию)
$rc = Run-Kit @('-Mode', 'optimize', '-Yes', '-NoReboot', '-AllowManaged')
Check ($rc -eq 0) "optimize: код выхода $rc"
$b = Get-SA $saU 'WinKitTestJunk';   Check ($b -and $b[0] -eq 3) 'после: автозагрузка HKCU выключена'
$b = Get-SA $saM 'WinKitTestJunk2';  Check ($b -and $b[0] -eq 3) 'после: автозагрузка HKLM выключена'
$b = Get-SA $saF 'winkit-test.cmd';  Check ($b -and $b[0] -eq 3) 'после: папка Автозагрузка — выключено'
Check ((Get-ScheduledTask -TaskPath '\WinKitTest\' -TaskName 'WinKitTestTask').State -eq 'Disabled') 'после: задача выключена'
Check ((Get-SvcMode 'WinKitTestSvc') -eq 'Manual') 'после: служба 1 Manual'
Check ((Get-SvcMode 'WinKitTestSvc2') -eq 'Manual') 'после: служба 2 Manual'
if ($powerTest) { Check ((Get-ActivePlan) -eq $bal) 'после: схема питания Сбалансированная' }
Check (-not (Test-Path -LiteralPath $oldF)) 'после: старый временный файл удалён'
Check (Test-Path -LiteralPath $newF) 'после: свежий временный файл НЕ тронут'
Check (Test-Path -LiteralPath $prec) 'после: файл за junction НЕ тронут (обход ссылок не выходит за папку)'
Check (Test-Path -LiteralPath "$tmp\winkit-junction") 'после: сама junction на месте'
$j = @(Get-ChildItem -LiteralPath "$env:ProgramData\CleanMyPC\backups" -Filter *.json -ErrorAction SilentlyContinue)
Check ($j.Count -ge 1) 'после: журнал отката создан'
Check ((Get-RV $advK 'Enabled') -eq '0') 'после: рекламный идентификатор выключен'
Check ((Get-RV $cdmK 'SilentInstalledAppsEnabled') -eq '0') 'после: тихая установка приложений выключена'
Check ((Get-RV $defK 'DisableAntiSpyware') -eq '<нет>') 'после: запрет Защитника снят'

# ---------- 3. откат
$rc = Run-Kit @('-Mode', 'rollback', '-Yes')
Check ($rc -eq 0) "rollback: код выхода $rc"
Check ($null -eq (Get-SA $saU 'WinKitTestJunk')) 'откат: StartupApproved HKCU снова пуст'
Check ($null -eq (Get-SA $saM 'WinKitTestJunk2')) 'откат: StartupApproved HKLM снова пуст'
Check ($null -eq (Get-SA $saF 'winkit-test.cmd')) 'откат: StartupFolder снова пуст'
Check ((Get-ScheduledTask -TaskPath '\WinKitTest\' -TaskName 'WinKitTestTask').State -ne 'Disabled') 'откат: задача включена'
Check ((Get-SvcMode 'WinKitTestSvc') -eq 'Auto') 'откат: служба 1 Auto'
Check ((Get-SvcMode 'WinKitTestSvc2') -eq 'Auto') 'откат: служба 2 Auto'
Check ((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\WinKitTestSvc2' -ErrorAction SilentlyContinue).DelayedAutostart -eq 1) 'откат: служба 2 снова отложенная'
if ($powerTest) { Check ((Get-ActivePlan) -eq $saver) 'откат: схема питания вернулась' }
Check ((Get-RV $advK 'Enabled') -eq $advBefore) 'откат: рекламный идентификатор как был'
Check ((Get-RV $cdmK 'SilentInstalledAppsEnabled') -eq $cdmBefore) 'откат: тихая установка как была'
Check ((Test-Path $advK) -eq $advKeyBefore) 'откат: ключ AdvertisingInfo как был (созданный набором удалён)'
Check ((Get-RV $defK 'DisableAntiSpyware') -eq '1') 'откат: запрет Защитника вернулся'

$rc = Run-Kit @('-Mode', 'rollback', '-Yes')
Check ($rc -eq 0) "повторный откат ничего не ломает: код $rc"

# ---------- 3б. браузер: подставной профиль Chrome с расширением «вручную» и чужим поиском
$cp = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Profile 99'
New-Item -ItemType Directory -Force -Path (Join-Path $cp 'Extensions\aaaabbbbccccddddeeeeffffgggghhhh\1.0') | Out-Null
Set-Content -LiteralPath (Join-Path $cp 'Extensions\aaaabbbbccccddddeeeeffffgggghhhh\1.0\manifest.json') -Value '{"name":"WinKit Test Coupons","version":"1.0"}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $cp 'Secure Preferences') -Value '{"extensions":{"settings":{"aaaabbbbccccddddeeeeffffgggghhhh":{"location":4,"path":"C:\\winkit-ext"}}}}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $cp 'Preferences') -Value '{"default_search_provider_data":{"template_url_data":{"url":"https://evil-search.example/?q={searchTerms}"}},"a":1,"A":2}' -Encoding UTF8

# старый большой файл в «Загрузках» — должен попасть в отчёт (и не удаляться)
$dl = Join-Path $env:USERPROFILE 'Downloads'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
$dlf = Join-Path $dl 'winkit-old-setup.zip'
$fs = [IO.File]::Create($dlf); $fs.SetLength(60MB); $fs.Close(); (Get-Item -LiteralPath $dlf).LastWriteTime = (Get-Date).AddDays(-200)

# ---------- 4. диагностика после — «было/стало»
$rc = Run-Kit @('-Mode', 'diag')
Check ($rc -eq 0) "diag после: код выхода $rc"
$lastDiag = @(Get-ChildItem -LiteralPath $out -Directory -Filter '*_diag_*' | Sort-Object Name)[-1]
$rep = Get-Content -LiteralPath (Join-Path $lastDiag.FullName 'report.txt') -Raw -Encoding UTF8
Check ($rep -match 'WinKit Test Coupons') 'браузер: расширение найдено'
Check ($rep -match 'установлено вручную') 'браузер: расширение «вручную» отмечено ВНИМАНИЕ'
Check ($rep -match 'evil-search\.example') 'браузер: чужой поиск найден'
$err = Join-Path $lastDiag.FullName 'errors.txt'
Check (-not (Test-Path -LiteralPath $err) -or -not ((Get-Content -LiteralPath $err -Raw) -match 'браузеры')) 'браузер: без внутренних ошибок'
Remove-Item -LiteralPath $cp -Recurse -Force -ErrorAction SilentlyContinue
Check ($rep -match 'winkit-old-setup\.zip') 'загрузки: старый большой файл в отчёте'
Check (Test-Path -LiteralPath $dlf) 'загрузки: файл пользователя не удалён'
Check (-not (Test-Path -LiteralPath $err) -or -not ((Get-Content -LiteralPath $err -Raw) -match 'загрузки')) 'загрузки: без внутренних ошибок'
Remove-Item -LiteralPath $dlf -Force -ErrorAction SilentlyContinue

# ---------- уборка
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'WinKitTestJunk' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'WinKitTestJunk2' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $startupDir 'winkit-test.cmd') -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskPath '\WinKitTest\' -TaskName 'WinKitTestTask' -Confirm:$false -ErrorAction SilentlyContinue
& sc.exe delete WinKitTestSvc | Out-Null; & sc.exe delete WinKitTestSvc2 | Out-Null
if ($origPlan) { & powercfg.exe /setactive $origPlan }
Remove-ItemProperty -Path $defK -Name 'DisableAntiSpyware' -ErrorAction SilentlyContinue
if (-not $defKeyBefore) { Remove-Item -Path $defK -Recurse -Force -ErrorAction SilentlyContinue }

foreach ($e in @(Get-ChildItem -LiteralPath $out -Recurse -Filter errors.txt)) { Write-Host ('---- ' + $e.FullName); Get-Content -LiteralPath $e.FullName -Encoding UTF8 | Out-Host }
Write-Host ''
if ($fail.Count) { Write-Host ("ПРОВАЛЕНО проверок: {0}" -f $fail.Count) -ForegroundColor Red; $fail | Out-Host; exit 1 }
Write-Host 'ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ' -ForegroundColor Green
exit 0
