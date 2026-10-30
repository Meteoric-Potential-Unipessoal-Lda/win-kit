<#
  win-kit — набор мастера: диагностика и бережная чистка Windows 10/11
  Версия 0.3 (2026-10-30)

  Обычный запуск: start.bat (сам попросит права администратора) -> меню.
  Без меню (для проверки):
    powershell -ExecutionPolicy Bypass -File winkit.ps1 -Mode diag
    powershell -ExecutionPolicy Bypass -File winkit.ps1 -Mode optimize -Yes -NoReboot
    powershell -ExecutionPolicy Bypass -File winkit.ps1 -Mode rollback -Yes
  -Yes: принять план по умолчанию (только «авто») / откатить последний сеанс целиком.

  Правила: только обратимое (необратимо только очистка мусора — отдельно и с пометкой);
  точка восстановления и журнал до первого изменения; журнал хранится на самом ПК
  (C:\ProgramData\CleanMyPC\backups), копия — в отчёте.
#>
param(
  [ValidateSet('menu','diag','optimize','rollback')][string]$Mode = 'menu',
  [switch]$Yes,
  [switch]$NoReboot,
  [switch]$AllowManaged,
  [switch]$CurrentUser,
  [string]$ReportDir = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:Version = '0.3'
$script:Root = $PSScriptRoot
if (-not $script:Root) { $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:Utf8Bom = New-Object System.Text.UTF8Encoding $true
$script:StateDir = Join-Path $env:ProgramData 'CleanMyPC'
$script:BackupDir = Join-Path $script:StateDir 'backups'
$script:MetricsPath = Join-Path $script:StateDir 'metrics.json'
$script:Errors = New-Object System.Collections.ArrayList
$script:Log = New-Object System.Collections.ArrayList
$script:Interactive = -not $Yes
$script:SigCache = @{}
$script:Journal = $null
$script:JournalPath = $null
$script:SessionDir = $null

# ---------------------------------------------------------------- вывод

function Say([string]$t = '', [string]$c = 'Gray') {
  Write-Host $t -ForegroundColor $c
  [void]$script:Log.Add($t)
}
function Head([string]$t) { Say ''; Say ('==== ' + $t + ' ====') 'Cyan' }
function Note-Error([string]$where, $err) {
  $m = ("{0}: {1}" -f $where, $err)
  [void]$script:Errors.Add($m)
}
function Try-Get([scriptblock]$sb, [string]$where) {
  try { $ErrorActionPreference = 'Stop'; & $sb } catch { Note-Error $where $_.Exception.Message; $null }
}
function Ask([string]$q) {
  if (-not $script:Interactive) { return '' }
  $a = Read-Host $q
  if ($null -eq $a) { return '' }
  return ([string]$a).Trim().ToLower()
}
function Is-Yes([string]$a) { return (@('y','yes','д','да','da','н','s','sim','si') -contains $a) }
function Fmt-GB($bytes) { if ($null -eq $bytes) { return '?' }; return ('{0:N1} ГБ' -f ([double]$bytes / 1GB)) }
function Fmt-MB($bytes) { if ($null -eq $bytes) { return '?' }; return ('{0:N0} МБ' -f ([double]$bytes / 1MB)) }
function Fmt-Size($bytes) { if ($null -eq $bytes) { return '?' }; if ($bytes -ge 1GB) { return (Fmt-GB $bytes) }; return (Fmt-MB $bytes) }

function Test-Admin {
  try {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# ---------------------------------------------------------------- пользователь, чей рабочий стол открыт

function Get-TargetUser {
  $u = [ordered]@{ Sid = $null; Name = $env:USERNAME; Profile = $env:USERPROFILE; Source = 'current' }
  try { $cur = [Security.Principal.WindowsIdentity]::GetCurrent(); $u.Sid = $cur.User.Value; $u.Name = $cur.Name } catch {}
  if ($CurrentUser) { $u.ShortName = ($u.Name -split '\\')[-1]; return [pscustomobject]$u }
  $cur = @{ Sid = $u.Sid; Name = $u.Name }
  try {
    $sess = (Get-Process -Id $PID).SessionId
    $ex = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Where-Object { $_.SessionId -eq $sess }) | Select-Object -First 1
    if ($ex) {
      $o = Invoke-CimMethod -InputObject $ex -MethodName GetOwnerSid -ErrorAction Stop
      if ($o.Sid) {
        if ($o.Sid -ne $u.Sid) { $u.Source = 'explorer' }
        $u.Sid = $o.Sid
        $ow = Invoke-CimMethod -InputObject $ex -MethodName GetOwner -ErrorAction Stop
        if ($ow.User) { $u.Name = ('{0}\{1}' -f $ow.Domain, $ow.User) }
      }
    }
  } catch { Note-Error 'TargetUser' $_.Exception.Message }
  $pl = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($u.Sid)"
  $okProfile = $false
  try {
    $pp = (Get-ItemProperty -LiteralPath $pl -ErrorAction Stop).ProfileImagePath
    if ($pp) { $pp = [Environment]::ExpandEnvironmentVariables($pp); if (Test-Path -LiteralPath $pp) { $u.Profile = $pp; $okProfile = $true } }
  } catch {}
  # чужой профиль не найден или его реестр не загружен — работаем с текущей учёткой, чтобы не смешивать
  if ($u.Source -eq 'explorer' -and (-not $okProfile -or -not (Test-Path -LiteralPath "Registry::HKEY_USERS\$($u.Sid)"))) {
    $u.Sid = $cur.Sid; $u.Name = $cur.Name; $u.Profile = $env:USERPROFILE; $u.Source = 'current'
  }
  $u.ShortName = ($u.Name -split '\\')[-1]
  return [pscustomobject]$u
}

# ---------------------------------------------------------------- реестр

function Get-RegValue([string]$path, [string]$name) {
  try {
    $k = Get-Item -LiteralPath $path -ErrorAction Stop
    if (@($k.GetValueNames()) -notcontains $name) { return $null }
    $kind = $k.GetValueKind($name).ToString()
    $val = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [pscustomobject]@{ Kind = $kind; Value = $val }
  } catch { return $null }
}
function Get-RegData([string]$path, [string]$name) { $v = Get-RegValue $path $name; if ($v) { return $v.Value }; return $null }

function ConvertTo-JValue([string]$kind, $val) {
  switch ($kind) {
    'Binary' { return [Convert]::ToBase64String([byte[]]$val) }
    'MultiString' { return ,@($val) }
    default { return $val }
  }
}
function ConvertFrom-JValue([string]$kind, $j) {
  switch ($kind) {
    'Binary' { return ,([byte[]][Convert]::FromBase64String([string]$j)) }
    'MultiString' { return ,([string[]]@($j)) }
    'DWord' { return [int]$j }
    'QWord' { return [long]$j }
    default { return [string]$j }
  }
}
function Set-RegValueRaw([string]$path, [string]$name, [string]$kind, $value) {
  if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
  New-ItemProperty -LiteralPath $path -Name $name -PropertyType $kind -Value $value -Force -ErrorAction Stop | Out-Null
}

# белый список записи в реестр
$script:AllowedReg = @(
  '^Registry::HKEY_(USERS\\[^\\]+|LOCAL_MACHINE)\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\(Run|Run32|StartupFolder)$',
  '^Registry::HKEY_USERS\\[^\\]+\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppModel\\SystemAppData\\[^\\]+\\[^\\]+$'
)
function Test-RegWriteAllowed([string]$path, [string]$name) {
  foreach ($p in $script:AllowedReg) { if ($path -match $p) { return $true } }
  if (Get-Command Test-TweakKey -ErrorAction SilentlyContinue) { return (Test-TweakKey $path) }
  return $false
}

# ---------------------------------------------------------------- журнал

function Start-Journal {
  New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
  $id = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
  $script:JournalPath = Join-Path $script:BackupDir "$id.json"
  $script:Journal = [ordered]@{
    kit = 'win-kit'; version = $script:Version; created = (Get-Date).ToString('s')
    computer = $env:COMPUTERNAME; userSid = $script:User.Sid
    entries = (New-Object System.Collections.ArrayList)
  }
  Save-Journal
}
function Save-Journal {
  $txt = ConvertTo-Json -InputObject $script:Journal -Depth 8
  [IO.File]::WriteAllText($script:JournalPath, $txt, $script:Utf8Bom)
}
function Add-JournalEntry($e) { [void]$script:Journal.entries.Add($e); Save-Journal }

function Set-RegJournaled([string]$path, [string]$name, [string]$kind, $value, [string]$batch, [string]$label) {
  if (-not (Test-RegWriteAllowed $path $name)) { throw "запись в реестр вне белого списка: $path [$name]" }
  $old = Get-RegValue $path $name
  $e = [ordered]@{ type = 'registry'; path = $path; name = $name; existed = ($null -ne $old); keyExisted = (Test-Path -LiteralPath $path); kind = $null; old = $null
                   newKind = $kind; batch = $batch; label = $label; time = (Get-Date).ToString('s') }
  if ($old) { $e.kind = $old.Kind; $e.old = ConvertTo-JValue $old.Kind $old.Value }
  Add-JournalEntry $e
  Set-RegValueRaw $path $name $kind $value
}

# ---------------------------------------------------------------- файлы и подписи

function Get-ExeFromCommand([string]$cmd) {
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $null }
  $c = [Environment]::ExpandEnvironmentVariables($cmd.Trim())
  $exe = $null
  if ($c.StartsWith('"')) {
    $i = $c.IndexOf('"', 1)
    if ($i -gt 1) { $exe = $c.Substring(1, $i - 1) }
  } else {
    $m = [regex]::Match($c, '^(.+?\.(exe|cmd|bat|com|vbs|js|ps1|lnk|scr|pif))(\s|,|$)', 'IgnoreCase')
    if ($m.Success) { $exe = $m.Groups[1].Value } else { $exe = ($c -split '\s+')[0] }
  }
  if ($exe -and $exe -notmatch '^[A-Za-z]:\\|^\\\\') {
    foreach ($d in @("$env:windir\System32", $env:windir, "$env:windir\SysWOW64")) {
      $p = Join-Path $d $exe
      if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
      if (Test-Path -LiteralPath "$p.exe" -PathType Leaf) { return "$p.exe" }
    }
  }
  return $exe
}

function Get-LnkTarget([string]$path) {
  try {
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($path)
    return (('"{0}" {1}' -f $l.TargetPath, $l.Arguments).Trim())
  } catch { return $null }
}

function Get-FileSigInfo([string]$path) {
  if ($script:SigCache.ContainsKey($path)) { return $script:SigCache[$path] }
  $r = [pscustomobject]@{ Status = '?'; Publisher = '' }
  try {
    $s = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
    $r.Status = [string]$s.Status
    if ($s.SignerCertificate) {
      $m = [regex]::Match($s.SignerCertificate.Subject, 'CN="?([^",]+)')
      if ($m.Success) { $r.Publisher = $m.Groups[1].Value }
    }
  } catch {}
  if (-not $r.Publisher) {
    try { $vi = (Get-Item -LiteralPath $path -ErrorAction Stop).VersionInfo; if ($vi.CompanyName) { $r.Publisher = $vi.CompanyName.Trim() } } catch {}
  }
  $script:SigCache[$path] = $r
  return $r
}

# обход папки БЕЗ захода в ссылки/соединения (junction) — чтобы очистка не ушла за пределы папки
function Get-FilesSafe([string]$path, [int]$minAgeHours = 0, [string]$filter = '') {
  $res = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return ,$res }
  $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return ,$res }
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return ,$res }
  $cut = (Get-Date).AddHours(-$minAgeHours)
  if (-not $item.PSIsContainer) {
    if ($minAgeHours -le 0 -or $item.LastWriteTime -lt $cut) { $res.Add($item) }
    return ,$res
  }
  $stack = New-Object System.Collections.Stack
  $stack.Push((New-Object IO.DirectoryInfo $item.FullName))
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    $entries = $null
    try { $entries = $d.GetFileSystemInfos() } catch { continue }
    foreach ($e in $entries) {
      if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      if ($e -is [IO.DirectoryInfo]) { $stack.Push($e); continue }
      if ($filter -and ($e.Name -notlike $filter)) { continue }
      if ($minAgeHours -gt 0 -and $e.LastWriteTime -ge $cut) { continue }
      $res.Add([IO.FileInfo]$e)
    }
  }
  return ,$res
}
function Get-SizeSafe([string]$path, [int]$minAgeHours = 0, [string]$filter = '') {
  $sum = [long]0
  foreach ($f in (Get-FilesSafe $path $minAgeHours $filter)) { $sum += $f.Length }
  return $sum
}

# ---------------------------------------------------------------- списки

function Read-Tsv([string]$name) {
  $p = Join-Path $script:Root ("data\" + $name)
  $rows = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $p)) { Note-Error 'Read-Tsv' "нет файла data\$name"; return ,$rows }
  $lines = @(Get-Content -LiteralPath $p -Encoding UTF8)
  if ($lines.Count -lt 2) { return ,$rows }
  $hdr = ($lines[0].TrimStart([char]0xFEFF)) -split "`t"
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ([string]::IsNullOrWhiteSpace($l) -or $l.StartsWith('#')) { continue }
    $c = $l -split "`t"
    $o = [ordered]@{}
    for ($j = 0; $j -lt $hdr.Count; $j++) { if ($j -lt $c.Count) { $o[$hdr[$j]] = $c[$j] } else { $o[$hdr[$j]] = '' } }
    [void]$rows.Add([pscustomobject]$o)
  }
  return ,$rows
}

# то, что не трогаем никогда (сильнее любых списков)
$script:HardProtect = '(?i)anydesk|securityhealth|windows ?defender|msmpeng|msascui|\bctfmon|kaspersky|\bavp(ui)?\b|\beset\b|ekrn|egui|avast|\bavg\b|bitdefender|norton|mcafee|malwarebytes|\bmbam|sophos|trend ?micro|f-secure|webroot|dr\.?web|comodo|panda ?(security|dome)|360(safe|tray|total)|\bexplorer\.exe|userinit|realtek|rtkaud|rthdvcpl|synaptics|syntp|etdctrl|apoint|dolby|nahimic|maxxaudio|smartaudio|bluetooth|btvstack|hotkey|touchpad|punto|keepass|bitwarden|1password|lastpass|dashlane'

function Get-Rule($rules, [string]$kind, [string]$text) {
  foreach ($r in $rules) {
    if ($r.kind -ne '*' -and $r.kind -ne $kind) { continue }
    try { if ($text -match ('(?i)' + $r.match)) { return $r } } catch { Note-Error 'rule' $r.match }
  }
  return $null
}

# ================================================================ ДИАГНОСТИКА (только чтение)

function Get-Events([hashtable]$filter, [int]$max = 200) {
  try { return @(Get-WinEvent -FilterHashtable $filter -MaxEvents $max -ErrorAction Stop) }
  catch {
    if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound' -and $_.Exception.Message -notmatch 'No events were found|There is not an event|не найдено|nenhum evento|no se encontr') {
      Note-Error ('events ' + $filter.LogName) $_.Exception.Message
    }
    return @()
  }
}
function Get-EventData($ev) {
  $h = @{}
  try {
    $x = [xml]$ev.ToXml()
    foreach ($d in @($x.Event.EventData.Data)) { if ($d -and $d.Name) { $h[$d.Name] = $d.'#text' } }
  } catch {}
  return $h
}

function Get-SysInfo {
  $os = Try-Get { Get-CimInstance Win32_OperatingSystem } 'Win32_OperatingSystem'
  $cs = Try-Get { Get-CimInstance Win32_ComputerSystem } 'Win32_ComputerSystem'
  $cpu = @(Try-Get { Get-CimInstance Win32_Processor } 'Win32_Processor') | Select-Object -First 1
  $cv = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $build = [int](Get-RegData $cv 'CurrentBuildNumber')
  $s = [ordered]@{
    Manufacturer = $cs.Manufacturer; Model = $cs.Model
    Caption = $os.Caption; Build = $build; UBR = (Get-RegData $cv 'UBR'); DisplayVersion = (Get-RegData $cv 'DisplayVersion')
    Edition = (Get-RegData $cv 'EditionID'); ProductType = $os.ProductType; Arch = $os.OSArchitecture
    IsWin11 = ($build -ge 22000); InstallDate = $os.InstallDate; LastBoot = $os.LastBootUpTime
    UptimeDays = $null; Cpu = $cpu.Name; Cores = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors
    RamGB = $null; RamUsedPct = $null; PartOfDomain = $cs.PartOfDomain; Domain = $cs.Domain
    PcType = $cs.PCSystemType; Language = (Get-Culture).Name; UiLanguage = (Get-UICulture).Name
  }
  if ($os.LastBootUpTime) { $s.UptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) }
  if ($os.TotalVisibleMemorySize) {
    $s.RamGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $s.RamUsedPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
  }
  if ($s.Caption) { $s.Caption = ($s.Caption -replace '^Microsoft\s+', '') }
  if ($s.IsWin11 -and $s.Caption -match 'Windows 10') { $s.Caption = $s.Caption -replace 'Windows 10', 'Windows 11' }
  return [pscustomobject]$s
}

function Get-Activation {
  $p = @(Try-Get { Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" } 'Activation')
  $p = @($p | Where-Object { $_ })
  if ($p.Count -eq 0) { return 'неизвестно' }
  if (@($p | Where-Object { $_.LicenseStatus -eq 1 }).Count -gt 0) { return 'активирована' }
  return 'НЕ активирована'
}

function Test-PendingReboot {
  $r = @()
  if (Test-Path -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $r += 'обслуживание компонентов' }
  if (Test-Path -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $r += 'Центр обновлений' }
  return ,$r
}

function Test-Win11Cpu([string]$name) {
  if (-not $name) { return 'unknown' }
  if ($name -match 'Core\(TM\) (Ultra )?[3579] ' -or $name -match 'Core Ultra') { return 'yes' }
  $m = [regex]::Match($name, 'i[3579]-(\d{4,5})')
  if ($m.Success) {
    $n = $m.Groups[1].Value
    if ($n.Length -eq 5) { $gen = [int]$n.Substring(0, 2) } else { $gen = [int]$n.Substring(0, 1) }
    if ($gen -ge 8) { return 'yes' }; if ($gen -le 6) { return 'no' }; return 'unknown'
  }
  if ($name -match 'Ryzen AI|Ryzen \d+ \d+ ') { return 'yes' }
  $m = [regex]::Match($name, 'Ryzen (?:Threadripper )?(?:PRO )?\d?\s*(\d)(\d{2,3})([A-Z]*)')
  if ($m.Success) {
    $ser = [int]$m.Groups[1].Value
    if ($ser -ge 3) { return 'yes' }
    if ($ser -eq 1) { return 'no' }
    if ($m.Groups[3].Value -match 'G|U|H') { return 'unknown' }
    return 'yes'
  }
  if ($name -match 'Snapdragon') { return 'yes' }
  if ($name -match '(Celeron|Pentium).*(N4\d{3}|N5\d{3}|N6\d{3}|J4\d{3}|J5\d{3}|Silver|Gold [67]\d{3})') { return 'yes' }
  if ($name -match '(Celeron|Pentium|Atom|Core\(TM\)2|Athlon\(tm\) (II|64)|Phenom|AMD [AE]\d|FX-)') { return 'no' }
  return 'unknown'
}

function Get-Win11Readiness($sys, $disks) {
  $r = [ordered]@{ Tpm = '?'; SecureBoot = '?'; Cpu = (Test-Win11Cpu $sys.Cpu); Ram = ($sys.RamGB -ge 3.8); Disk = $null; Verdict = '' ; Blockers = @() }
  $tpm = Try-Get { Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName Win32_Tpm } 'TPM'
  if ($tpm) { if ([string]$tpm.SpecVersion -match '^2\.0') { $r.Tpm = '2.0' } else { $r.Tpm = ([string]$tpm.SpecVersion -split ',')[0] } } else { $r.Tpm = 'нет/выключен' }
  try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop; if ($sb) { $r.SecureBoot = 'включён' } else { $r.SecureBoot = 'UEFI, выключен' } }
  catch { if ($_.Exception.Message -match 'not supported|не поддерж') { $r.SecureBoot = 'BIOS (Legacy)' } else { $r.SecureBoot = '?' } }
  $sysDisk = @($disks | Where-Object { $_.System }) | Select-Object -First 1
  if ($sysDisk) { $r.Disk = ($sysDisk.Size -ge 60GB) }
  $b = @()
  if ($r.Tpm -ne '2.0') { $b += "TPM 2.0 ($($r.Tpm))" }
  if ($r.SecureBoot -eq 'BIOS (Legacy)') { $b += 'старый режим BIOS (нужен UEFI)' }
  if ($r.Cpu -eq 'no') { $b += 'процессор не поддерживается' }
  if (-not $r.Ram) { $b += 'мало памяти (< 4 ГБ)' }
  if ($r.Disk -eq $false) { $b += 'маленький диск (< 64 ГБ)' }
  $r.Blockers = $b
  if ($b.Count -eq 0 -and $r.Cpu -eq 'yes') { $r.Verdict = 'можно обновить до Windows 11' }
  elseif ($b.Count -eq 0) { $r.Verdict = 'вероятно можно (процессор проверить вручную)' }
  else { $r.Verdict = 'официально нельзя: ' + ($b -join ', ') }
  return [pscustomobject]$r
}

function Get-DiskInfo {
  $res = New-Object System.Collections.ArrayList
  $sysNum = $null
  try { $sysNum = (Get-Partition -DriveLetter ($env:SystemDrive.Substring(0, 1)) -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number } catch {}
  $pds = @(Try-Get { Get-PhysicalDisk } 'Get-PhysicalDisk')
  foreach ($d in $pds) {
    if (-not $d) { continue }
    $o = [ordered]@{ Name = $d.FriendlyName; Media = [string]$d.MediaType; Bus = [string]$d.BusType; Health = [string]$d.HealthStatus
                     Size = [long]$d.Size; System = ([string]$d.DeviceId -eq [string]$sysNum); Wear = $null; TempC = $null
                     ReadErrors = $null; PowerOnHours = $null; Type = '' }
    try {
      $rc = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction Stop
      $o.Wear = $rc.Wear; $o.TempC = $rc.Temperature; $o.ReadErrors = $rc.ReadErrorsUncorrected; $o.PowerOnHours = $rc.PowerOnHours
    } catch {}
    if ($o.Media -eq 'SSD' -or $o.Bus -eq 'NVMe') { $o.Type = 'SSD' } elseif ($o.Media -eq 'HDD') { $o.Type = 'HDD' } else { $o.Type = '?' }
    [void]$res.Add([pscustomobject]$o)
  }
  return ,$res
}

function Get-Volumes {
  $v = @(Try-Get { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' } 'LogicalDisk')
  return ,@($v | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Drive = $_.DeviceID; Size = [long]$_.Size; Free = [long]$_.FreeSpace; FreePct = $(if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size) } else { $null }); Label = $_.VolumeName } })
}

function Get-BatteryInfo {
  $b = @(Try-Get { Get-CimInstance Win32_Battery } 'Win32_Battery') | Where-Object { $_ }
  if (@($b).Count -eq 0) { return ,@() }
  $res = New-Object System.Collections.ArrayList
  try {
    $tmp = Join-Path $env:TEMP ('winkit_battery_{0}.xml' -f $PID)
    & powercfg.exe /batteryreport /xml /output $tmp 2>&1 | Out-Null
    if (Test-Path -LiteralPath $tmp) {
      [xml]$x = Get-Content -LiteralPath $tmp -Raw
      foreach ($bb in @($x.BatteryReport.Batteries.Battery)) {
        $des = [double]$bb.DesignCapacity; $full = [double]$bb.FullChargeCapacity
        $wear = $null; if ($des -gt 0) { $wear = [math]::Round(100 * (1 - $full / $des)) }
        $cyc = $bb.CycleCount; if ([string]$cyc -eq '0') { $cyc = '?' }
        [void]$res.Add([pscustomobject]@{ Name = $bb.Id; DesignmWh = $des; FullmWh = $full; WearPct = $wear; Cycles = $cyc })
      }
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  } catch { Note-Error 'battery' $_.Exception.Message }
  return ,$res
}

function Get-BootInfo {
  $r = [ordered]@{ Boots = @(); Degraders = @(); LastBootMs = $null; LastBootTime = $null }
  $evs = Get-Events @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } 10
  $boots = @()
  foreach ($e in $evs) {
    $d = Get-EventData $e
    $boots += [pscustomobject]@{ Time = $e.TimeCreated; BootMs = [int]$d['BootTime']; MainPathMs = [int]$d['MainPathBootTime']; PostBootMs = [int]$d['BootPostBootTime'] }
  }
  $r.Boots = $boots
  if ($boots.Count -gt 0) { $r.LastBootMs = $boots[0].BootMs; $r.LastBootTime = $boots[0].Time }
  $deg = Get-Events @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = @(101, 102, 103, 109); StartTime = (Get-Date).AddDays(-60) } 300
  $agg = @{}
  foreach ($e in $deg) {
    $d = Get-EventData $e
    $n = $d['FriendlyName']; if (-not $n) { $n = $d['Name'] }; if (-not $n) { continue }
    $t = [int]$d['DegradationTime']
    if (-not $agg.ContainsKey($n) -or $agg[$n] -lt $t) { $agg[$n] = $t }
  }
  $r.Degraders = @($agg.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Name = $_.Key; DelayMs = $_.Value } })
  return [pscustomobject]$r
}

function Get-Stability {
  $since = (Get-Date).AddDays(-30)
  $r = [ordered]@{}
  $r.BugChecks = @(Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } 50 | ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Text = (($_.Message -split "`n")[0]) } })
  $kp = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } 50
  $r.UnexpectedShutdowns = @($kp).Count
  $r.KernelPowerBugcheck = @($kp | Where-Object { $d = Get-EventData $_; $d['BugcheckCode'] -and $d['BugcheckCode'] -ne '0' }).Count
  $sysErr = @(Get-Events @{ LogName = 'System'; Level = @(1, 2, 3); StartTime = $since } 3000)
  $r.Whea = @($sysErr | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -and $_.Level -le 2 }).Count
  $r.DiskErrors = @($sysErr | Where-Object { @('disk', 'Ntfs', 'stornvme', 'storahci', 'iaStorA', 'iaStorAC', 'iaStorAVC') -contains $_.ProviderName -and @(7, 11, 51, 55, 129, 153, 98) -contains $_.Id }).Count
  $crashes = Get-Events @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } 300
  $r.AppCrashes = @($crashes | ForEach-Object { if ($_.Properties.Count -gt 0) { [string]$_.Properties[0].Value } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { [pscustomobject]@{ App = $_.Name; Count = $_.Count } })
  $md = Join-Path $env:windir 'Minidump'
  $r.Minidumps = @(Get-ChildItem -LiteralPath $md -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Time = $_.LastWriteTime } })
  return [pscustomobject]$r
}

function Get-ProcessInfo {
  $r = [ordered]@{ TopMem = @(); TopCpu = @(); CpuTotal = $null; Count = 0 }
  $ps = @(Get-Process -ErrorAction SilentlyContinue)
  $r.Count = $ps.Count
  $r.TopMem = @($ps | Group-Object ProcessName | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MemMB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) } } | Sort-Object MemMB -Descending | Select-Object -First 12)
  try {
    $null = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop
    Start-Sleep -Seconds 2
    $pp = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop)
    $tot = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
    $r.CpuTotal = [int]$tot.PercentProcessorTime
    $lp = [Environment]::ProcessorCount
    $r.TopCpu = @($pp | Where-Object { $_.Name -notin @('_Total', 'Idle') } | ForEach-Object { [pscustomobject]@{ Name = ($_.Name -replace '#\d+$', ''); P = [double]$_.PercentProcessorTime } } | Group-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; CpuPct = [math]::Round((($_.Group | Measure-Object P -Sum).Sum) / $lp, 1) } } | Sort-Object CpuPct -Descending | Select-Object -First 8)
  } catch { Note-Error 'cpu' $_.Exception.Message }
  return [pscustomobject]$r
}

function Get-PowerInfo {
  $r = [ordered]@{ PlanName = ''; PlanGuid = ''; FastStartup = $null; Hibernate = $null; HiberfilBytes = $null; HasBattery = $false; Plans = @() }
  try {
    $out = & powercfg.exe /getactivescheme 2>$null
    $m = [regex]::Match(($out -join ' '), '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\(([^)]*)\)')
    if ($m.Success) { $r.PlanGuid = $m.Groups[1].Value.ToLower(); $r.PlanName = $m.Groups[2].Value }
    $lst = & powercfg.exe /list 2>$null
    $r.Plans = @([regex]::Matches(($lst -join "`n"), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLower() })
  } catch { Note-Error 'powercfg' $_.Exception.Message }
  $r.FastStartup = Get-RegData 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
  $r.Hibernate = Get-RegData 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
  try { $h = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction Stop; $r.HiberfilBytes = $h.Length } catch {}
  $r.HasBattery = (@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0)
  return [pscustomobject]$r
}

function Get-DeviceErrors {
  $d = @(Try-Get { Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' } 'PnP')
  return ,@($d | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Code = $_.ConfigManagerErrorCode; Class = $_.PNPClass } })
}

function Get-UpdateInfo {
  $r = [ordered]@{ LastHotfix = $null; LastSuccess = $null; Failed30d = 0; Recent = @() }
  try { $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1; if ($hf) { $r.LastHotfix = $hf.InstalledOn } } catch {}
  try {
    $s = New-Object -ComObject Microsoft.Update.Session
    $sr = $s.CreateUpdateSearcher()
    $n = $sr.GetTotalHistoryCount()
    if ($n -gt 0) {
      $hist = $sr.QueryHistory(0, [math]::Min(40, $n))
      $items = @()
      foreach ($h in $hist) { $items += [pscustomobject]@{ Date = $h.Date.ToLocalTime(); Title = $h.Title; Result = $h.ResultCode } }
      $ok = @($items | Where-Object { $_.Result -eq 2 } | Sort-Object Date -Descending)
      if ($ok.Count -gt 0) { $r.LastSuccess = $ok[0].Date }
      $r.Failed30d = @($items | Where-Object { $_.Result -in @(4, 5) -and $_.Date -gt (Get-Date).AddDays(-30) }).Count
      $r.Recent = @($items | Sort-Object Date -Descending | Select-Object -First 8)
    }
  } catch { Note-Error 'WindowsUpdate' $_.Exception.Message }
  return [pscustomobject]$r
}

function Get-InstalledPrograms {
  $keys = @(
    @{ K = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'все' },
    @{ K = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; S = 'все (32)' },
    @{ K = "Registry::HKEY_USERS\$($script:User.Sid)\Software\Microsoft\Windows\CurrentVersion\Uninstall"; S = 'пользователь' }
  )
  $seen = @{}
  $res = New-Object System.Collections.ArrayList
  foreach ($k in $keys) {
    foreach ($sub in @(Get-ChildItem -LiteralPath $k.K -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
      if (-not $p -or -not $p.DisplayName) { continue }
      if ($p.SystemComponent -eq 1 -or $p.ParentKeyName) { continue }
      $id = ('{0}|{1}' -f $p.DisplayName, $p.DisplayVersion)
      if ($seen.ContainsKey($id)) { continue }; $seen[$id] = 1
      $date = $null
      if ($p.InstallDate -match '^\d{8}$') { try { $date = [datetime]::ParseExact($p.InstallDate, 'yyyyMMdd', $null) } catch {} }
      [void]$res.Add([pscustomobject]@{ Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Publisher = [string]$p.Publisher; Installed = $date
        SizeMB = $(if ($p.EstimatedSize) { [math]::Round($p.EstimatedSize / 1024) } else { $null }); Scope = $k.S; Key = $sub.PSChildName
        KeyPath = ($k.K + '\' + $sub.PSChildName); Uninstall = [string]$p.UninstallString; Quiet = [string]$p.QuietUninstallString })
    }
  }
  return ,@($res | Sort-Object Name)
}

function Get-SecurityInfo {
  $r = [ordered]@{ Defender = $null; AvProducts = @(); Threats = @(); BitLocker = '?'; Hosts = @(); Proxy = $null; Dns = @(); Managed = @(); }
  $mp = Try-Get { Get-MpComputerStatus } 'Defender'
  if ($mp) {
    $r.Defender = [pscustomobject]@{ Service = $mp.AMServiceEnabled; Antivirus = $mp.AntivirusEnabled; RealTime = $mp.RealTimeProtectionEnabled
      SignaturesAgeDays = $mp.AntivirusSignatureAge; LastQuickScanDays = $mp.QuickScanAge; Tamper = $mp.IsTamperProtected; Mode = [string]$mp.AMRunningMode }
  }
  $av = @()
  if ($script:Sys.ProductType -eq 1) { $av = @(Try-Get { Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct } 'SecurityCenter2') }
  $r.AvProducts = @($av | Where-Object { $_ } | ForEach-Object {
    $hex = '{0:X6}' -f [int]$_.productState
    [pscustomobject]@{ Name = $_.displayName; Enabled = (@('10', '11') -contains $hex.Substring(2, 2)); UpToDate = ($hex.Substring(4, 2) -eq '00') }
  })
  try {
    $det = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-90) })
    if ($det.Count -gt 0) {
      $names = @{}; foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $names[[string]$t.ThreatID] = $t.ThreatName }
      $r.Threats = @($det | ForEach-Object { [pscustomobject]@{ Time = $_.InitialDetectionTime; Name = $names[[string]$_.ThreatID]; Resources = (@($_.Resources) -join '; ') } })
    }
  } catch {}
  $bl = Try-Get { Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter ("DriveLetter='{0}'" -f $env:SystemDrive) } 'BitLocker'
  if ($bl) { switch ([int]$bl.ProtectionStatus) { 0 { $r.BitLocker = 'выключен' } 1 { $r.BitLocker = 'ВКЛЮЧЁН' } default { $r.BitLocker = 'неизвестно' } } }
  try {
    $r.Hosts = @(Get-Content -LiteralPath "$env:windir\System32\drivers\etc\hosts" -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') -and $_ -notmatch '^(127\.0\.0\.1|::1)\s+localhost\s*$' })
  } catch {}
  $is = "Registry::HKEY_USERS\$($script:User.Sid)\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
  $r.Proxy = [pscustomobject]@{ Enabled = (Get-RegData $is 'ProxyEnable'); Server = (Get-RegData $is 'ProxyServer'); Pac = (Get-RegData $is 'AutoConfigURL') }
  try { $r.Dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique) } catch {}
  # рабочий (управляемый) ПК
  if ($script:Sys.PartOfDomain) { $r.Managed += ('в домене ' + $script:Sys.Domain) }
  try {
    $ds = & dsregcmd.exe /status 2>$null
    if (($ds -join "`n") -match '(?m)^\s*AzureAdJoined\s*:\s*YES') { $r.Managed += 'присоединён к Entra ID (Azure AD)' }
  } catch {}
  foreach ($en in @(Get-ChildItem -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -LiteralPath $en.PSPath -ErrorAction SilentlyContinue
    if ($p -and $p.ProviderID -eq 'MS DM Server' -and $p.UPN) { $r.MdmNote = 'зарегистрирован в MDM (Intune) — ' + $p.UPN; break }
  }
  return [pscustomobject]$r
}

# ---------------------------------------------------------------- автозагрузка

function New-StartupItem([string]$kind, [string]$name, [string]$cmd, [string]$where, [string]$approvedKey, [string]$approvedName) {
  $exe = Get-ExeFromCommand $cmd
  $it = [ordered]@{ Kind = $kind; Name = $name; Command = $cmd; Exe = $exe; Where = $where; ApprovedKey = $approvedKey; ApprovedName = $approvedName
                    Enabled = $true; Publisher = ''; Signed = ''; Exists = $null }
  if ($kind -eq 'startup') {
    $v = Get-RegValue $approvedKey $approvedName
    if ($v -and $v.Kind -eq 'Binary' -and @($v.Value).Count -ge 1) { $it.Enabled = (([byte[]]$v.Value)[0] -band 1) -eq 0 }
  }
  if ($exe -and $exe -match '^[A-Za-z]:\\') {
    $it.Exists = (Test-Path -LiteralPath $exe -PathType Leaf)
    if ($it.Exists) { $s = Get-FileSigInfo $exe; $it.Publisher = $s.Publisher; $it.Signed = $s.Status }
  }
  return [pscustomobject]$it
}

function Get-StartupItems {
  $list = New-Object System.Collections.ArrayList
  $hku = "Registry::HKEY_USERS\$($script:User.Sid)"
  $hklm = 'Registry::HKEY_LOCAL_MACHINE'
  $sa = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
  $src = @(
    @{ W = 'Реестр (пользователь)'; K = "$hku\Software\Microsoft\Windows\CurrentVersion\Run"; A = "$hku\$sa\Run" },
    @{ W = 'Реестр (все)'; K = "$hklm\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; A = "$hklm\$sa\Run" },
    @{ W = 'Реестр (все, 32)'; K = "$hklm\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; A = "$hklm\$sa\Run32" }
  )
  foreach ($s in $src) {
    try {
      $k = Get-Item -LiteralPath $s.K -ErrorAction Stop
      foreach ($n in $k.GetValueNames()) {
        if ([string]::IsNullOrEmpty($n)) { continue }
        [void]$list.Add((New-StartupItem 'startup' $n ([string]$k.GetValue($n)) $s.W $s.A $n))
      }
    } catch {}
  }
  $uf = Join-Path $script:User.Profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
  $cf = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'
  foreach ($f in @(@{ D = $uf; W = 'Папка «Автозагрузка» (пользователь)'; A = "$hku\$sa\StartupFolder" }, @{ D = $cf; W = 'Папка «Автозагрузка» (все)'; A = "$hklm\$sa\StartupFolder" })) {
    foreach ($file in @(Get-ChildItem -LiteralPath $f.D -File -Force -ErrorAction SilentlyContinue)) {
      if ($file.Name -eq 'desktop.ini') { continue }
      $cmd = '"' + $file.FullName + '"'
      if ($file.Extension -eq '.lnk') { $t = Get-LnkTarget $file.FullName; if ($t) { $cmd = $t } }
      [void]$list.Add((New-StartupItem 'startup' $file.Name $cmd $f.W $f.A $file.Name))
    }
  }
  $base = "$hku\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData"
  foreach ($pkg in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
    foreach ($tk in @(Get-ChildItem -LiteralPath $pkg.PSPath -ErrorAction SilentlyContinue)) {
      $kp = "$base\$($pkg.PSChildName)\$($tk.PSChildName)"
      $st = Get-RegValue $kp 'State'
      if (-not $st -or $st.Kind -ne 'DWord') { continue }
      $nice = $pkg.PSChildName -replace '_[a-z0-9]{13}$', ''
      $it = New-StartupItem 'uwp' $nice $pkg.PSChildName 'Приложение из Магазина' $kp 'State'
      $it.Enabled = ([int]$st.Value -eq 2)
      [void]$list.Add($it)
    }
  }
  return ,$list
}

function Get-ThirdPartyTasks {
  $r = New-Object System.Collections.ArrayList
  foreach ($t in @(Try-Get { Get-ScheduledTask } 'Get-ScheduledTask')) {
    if (-not $t) { continue }
    if ($t.TaskPath -like '\Microsoft\*') { continue }
    $acts = @($t.Actions | Where-Object { $_.Execute } | ForEach-Object { ('{0} {1}' -f $_.Execute, $_.Arguments).Trim() })
    $trig = @($t.Triggers | Where-Object { $_ } | ForEach-Object { ($_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '') }) -join ','
    $exe = $null; if ($acts.Count -gt 0) { $exe = Get-ExeFromCommand $acts[0] }
    $o = [pscustomobject]@{ Kind = 'task'; Name = $t.TaskName; Path = $t.TaskPath; Command = ($acts -join ' ; '); Exe = $exe; Triggers = $trig
                            Enabled = ([string]$t.State -ne 'Disabled'); Publisher = ''; Signed = '' }
    if ($exe -and $exe -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $exe -PathType Leaf)) { $s = Get-FileSigInfo $exe; $o.Publisher = $s.Publisher; $o.Signed = $s.Status }
    [void]$r.Add($o)
  }
  return ,$r
}

function Get-ThirdPartyServices {
  $r = New-Object System.Collections.ArrayList
  foreach ($s in @(Try-Get { Get-CimInstance Win32_Service } 'Win32_Service')) {
    if (-not $s) { continue }
    $exe = Get-ExeFromCommand ([string]$s.PathName)
    if ($exe -and $exe.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not $exe) { continue }
    $delayed = $false
    if ($s.StartMode -eq 'Auto') { if ((Get-RegData "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($s.Name)" 'DelayedAutostart') -eq 1) { $delayed = $true } }
    $pub = ''; if ($exe -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $exe -PathType Leaf)) { $pub = (Get-FileSigInfo $exe).Publisher }
    [void]$r.Add([pscustomobject]@{ Kind = 'service'; Name = $s.Name; Display = $s.DisplayName; Command = $s.PathName; Exe = $exe; StartMode = $s.StartMode
                                    Delayed = $delayed; State = $s.State; Enabled = ($s.StartMode -eq 'Auto'); Publisher = $pub })
  }
  return ,$r
}

# ---------------------------------------------------------------- подозрительное

$script:SuspiciousCmd = '(?i)(\s-e(nc|ncodedcommand)?\s+[A-Za-z0-9+/=]{20,}|frombase64string|-w(indowstyle)?\s+h(idden)?\b|mshta|\bwscript|\bcscript|regsvr32.*(http|scrobj)|rundll32.*(javascript|http)|bitsadmin|certutil.*urlcache|downloadstring|invoke-webrequest|\biwr\b|\biex\b|invoke-expression)'
$script:UserDirs = '(?i)\\AppData\\(Roaming|Local\\Temp)\\|\\Users\\Public\\|\\ProgramData\\[^\\]+\.(exe|dll|vbs|js|bat|cmd|ps1)$|\\Windows\\Temp\\'

function Find-Suspicious($startup, $tasks) {
  $f = New-Object System.Collections.ArrayList
  foreach ($s in @($startup)) {
    if (-not $s.Enabled) { continue }
    $why = @()
    if ($s.Command -match $script:SuspiciousCmd) { $why += 'скрытый скрипт/загрузка из интернета' }
    if ($s.Exe -match $script:UserDirs -and $s.Signed -ne 'Valid') { $why += 'запуск из AppData/Temp без подписи' }
    if ($why.Count) { [void]$f.Add([pscustomobject]@{ What = ('Автозагрузка: ' + $s.Name); Command = $s.Command; Why = ($why -join ', ') }) }
  }
  foreach ($t in @($tasks)) {
    if (-not $t.Enabled) { continue }
    $why = @()
    if ($t.Command -match $script:SuspiciousCmd) { $why += 'скрытый скрипт/загрузка из интернета' }
    if ($t.Exe -match $script:UserDirs -and $t.Signed -ne 'Valid') { $why += 'запуск из AppData/Temp без подписи' }
    if ($why.Count) { [void]$f.Add([pscustomobject]@{ What = ('Задача: ' + $t.Path + $t.Name); Command = $t.Command; Why = ($why -join ', ') }) }
  }
  return ,$f
}

function Find-Pups($programs) {
  $rows = Read-Tsv 'pup.tsv'
  $res = New-Object System.Collections.ArrayList
  $procs = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
  foreach ($r in $rows) {
    $rx = '(?i)' + $r.match
    foreach ($p in @($programs)) {
      try { if ($p.Name -match $rx) { [void]$res.Add([pscustomobject]@{ Kind = $r.kind; Name = $p.Name; Note = $r.note; Source = 'установлено' }) } } catch {}
    }
    if ($r.kind -eq 'remote') {
      foreach ($pn in $procs) { try { if ($pn -match $rx) { [void]$res.Add([pscustomobject]@{ Kind = $r.kind; Name = $pn; Note = $r.note; Source = 'запущено сейчас' }) } } catch {} }
    }
  }
  return ,@($res | Sort-Object Kind, Name, Source -Unique)
}

# ---------------------------------------------------------------- места на диске

function Get-CleanTargets {
  $p = $script:User.Profile
  $L = "$p\AppData\Local"
  $t = @(
    [pscustomobject]@{ Key = 'usertemp'; Title = 'Временные файлы пользователя (старше суток)'; Paths = @("$L\Temp"); Age = 24; Filter = ''; Level = 'auto'; Special = '' },
    [pscustomobject]@{ Key = 'wintemp'; Title = 'Временные файлы Windows (старше суток)'; Paths = @("$env:windir\Temp"); Age = 24; Filter = ''; Level = 'auto'; Special = '' },
    [pscustomobject]@{ Key = 'wudl'; Title = 'Скачанные установщики обновлений Windows'; Paths = @("$env:windir\SoftwareDistribution\Download"); Age = 0; Filter = ''; Level = 'auto'; Special = 'wu' },
    [pscustomobject]@{ Key = 'do'; Title = 'Кэш оптимизации доставки обновлений'; Paths = @("$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"); Age = 0; Filter = ''; Level = 'auto'; Special = 'do' },
    [pscustomobject]@{ Key = 'wer'; Title = 'Отчёты об ошибках Windows'; Paths = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$L\Microsoft\Windows\WER\ReportArchive", "$L\Microsoft\Windows\WER\ReportQueue"); Age = 0; Filter = ''; Level = 'auto'; Special = '' },
    [pscustomobject]@{ Key = 'crashdumps'; Title = 'Дампы сбоев программ'; Paths = @("$L\CrashDumps"); Age = 0; Filter = ''; Level = 'auto'; Special = '' },
    [pscustomobject]@{ Key = 'memdump'; Title = 'Дампы синих экранов (MEMORY.DMP, Minidump)'; Paths = @("$env:windir\MEMORY.DMP", "$env:windir\Minidump"); Age = 0; Filter = ''; Level = 'base'; Special = '' },
    [pscustomobject]@{ Key = 'thumbs'; Title = 'Кэш эскизов (пересоздастся сам)'; Paths = @("$L\Microsoft\Windows\Explorer"); Age = 0; Filter = 'thumbcache_*.db'; Level = 'base'; Special = '' },
    [pscustomobject]@{ Key = 'recycle'; Title = 'Корзина'; Paths = @(); Age = 0; Filter = ''; Level = 'ask'; Special = 'recycle' },
    [pscustomobject]@{ Key = 'browsers'; Title = 'Кэш браузеров (не пароли, не история, не вкладки; браузер закрыть)'; Paths = @(Get-BrowserCachePaths); Age = 0; Filter = ''; Level = 'ask'; Special = 'browsers' },
    [pscustomobject]@{ Key = 'telegram'; Title = 'Кэш фото/видео Telegram (заново скачается из чатов; Telegram закрыть)'; Paths = @(Get-TelegramCachePaths); Age = 0; Filter = ''; Level = 'ask'; Special = 'telegram' },
    [pscustomobject]@{ Key = 'winold'; Title = 'Старая версия Windows (Windows.old) и файлы установки обновлений'; Paths = @("$env:SystemDrive\Windows.old"); Age = 0; Filter = ''; Level = 'ask'; Special = 'winold' },
    [pscustomobject]@{ Key = 'drivers'; Title = 'Старые версии драйверов («Очистка диска» Windows)'; Paths = @(); Age = 0; Filter = ''; Level = 'base'; Special = 'drivers' },
    [pscustomobject]@{ Key = 'dism'; Title = 'Старые компоненты Windows (DISM, 5–30 мин)'; Paths = @(); Age = 0; Filter = ''; Level = 'base'; Special = 'dism' }
  )
  return ,$t
}

function Get-TelegramCachePaths {
  $res = @()
  $R = Join-Path $script:User.Profile 'AppData\Roaming'
  $tds = @("$R\Telegram Desktop\tdata")
  foreach ($pk in @(Get-ChildItem -LiteralPath (Join-Path $script:User.Profile 'AppData\Local\Packages') -Directory -Filter 'TelegramMessengerLLP.TelegramDesktop*' -ErrorAction SilentlyContinue)) {
    $tds += (Join-Path $pk.FullName 'LocalCache\Roaming\Telegram Desktop UWP\tdata')
  }
  foreach ($td in $tds) { foreach ($u in @(Get-ChildItem -LiteralPath $td -Directory -Filter 'user_data*' -ErrorAction SilentlyContinue)) { $res += $u.FullName } }
  return $res
}

function Get-BrowserCachePaths {
  $L = Join-Path $script:User.Profile 'AppData\Local'
  $res = @()
  foreach ($ud in @("$L\Google\Chrome\User Data", "$L\Microsoft\Edge\User Data", "$L\BraveSoftware\Brave-Browser\User Data", "$L\Yandex\YandexBrowser\User Data", "$L\Vivaldi\User Data")) {
    foreach ($prof in @(Get-ChildItem -LiteralPath $ud -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
      foreach ($c in @('Cache', 'Code Cache', 'GPUCache')) { $x = Join-Path $prof.FullName $c; if (Test-Path -LiteralPath $x) { $res += $x } }
    }
  }
  foreach ($prof in @(Get-ChildItem -LiteralPath "$L\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue)) {
    $x = Join-Path $prof.FullName 'cache2'; if (Test-Path -LiteralPath $x) { $res += $x }
  }
  return $res
}

function Get-RecycleBinSize {
  try {
    $sh = New-Object -ComObject Shell.Application
    $sum = [long]0
    foreach ($i in @($sh.NameSpace(10).Items())) { try { $sum += [long]$i.ExtendedProperty('Size') } catch {} }
    return $sum
  } catch { return $null }
}

function Measure-CleanTargets($targets) {
  foreach ($t in $targets) {
    $size = [long]0
    if ($t.Special -eq 'recycle') { $size = Get-RecycleBinSize }
    elseif ($t.Special -eq 'dism' -or $t.Special -eq 'drivers') { $size = $null }
    elseif ($t.Special -eq 'winold') { if (Test-Path -LiteralPath $t.Paths[0]) { $size = (Measure-DirFast $t.Paths[0] (New-Object System.Collections.ArrayList) ((Get-Date).AddSeconds(60))).Size } else { $size = 0 } }
    else { foreach ($p in $t.Paths) { $size += (Get-SizeSafe $p $t.Age $t.Filter) } }
    $t | Add-Member -NotePropertyName Size -NotePropertyValue $size -Force
  }
}

# ---------------------------------------------------------------- замеры «было/стало»

function Get-Metrics($label) {
  $c = @($script:Vols | Where-Object { $_.Drive -eq $env:SystemDrive }) | Select-Object -First 1
  return [pscustomobject]@{
    Time = (Get-Date).ToString('s'); Label = $label; LastBoot = $(if ($script:Sys.LastBoot) { $script:Sys.LastBoot.ToString('s') } else { $null })
    BootMs = $script:Boot.LastBootMs; BootEventTime = $(if ($script:Boot.LastBootTime) { $script:Boot.LastBootTime.ToString('s') } else { $null })
    RamUsedPct = $script:Sys.RamUsedPct; Processes = $script:Procs.Count
    StartupEnabled = @($script:Startup | Where-Object { $_.Enabled }).Count
    FreeGB = $(if ($c) { [math]::Round($c.Free / 1GB, 1) } else { $null })
  }
}
function Get-MetricsHistory {
  $arr = @()
  try {
    if (Test-Path -LiteralPath $script:MetricsPath) {
      $raw = (Get-Content -LiteralPath $script:MetricsPath -Raw -Encoding UTF8) | ConvertFrom-Json
      foreach ($i in $raw) { $arr += $i }
    }
  } catch {}
  return ,$arr
}
function Save-Metrics($m) {
  try {
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    $h = (Get-MetricsHistory) + @($m)
    if ($h.Count -gt 50) { $h = $h[($h.Count - 50)..($h.Count - 1)] }
    [IO.File]::WriteAllText($script:MetricsPath, (ConvertTo-Json -InputObject @($h) -Depth 4), $script:Utf8Bom)
  } catch { Note-Error 'metrics' $_.Exception.Message }
}

# ---------------------------------------------------------------- что занимает место (только когда места мало)

function Measure-DirFast([string]$path, $big, [datetime]$deadline) {
  $sum = [long]0
  try { $di = New-Object IO.DirectoryInfo $path; if (-not $di.Exists -or ($di.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return [pscustomobject]@{ Size = [long]0; Partial = $false } } } catch { return [pscustomobject]@{ Size = [long]0; Partial = $false } }
  $stack = New-Object System.Collections.Stack
  $stack.Push($di)
  $n = 0
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    $entries = $null
    try { $entries = $d.GetFileSystemInfos() } catch { continue }
    foreach ($e in $entries) {
      if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) }
      else { $sum += $e.Length; if ($e.Length -ge 1GB) { [void]$big.Add([pscustomobject]@{ Path = $e.FullName; Size = $e.Length }) } }
    }
    $n++
    if (($n % 300) -eq 0 -and (Get-Date) -gt $deadline) { return [pscustomobject]@{ Size = $sum; Partial = $true } }
  }
  return [pscustomobject]@{ Size = $sum; Partial = $false }
}

function Get-SpaceAdvice([string]$p) {
  $rules = @(
    @('\\Downloads$', 'Загрузки — разобрать с клиентом (старые установщики, видео, архивы)'),
    @('\\(Videos|Pictures|Documents|Desktop|Music|OneDrive[^\\]*)$', 'личные файлы — перенести на другой диск/облако вместе с клиентом'),
    @('\\\$Recycle\.Bin$', 'Корзина — очистить (пункт 2, «спросить клиента»)'),
    @('Windows\.old$', 'старая версия Windows — удаляется через «Очистка диска» (пропадёт откат обновления)'),
    @('\\Windows$', 'система; старые компоненты чистит DISM (пункт 2)'),
    @('hiberfil\.sys$', 'гибернация — «powercfg /h off» освобождает (с клиентом, на ноутбуке подумать)'),
    @('(pagefile|swapfile)\.sys$', 'файл подкачки — не трогать'),
    @('\.vhdx?$|\\(Docker|wsl)\b', 'виртуальный диск (WSL/Docker/виртуальная машина) — чистить изнутри'),
    @('AppData\\Local\\Packages$', 'данные приложений из Магазина (WhatsApp, Telegram, Spotify…)'),
    @('AppData\\Local\\Google$', 'Chrome и кэш Google Диска (DriveFS — размер кэша меняется в настройках Google Диска)'),
    @('AppData\\Local\\Microsoft$', 'кэши Edge/Outlook/Teams/OneDrive'),
    @('Telegram Desktop$', 'кэш Telegram — «Настройки -> Продвинутые -> Управление памятью»'),
    @('WhatsApp', 'медиа WhatsApp — чистить в самом WhatsApp'),
    @('AppData\\Local\\Temp$', 'временные файлы (пункт 2 чистит старше суток)'),
    @('\\(\.nuget|\.gradle|\.m2|\.cache|node_modules|pip|npm-cache|Yarn)$', 'кэш разработчика — можно чистить, если клиент программист'),
    @('Program Files', 'программы — ненужные удалить через «Параметры -> Приложения»'),
    @('\\ProgramData$', 'данные программ (антивирусы, кэши установщиков)')
  )
  foreach ($r in $rules) { if ($p -match ('(?i)' + $r[0])) { return $r[1] } }
  return ''
}

function Get-SpaceUsage {
  $t0 = Get-Date
  $deadline = $t0.AddSeconds(180)
  $big = New-Object System.Collections.ArrayList
  $buckets = New-Object System.Collections.ArrayList
  $root = $env:SystemDrive + '\'
  $prof = $script:User.Profile
  $usersDir = Split-Path -Parent $prof
  $RP = [IO.FileAttributes]::ReparsePoint
  foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($d.Attributes -band $RP) { continue }
    if ($d.FullName -ne $usersDir) { [void]$buckets.Add($d.FullName); continue }
    foreach ($u in @(Get-ChildItem -LiteralPath $usersDir -Directory -Force -ErrorAction SilentlyContinue)) {
      if ($u.Attributes -band $RP) { continue }
      if ($u.FullName -ne $prof) { [void]$buckets.Add($u.FullName); continue }
      foreach ($c in @(Get-ChildItem -LiteralPath $prof -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($c.Attributes -band $RP) { continue }
        if ($c.Name -ne 'AppData') { [void]$buckets.Add($c.FullName); continue }
        foreach ($a in @('Local', 'Roaming', 'LocalLow')) {
          foreach ($x in @(Get-ChildItem -LiteralPath (Join-Path $c.FullName $a) -Directory -Force -ErrorAction SilentlyContinue)) {
            if (-not ($x.Attributes -band $RP)) { [void]$buckets.Add($x.FullName) }
          }
        }
      }
    }
  }
  # сначала то, что можно разобрать с клиентом (профиль), системные папки — в конце
  $win = $env:windir
  $ordered = @($buckets | Sort-Object {
    if ($_.StartsWith($prof + '\', [StringComparison]::OrdinalIgnoreCase)) { 0 }
    elseif ($_.StartsWith($usersDir + '\', [StringComparison]::OrdinalIgnoreCase)) { 1 }
    elseif ($_ -match '(?i)Windows\.old$|\$Recycle\.Bin$') { 2 }
    elseif ($_ -eq $win) { 6 }
    elseif ($_ -match '(?i)\\Program Files') { 5 }
    elseif ($_ -match '(?i)\\ProgramData$') { 3 }
    else { 4 }
  })
  $res = New-Object System.Collections.ArrayList
  $partial = $false
  foreach ($b in $ordered) {
    if ((Get-Date) -gt $deadline) { $partial = $true; break }
    $m = Measure-DirFast $b $big $deadline
    if ($m.Partial) { $partial = $true }
    [void]$res.Add([pscustomobject]@{ Path = $b; Size = $m.Size; Partial = $m.Partial; Advice = (Get-SpaceAdvice $b) })
  }
  foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue)) {
    if ($f.Length -ge 256MB) { [void]$res.Add([pscustomobject]@{ Path = $f.FullName; Size = $f.Length; Partial = $false; Advice = (Get-SpaceAdvice $f.FullName) }) }
  }
  return [pscustomobject]@{
    Top = @($res | Sort-Object Size -Descending | Select-Object -First 20)
    Big = @($big | Sort-Object Size -Descending | Select-Object -First 15 | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Size = $_.Size; Advice = (Get-SpaceAdvice $_.Path) } })
    Partial = $partial; Seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds)
  }
}

# ---------------------------------------------------------------- сбор всего

function Invoke-Diagnostics {
  Head 'Диагностика (только чтение — ничего не меняется)'
  $steps = @(
    @('система', { $script:Sys = Get-SysInfo }),
    @('активация', { $script:Activation = Get-Activation }),
    @('диски', { $script:Disks = Get-DiskInfo; $script:Vols = Get-Volumes }),
    @('Windows 11', { if (-not $script:Sys.IsWin11) { $script:Win11 = Get-Win11Readiness $script:Sys $script:Disks } else { $script:Win11 = $null } }),
    @('батарея', { $script:Battery = Get-BatteryInfo }),
    @('загрузка', { $script:Boot = Get-BootInfo }),
    @('стабильность', { $script:Stab = Get-Stability }),
    @('процессы', { $script:Procs = Get-ProcessInfo }),
    @('электропитание', { $script:Power = Get-PowerInfo }),
    @('устройства', { $script:DevErr = Get-DeviceErrors }),
    @('обновления', { $script:Upd = Get-UpdateInfo; $script:Pending = Test-PendingReboot }),
    @('программы', { $script:Programs = Get-InstalledPrograms }),
    @('настройки Windows', { $script:Tweaks = Get-TweakState }),
    @('приложения Магазина', { $script:Apps = Get-StoreApps }),
    @('браузеры', { $script:Browsers = Get-BrowserInfo; $script:ForcedExt = Get-ForcedExtensions; $script:Shortcuts = Get-HijackedShortcuts }),
    @('загрузки', { $script:OldDl = Get-OldDownloads }),
    @('автозагрузка', { $script:Startup = Get-StartupItems; $script:Tasks = Get-ThirdPartyTasks; $script:Services = Get-ThirdPartyServices }),
    @('безопасность', { $script:Sec = Get-SecurityInfo; $script:Susp = Find-Suspicious $script:Startup $script:Tasks; $script:Pups = Find-Pups $script:Programs }),
    @('место на диске', { $script:Clean = Get-CleanTargets; Measure-CleanTargets $script:Clean }),
    @('что занимает место', { $script:Space = $null; $c = @($script:Vols | Where-Object { $_.Drive -eq $env:SystemDrive }) | Select-Object -First 1; if ($c -and ($c.FreePct -lt 20 -or $c.Free -lt 40GB)) { $script:Space = Get-SpaceUsage } })
  )
  foreach ($s in $steps) {
    Write-Host ('  - ' + $s[0] + ' ...') -ForegroundColor DarkGray
    try { & $s[1] } catch { Note-Error ('diag ' + $s[0]) $_.Exception.Message }
  }
  $script:Findings = Get-Findings
}

# ================================================================ v0.3: настройки Windows, приложения Магазина, удаление программ, браузеры, место

# ---------------------------------------------------------------- настройки Windows (data\tweaks.tsv)

# ключи реестра, которые разрешено менять настройкам из tweaks.tsv (сильнее любого списка)
$script:TweakKeyAllow = @(
  'Software\\Microsoft\\Windows\\CurrentVersion\\(ContentDeliveryManager|AdvertisingInfo|Explorer\\Advanced|SearchSettings|UserProfileEngagement|Privacy|GameDVR|Internet Settings)',
  'Software\\Policies\\Microsoft\\(Windows\\(Explorer|WindowsCopilot|DataCollection|System|WindowsAI|Windows Feeds|DeliveryOptimization)|Edge|Dsh|Windows Defender|Windows Defender\\Real-Time Protection)',
  'System\\GameConfigStore',
  'Software\\Microsoft\\Input\\TIPC',
  'SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power'
)
function Test-TweakKey([string]$path) {
  foreach ($k in $script:TweakKeyAllow) { if ($path -match ('(?i)^Registry::HKEY_(USERS\\[^\\]+|LOCAL_MACHINE)\\(' + $k + ')$')) { return $true } }
  return $false
}

function Get-TweakState {
  $rows = Read-Tsv 'tweaks.tsv'
  $build = [int]$script:Sys.Build
  $hku = "Registry::HKEY_USERS\$($script:User.Sid)"
  $groups = [ordered]@{}
  foreach ($r in $rows) {
    $min = 0; $max = 999999
    if ($r.minbuild) { $min = [int]$r.minbuild }
    if ($r.maxbuild) { $max = [int]$r.maxbuild }
    if ($build -lt $min -or $build -gt $max) { continue }
    if ($r.scope -eq 'user' -and -not $script:User.Sid) { continue }
    if ($r.scope -eq 'user') { $full = $hku + '\' + $r.path } else { $full = 'Registry::HKEY_LOCAL_MACHINE\' + $r.path }
    if (-not (Test-TweakKey $full)) { Note-Error 'tweaks' ('ключ вне белого списка: ' + $r.path); continue }
    $cur = Get-RegValue $full $r.name
    $done = $false
    if ($r.type -eq 'delete') { $done = ($null -eq $cur) }
    elseif ($null -eq $cur) { $done = ($r.mode -eq 'fix') }
    else { $done = ([string]$cur.Value -eq [string]$r.value) }
    if (-not $groups.Contains($r.id)) {
      $groups[$r.id] = [pscustomobject]@{ Id = $r.id; Level = $r.level; Section = $r.section; Title = $r.title; Note = $r.note; Keys = (New-Object System.Collections.ArrayList); Pending = 0 }
    }
    $g = $groups[$r.id]
    $curText = $null; if ($cur) { $curText = [string]$cur.Value }
    [void]$g.Keys.Add([pscustomobject]@{ Path = $full; Name = $r.name; Type = $r.type; Value = $r.value; Done = $done; Current = $curText })
    if (-not $done) { $g.Pending++ }
  }
  return ,@($groups.Values)
}

function Remove-RegJournaled([string]$path, [string]$name, [string]$batch, [string]$label) {
  if (-not (Test-RegWriteAllowed $path $name)) { throw "удаление в реестре вне белого списка: $path [$name]" }
  $old = Get-RegValue $path $name
  if (-not $old) { return }
  Add-JournalEntry ([ordered]@{ type = 'registry'; path = $path; name = $name; existed = $true; keyExisted = $true; kind = $old.Kind
                                old = (ConvertTo-JValue $old.Kind $old.Value); newKind = 'deleted'; batch = $batch; label = $label; time = (Get-Date).ToString('s') })
  Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction Stop
}

function Invoke-Tweak($g, [string]$batch, [string]$label) {
  foreach ($k in $g.Keys) {
    if ($k.Done) { continue }
    if ($k.Type -eq 'delete') { Remove-RegJournaled $k.Path $k.Name $batch $label; continue }
    $v = [string]$k.Value
    if ($k.Type -eq 'DWord') { $v = [int]$k.Value }
    Set-RegJournaled $k.Path $k.Name $k.Type $v $batch $label
  }
}

# ---------------------------------------------------------------- приложения из Магазина (data\apps.tsv)

function Get-CurrentSid { try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return $null } }

function Get-StoreApps {
  $res = New-Object System.Collections.ArrayList
  $pk = $null
  try {
    if ($script:User.Sid -and $script:User.Sid -ne (Get-CurrentSid)) { $pk = @(Get-AppxPackage -User $script:User.Sid -ErrorAction Stop) }
    else { $pk = @(Get-AppxPackage -ErrorAction Stop) }
  } catch { Note-Error 'Get-AppxPackage' $_.Exception.Message; return ,$res }
  foreach ($p in $pk) {
    if (-not $p -or $p.IsFramework -or $p.NonRemovable -or [string]$p.SignatureKind -eq 'System') { continue }
    [void]$res.Add([pscustomobject]@{ Name = $p.Name; FullName = $p.PackageFullName; Location = [string]$p.InstallLocation; Version = [string]$p.Version })
  }
  return ,$res
}

function Remove-StoreApp($a, [string]$storeId, [string]$batch, [string]$label) {
  if ($a.Name -match '(?i)^Microsoft\.(WindowsStore|DesktopAppInstaller|SecHealthUI|VCLibs|UI\.Xaml|NET\.|WindowsTerminal|Windows\.Photos|WindowsCalculator|WindowsCamera|Paint|WindowsNotepad|ScreenSketch|StorePurchaseApp)') { throw 'это приложение защищено' }
  Add-JournalEntry ([ordered]@{ type = 'appx'; name = $a.Name; fullName = $a.FullName; location = $a.Location; storeId = $storeId; userSid = $script:User.Sid
                                batch = $batch; label = $label; time = (Get-Date).ToString('s') })
  if ($script:User.Sid -and $script:User.Sid -ne (Get-CurrentSid)) { Remove-AppxPackage -Package $a.FullName -User $script:User.Sid -ErrorAction Stop }
  else { Remove-AppxPackage -Package $a.FullName -ErrorAction Stop }
}

function Restore-StoreApp($e) {
  $have = @()
  try {
    if ($e.userSid -and $e.userSid -ne (Get-CurrentSid)) { $have = @(Get-AppxPackage -Name $e.name -User $e.userSid -ErrorAction Stop) } else { $have = @(Get-AppxPackage -Name $e.name -ErrorAction Stop) }
  } catch {}
  if (@($have | Where-Object { $_ }).Count) { return }
  $m = $null; if ($e.location) { $m = Join-Path ([string]$e.location) 'AppxManifest.xml' }
  if ($m -and (Test-Path -LiteralPath $m)) {
    try { Add-AppxPackage -Register $m -DisableDevelopmentMode -ErrorAction Stop; return } catch { Note-Error 'appx register' $_.Exception.Message }
  }
  if ($e.storeId -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    & winget.exe install --id $e.storeId --source msstore --accept-package-agreements --accept-source-agreements --silent | Out-Host
    if ($LASTEXITCODE -eq 0) { return }
  }
  $hint = ''; if ($e.storeId) { $hint = ': Магазин -> ms-windows-store://pdp/?productid=' + $e.storeId }
  throw ('автоматически вернуть не вышло — установите из Магазина' + $hint)
}

# ---------------------------------------------------------------- удаление программ (НЕОБРАТИМО, только по слову клиента)

function Get-UninstallCandidates {
  $res = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($x in @($script:Pups)) {
    if (-not $x -or $x.Source -ne 'установлено') { continue }
    if ($x.Name -match '(?i)anydesk') { continue }
    if ($seen.ContainsKey($x.Name)) { continue }
    $p = @($script:Programs | Where-Object { $_.Name -eq $x.Name -and ($_.Uninstall -or $_.Quiet) }) | Select-Object -First 1
    if (-not $p) { continue }
    $seen[$x.Name] = 1
    $note = $x.Note
    if ($x.Kind -eq 'remote') { $note = 'Удалённый доступ — удалять, ТОЛЬКО если клиент его не ставил сам. ' + $note }
    [void]$res.Add([pscustomobject]@{ Program = $p; Kind = $x.Kind; Note = $note })
  }
  return ,$res
}

function Test-ProgramPresent($p) { return (Test-Path -LiteralPath $p.KeyPath) }

function Invoke-Uninstall($p) {
  $u = $p.Quiet
  if (-not $u) { $u = $p.Uninstall }
  if (-not $u) { throw 'нет команды удаления' }
  $m = [regex]::Match($u, '(?i)msiexec(\.exe)?\s+/[IX]\s*(\{[0-9A-F-]+\})')
  if ($m.Success) { $u = 'MsiExec.exe /X' + $m.Groups[2].Value + ' /passive /norestart' }
  Add-JournalEntry ([ordered]@{ type = 'uninstall'; name = $p.Name; version = $p.Version; command = $u; batch = 'u'; label = ('Удалена программа: ' + $p.Name + ' ' + $p.Version); time = (Get-Date).ToString('s') })
  Say ('    запускаю удаление: ' + $p.Name + ' (если откроется окно — пройти его до конца)') 'DarkGray'
  $pr = Start-Process -FilePath "$env:windir\System32\cmd.exe" -ArgumentList ('/s /c "' + $u + '"') -Wait -PassThru
  Start-Sleep -Seconds 3
  if ((Test-ProgramPresent $p) -and $script:Interactive) {
    $null = Ask '    Удаление ещё идёт? Дождитесь конца в его окне и нажмите Enter'
  }
  if (Test-ProgramPresent $p) { throw ('программа осталась (удаление отменено или не завершено, код ' + $pr.ExitCode + ')') }
}

# ---------------------------------------------------------------- старые большие файлы в «Загрузках» (только отчёт)

function Get-OldDownloads {
  $dir = Join-Path $script:User.Profile 'Downloads'
  $files = @(Get-FilesSafe $dir (90 * 24) '' | Where-Object { $_.Length -ge 50MB -and $_.Extension -match '(?i)^\.(exe|msi|iso|img|zip|rar|7z|tar|gz|mp4|mkv|avi|mov|dmg|apk|cab|msix|appx)$' })
  $sum = [long]0; foreach ($f in $files) { $sum += $f.Length }
  return [pscustomobject]@{
    Count = $files.Count; Size = $sum
    Top = @($files | Sort-Object Length -Descending | Select-Object -First 15 | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Size = $_.Length; Date = $_.LastWriteTime } })
  }
}

# ---------------------------------------------------------------- браузеры: расширения, поиск, домашняя страница, ярлыки (только отчёт)

function Read-JsonDict([string]$path) {
  try {
    $txt = [IO.File]::ReadAllText($path)
    try {
      Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
      $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
      $js.MaxJsonLength = [int]::MaxValue
      return $js.DeserializeObject($txt)
    } catch {
      return ($txt | ConvertFrom-Json -AsHashtable)
    }
  } catch { return $null }
}
function Get-JVal($o, [string]$path) {
  foreach ($k in ($path -split '\.')) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($k)) { $o = $o[$k] } else { return $null } } else { return $null }
  }
  return $o
}

$script:GoodSearch = '(?i)^(https?://)?([a-z0-9-]+\.)*(google\.[a-z.]+|bing\.com|duckduckgo\.com|yandex\.[a-z]+|ya\.ru|ecosia\.org|yahoo\.com|startpage\.com|search\.brave\.com|qwant\.com|sapo\.pt|msn\.com|microsoft\.com|live\.com|office\.com|youtube\.com|gmail\.com|mail\.ru)([/:?]|$)|^chrome://|^edge://|^about:|^\{google:baseURL\}'

function Get-ExtName([string]$dir, [string]$name) {
  if (-not $name -or $name -notmatch '^__MSG_(.+)__$') { return $name }
  $key = $Matches[1]
  $man = Read-JsonDict (Join-Path $dir 'manifest.json')
  $loc = Get-JVal $man 'default_locale'
  foreach ($l in @($loc, 'en', 'en_US', 'ru', 'pt_PT', 'pt_BR')) {
    if (-not $l) { continue }
    $msg = Read-JsonDict (Join-Path $dir "_locales\$l\messages.json")
    if ($msg) { foreach ($k in $msg.Keys) { if ($k -ieq $key) { $m = Get-JVal $msg[$k] 'message'; if ($m) { return $m } } } }
  }
  return $name
}

function Get-BrowserInfo {
  $res = New-Object System.Collections.ArrayList
  $L = Join-Path $script:User.Profile 'AppData\Local'
  $R = Join-Path $script:User.Profile 'AppData\Roaming'
  $chromes = @(
    @{ B = 'Chrome'; D = "$L\Google\Chrome\User Data" }, @{ B = 'Edge'; D = "$L\Microsoft\Edge\User Data" },
    @{ B = 'Brave'; D = "$L\BraveSoftware\Brave-Browser\User Data" }, @{ B = 'Яндекс'; D = "$L\Yandex\YandexBrowser\User Data" },
    @{ B = 'Opera'; D = "$R\Opera Software\Opera Stable" }, @{ B = 'Vivaldi'; D = "$L\Vivaldi\User Data" }
  )
  $locNames = @{ 1 = 'магазин'; 2 = 'другая программа'; 3 = 'другая программа (реестр)'; 4 = 'ВРУЧНУЮ (распакованное)'; 6 = 'другая программа'; 7 = 'политика'; 8 = 'командная строка'; 9 = 'политика' }
  foreach ($c in $chromes) {
    if (-not (Test-Path -LiteralPath $c.D)) { continue }
    $profiles = @(Get-ChildItem -LiteralPath $c.D -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    if ($c.B -eq 'Opera') { $profiles = @(Get-Item -LiteralPath $c.D) }
    foreach ($pr in $profiles) {
      $pref = Read-JsonDict (Join-Path $pr.FullName 'Preferences')
      $sec = Read-JsonDict (Join-Path $pr.FullName 'Secure Preferences')
      $o = [ordered]@{ Browser = $c.B; Profile = $pr.Name; Search = $null; Home = @(); Extensions = (New-Object System.Collections.ArrayList) }
      foreach ($src in @($sec, $pref)) {
        if (-not $o.Search) { $o.Search = Get-JVal $src 'default_search_provider_data.template_url_data.url' }
        $hp = Get-JVal $src 'homepage'; if ($hp -and (Get-JVal $src 'homepage_is_newtabpage') -ne $true) { $o.Home += [string]$hp }
        if ((Get-JVal $src 'session.restore_on_startup') -eq 4) { foreach ($u in @(Get-JVal $src 'session.startup_urls')) { if ($u) { $o.Home += [string]$u } } }
      }
      $o.Home = @($o.Home | Select-Object -Unique)
      $settings = @{}
      foreach ($src in @($pref, $sec)) { $s = Get-JVal $src 'extensions.settings'; if ($s -is [System.Collections.IDictionary]) { foreach ($k in $s.Keys) { $settings[$k] = $s[$k] } } }
      foreach ($id in $settings.Keys) {
        $st = $settings[$id]
        $loc = [int](Get-JVal $st 'location')
        if ($loc -eq 5 -or $loc -eq 10) { continue }
        $extDir = Join-Path $pr.FullName "Extensions\$id"
        $ver = @(Get-ChildItem -LiteralPath $extDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) | Select-Object -First 1
        $name = $null
        if ($ver) { $man = Read-JsonDict (Join-Path $ver.FullName 'manifest.json'); $name = Get-ExtName $ver.FullName ([string](Get-JVal $man 'name')) }
        if (-not $name) { $name = [string](Get-JVal $st 'manifest.name') }
        if (-not $name -and $loc -ne 4) { continue }
        $dr = Get-JVal $st 'disable_reasons'
        $enabled = (-not $dr -or ($dr -is [System.Collections.ICollection] -and $dr.Count -eq 0) -or $dr -eq 0)
        if ((Get-JVal $st 'state') -eq 0) { $enabled = $false }
        $from = $locNames[$loc]; if (-not $from) { $from = "код $loc" }
        [void]$o.Extensions.Add([pscustomobject]@{ Id = $id; Name = $name; Location = $loc; From = $from; Enabled = $enabled; Path = $(if ($loc -eq 4) { [string](Get-JVal $st 'path') } else { '' }) })
      }
      [void]$res.Add([pscustomobject]$o)
    }
  }
  foreach ($fp in @(Get-ChildItem -LiteralPath "$R\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue)) {
    $j = Read-JsonDict (Join-Path $fp.FullName 'extensions.json')
    $o = [ordered]@{ Browser = 'Firefox'; Profile = $fp.Name; Search = $null; Home = @(); Extensions = (New-Object System.Collections.ArrayList) }
    foreach ($a in @(Get-JVal $j 'addons')) {
      if (-not $a -or (Get-JVal $a 'type') -ne 'extension') { continue }
      $loc = [string](Get-JVal $a 'location')
      if ($loc -match '^app-(builtin|system-defaults|system-addons)$') { continue }
      [void]$o.Extensions.Add([pscustomobject]@{ Id = [string](Get-JVal $a 'id'); Name = [string](Get-JVal $a 'defaultLocale.name'); Location = $loc
                                                 From = $(if ($loc -eq 'app-profile') { 'магазин/вручную' } else { 'другая программа (' + $loc + ')' }); Enabled = [bool](Get-JVal $a 'active'); Path = '' })
    }
    [void]$res.Add([pscustomobject]$o)
  }
  return ,$res
}

function Get-ForcedExtensions {
  $res = @()
  foreach ($k in @('Google\Chrome', 'Microsoft\Edge', 'BraveSoftware\Brave', 'YandexBrowser')) {
    foreach ($h in @('Registry::HKEY_LOCAL_MACHINE', "Registry::HKEY_USERS\$($script:User.Sid)")) {
      $p = "$h\SOFTWARE\Policies\$k\ExtensionInstallForcelist"
      try { $key = Get-Item -LiteralPath $p -ErrorAction Stop; foreach ($n in $key.GetValueNames()) { $res += ('{0}: {1}' -f $k, $key.GetValue($n)) } } catch {}
    }
  }
  return ,$res
}

function Get-HijackedShortcuts {
  $res = @()
  $dirs = @((Join-Path $script:User.Profile 'Desktop'), "$env:PUBLIC\Desktop",
            (Join-Path $script:User.Profile 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
            (Join-Path $script:User.Profile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'), "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")
  try { $sh = New-Object -ComObject WScript.Shell } catch { return ,$res }
  foreach ($d in $dirs) {
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
      try {
        $l = $sh.CreateShortcut($f.FullName)
        if ($l.TargetPath -match '(?i)\\(chrome|msedge|firefox|brave|opera|browser|iexplore|vivaldi)\.exe$' -and $l.Arguments -match '(?i)https?://|www\.|\.html?\b') {
          $res += [pscustomobject]@{ Shortcut = $f.FullName; Target = $l.TargetPath; Args = $l.Arguments }
        }
      } catch {}
    }
  }
  return ,$res
}

# ---------------------------------------------------------------- очистка через «Очистку диска» Windows (cleanmgr)

function Invoke-CleanMgr([string[]]$handlers) {
  $base = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
  $flag = 'StateFlags0777'
  $set = @()
  try {
    # временная служебная пометка «что чистить» для cleanmgr /sagerun — снимается сразу после
    foreach ($h in $handlers) { $k = "$base\$h"; if (Test-Path -LiteralPath $k) { Set-RegValueRaw $k $flag 'DWord' 2; $set += $k } }
    if (-not $set.Count) { throw 'в этой Windows нет нужных разделов «Очистки диска»' }
    Say '    «Очистка диска» Windows работает (может занять 5–20 минут)…' 'DarkGray'
    $null = Start-Process -FilePath "$env:windir\System32\cleanmgr.exe" -ArgumentList '/sagerun:777' -Wait -PassThru
  } finally {
    foreach ($k in $set) { Remove-ItemProperty -LiteralPath $k -Name $flag -Force -ErrorAction SilentlyContinue }
  }
}

# ================================================================ ВЫВОДЫ И ОТЧЁТ

function Add-F($list, [string]$sev, [string]$text, [string]$advice = '') {
  [void]$list.Add([pscustomobject]@{ Sev = $sev; Text = $text; Advice = $advice })
}

function Get-Findings {
  $f = New-Object System.Collections.ArrayList
  $s = $script:Sys
  if ($s) {
    if (-not $s.IsWin11 -and $s.Build -gt 0 -and $s.ProductType -eq 1) {
      $adv = 'Перейти на Windows 11'
      if ($script:Win11) { $adv = 'Windows 11: ' + $script:Win11.Verdict }
      Add-F $f 'red' 'Windows 10: обновления безопасности больше не выходят (для домашних ESU закончился 13.10.2026)' $adv
    }
    if ($s.RamGB -and $s.RamGB -lt 7.5 -and $s.IsWin11) { Add-F $f 'yellow' ("Мало памяти для Windows 11: {0} ГБ" -f $s.RamGB) 'Совет клиенту: добавить ОЗУ до 8–16 ГБ, если ноутбук позволяет' }
    if ($s.RamUsedPct -ge 85) { Add-F $f 'yellow' ("Память занята на {0}% прямо сейчас" -f $s.RamUsedPct) 'Смотри «Больше всего памяти» и автозагрузку' }
    if ($s.UptimeDays -ge 14) { Add-F $f 'info' ("ПК не перезагружали {0} дн." -f $s.UptimeDays) 'Перезагрузка в конце работы' }
  }
  if ($script:Activation -eq 'НЕ активирована') { Add-F $f 'yellow' 'Windows не активирована' 'Только сообщить клиенту (активаторы не используем)' }
  if (@($script:Pending).Count) { Add-F $f 'yellow' ('Windows ждёт перезагрузки: ' + (@($script:Pending) -join ', ')) 'Перезагрузить до/после работы' }
  $u = $script:Upd
  if ($u) {
    $last = $u.LastSuccess; if (-not $last) { $last = $u.LastHotfix }
    if ($last -and $last -lt (Get-Date).AddDays(-45)) { Add-F $f 'yellow' ("Обновления давно не ставились (последнее {0:dd.MM.yyyy})" -f $last) 'Запустить Центр обновлений' }
    if ($u.Failed30d -ge 3) {
      $adv = 'Прислать отчёт Claude'
      $cv = @($script:Vols | Where-Object { $_.Drive -eq $env:SystemDrive }) | Select-Object -First 1
      if ($cv -and $cv.Free -lt 15GB) { $adv = 'Скорее всего из-за нехватки места на ' + $env:SystemDrive + ' — сначала освободить место, потом перезагрузить и обновить' }
      Add-F $f 'yellow' ("Ошибки установки обновлений за месяц: {0}" -f $u.Failed30d) $adv
    }
  }
  foreach ($d in @($script:Disks)) {
    if ($d.Health -and $d.Health -ne 'Healthy') { Add-F $f 'red' ("Диск «{0}»: состояние {1}" -f $d.Name, $d.Health) 'СРОЧНО сделать копию данных, диск под замену' }
    if ($d.Wear -ge 80) { Add-F $f 'red' ("Диск «{0}» изношен на {1}%" -f $d.Name, $d.Wear) 'Копия данных, планировать замену' }
    elseif ($d.Wear -ge 50) { Add-F $f 'yellow' ("Диск «{0}» изношен на {1}%" -f $d.Name, $d.Wear) '' }
    if ($d.ReadErrors -gt 0) { Add-F $f 'red' ("Диск «{0}»: неисправимые ошибки чтения ({1})" -f $d.Name, $d.ReadErrors) 'Копия данных, диск под замену' }
    if ($d.TempC -ge 65) { Add-F $f 'yellow' ("Диск «{0}» горячий: {1} °C" -f $d.Name, $d.TempC) 'Проверить охлаждение' }
    if ($d.System -and $d.Type -eq 'HDD') { Add-F $f 'yellow' 'Windows стоит на обычном жёстком диске (HDD) — главная причина медленной работы' 'Совет клиенту: заменить на SSD (самый заметный прирост скорости)' }
  }
  foreach ($v in @($script:Vols)) {
    if ($v.Drive -eq $env:SystemDrive) {
      if ($v.Free -lt 10GB -or $v.FreePct -lt 8) { Add-F $f 'red' ("На диске {0} мало места: {1} свободно ({2}%)" -f $v.Drive, (Fmt-GB $v.Free), $v.FreePct) 'Очистка в пункте 2; большие папки — с клиентом' }
      elseif ($v.Free -lt 25GB -or $v.FreePct -lt 15) { Add-F $f 'yellow' ("На диске {0} свободно {1} ({2}%)" -f $v.Drive, (Fmt-GB $v.Free), $v.FreePct) 'Очистка в пункте 2' }
    } elseif ($v.FreePct -lt 5 -and $v.Label -notmatch '(?i)google|drive|onedrive|dropbox') {
      Add-F $f 'yellow' ("Диск {0} ({1}) почти заполнен: свободно {2} ({3}%)" -f $v.Drive, $v.Label, (Fmt-GB $v.Free), $v.FreePct) 'Разобрать с клиентом'
    }
  }
  if ($script:Space) {
    $top = @($script:Space.Top | Where-Object { $_.Size -ge 5GB -and $_.Advice -and $_.Advice -notmatch 'не трогать|^система' } | Select-Object -First 3)
    if ($top.Count) { Add-F $f 'info' ('Больше всего места на ' + $env:SystemDrive + ' — ' + (($top | ForEach-Object { (Split-Path -Leaf $_.Path) + ' ' + (Fmt-GB $_.Size) }) -join ', ')) 'Список «Что занимает место» — ниже и в отчёте' }
  }
  foreach ($b in @($script:Battery)) { if ($b.WearPct -ge 40) { Add-F $f 'yellow' ("Батарея изношена на {0}% (циклов: {1})" -f $b.WearPct, $b.Cycles) 'Совет клиенту: замена батареи' } }
  $bo = $script:Boot
  if ($bo -and $bo.LastBootMs -gt 60000) {
    $adv = 'Смотри «Что тормозит загрузку» и автозагрузку'
    if (@($script:Pending).Count -or $bo.LastBootMs -gt 300000) { $adv += '; если перед этим ставились обновления — замерить ещё раз после обычной перезагрузки' }
    Add-F $f 'yellow' ("Долгая загрузка: {0:N0} с" -f ($bo.LastBootMs / 1000)) $adv
  }
  $en = @($script:Startup | Where-Object { $_.Enabled }).Count
  if ($en -gt 10) { Add-F $f 'yellow' ("В автозагрузке {0} программ" -f $en) 'Пункт 2 — отключить лишнее' }
  $st = $script:Stab
  if ($st) {
    if (@($st.BugChecks).Count -gt 0 -or $st.KernelPowerBugcheck -gt 0) { Add-F $f 'red' ("Синие экраны за 30 дней: {0}" -f [math]::Max(@($st.BugChecks).Count, $st.KernelPowerBugcheck)) 'Прислать отчёт Claude (дампы перечислены в отчёте)' }
    elseif ($st.UnexpectedShutdowns -gt 2) { Add-F $f 'yellow' ("Внезапные выключения за 30 дней: {0}" -f $st.UnexpectedShutdowns) 'Питание/батарея/перегрев или выключение кнопкой — спросить клиента' }
    if ($st.Whea -gt 0) { Add-F $f 'red' ("Аппаратные ошибки (WHEA) за 30 дней: {0}" -f $st.Whea) 'Возможна проблема с процессором/памятью — прислать отчёт Claude' }
    if ($st.DiskErrors -gt 0) { Add-F $f 'red' ("Ошибки диска в журнале за 30 дней: {0}" -f $st.DiskErrors) 'Сделать копию данных, прислать отчёт Claude' }
    foreach ($c in @($st.AppCrashes)) { if ($c.Count -ge 3) { Add-F $f 'info' ("Часто падает: {0} ({1} раз за 30 дней)" -f $c.App, $c.Count) '' } }
  }
  foreach ($d in @($script:DevErr)) {
    if ($d.Code -eq 22) { continue }
    Add-F $f 'yellow' ("Устройство с ошибкой: {0} (код {1})" -f $d.Name, $d.Code) 'Драйвер — с сайта производителя ноутбука/устройства'
  }
  $p = $script:Power
  if ($p -and $p.PlanGuid -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') { Add-F $f 'yellow' ('Включена схема питания «Экономия энергии»' + $(if ($p.HasBattery) { '' } else { ' на настольном ПК' })) 'Пункт 2 — вернуть «Сбалансированную»' }
  $sec = $script:Sec
  if ($sec) {
    $otherAv = @($sec.AvProducts | Where-Object { $_.Enabled -and $_.Name -notmatch 'Windows Defender|Защитник|Microsoft Defender' })
    $defOn = ($sec.Defender -and $sec.Defender.RealTime)
    if (-not $defOn -and $otherAv.Count -eq 0 -and $script:Sys.ProductType -eq 1) { Add-F $f 'red' 'Антивирусная защита ВЫКЛЮЧЕНА (Защитник выключен, другого антивируса нет)' 'Включить Защитник (Безопасность Windows)' }
    if ($otherAv.Count -gt 1) { Add-F $f 'yellow' ('Работают сразу несколько антивирусов: ' + (($otherAv | ForEach-Object { $_.Name }) -join ', ')) 'Оставить один (с клиентом)' }
    if ($defOn -and $sec.Defender.SignaturesAgeDays -gt 7) { Add-F $f 'yellow' ("Базы Защитника старые: {0} дн." -f $sec.Defender.SignaturesAgeDays) 'Обновить (Центр обновлений)' }
    if (@($sec.Threats).Count -gt 0) { Add-F $f 'yellow' ("Защитник находил угрозы за 90 дней: {0}" -f @($sec.Threats).Count) 'Список — в отчёте; прислать Claude' }
    if ($sec.BitLocker -eq 'ВКЛЮЧЁН') { Add-F $f 'info' 'Диск зашифрован (BitLocker/шифрование устройства)' 'Убедиться, что у клиента есть ключ восстановления (account.microsoft.com/devices/recoverykey)' }
    $hostsOwn = @($sec.Hosts | Where-Object { $_ -notmatch '(?i)gen-webserver\.internal|gen digital helper' })
    if ($hostsOwn.Count -gt 0) {
      $lic = @($hostsOwn | Where-Object { $_ -match '(?i)licen|activat|piriform|ccleaner|corel|adobe|autodesk|jetbrains|genuine|wondershare|avast|avg\.com|kaspersky|eset' })
      if ($lic.Count) { Add-F $f 'yellow' ("Файл hosts блокирует проверку лицензий/обновлений программ (строк: {0})" -f $lic.Count) 'Обычно так делают при установке взломанных версий — сказать клиенту (такие сборки — частый источник вирусов); hosts сами не правим' }
      if ($lic.Count -lt $hostsOwn.Count) { Add-F $f 'yellow' ("Файл hosts изменён (строк: {0})" -f ($hostsOwn.Count - $lic.Count)) 'Строки — в отчёте; прислать Claude, если непонятно' }
    }
    if ($sec.Proxy -and ($sec.Proxy.Enabled -eq 1 -or $sec.Proxy.Pac)) { Add-F $f 'yellow' ('Включён прокси: ' + ((@($sec.Proxy.Server, $sec.Proxy.Pac) | Where-Object { $_ }) -join ' ')) 'Спросить клиента; если не знает — подозрительно' }
    if (@($sec.Managed).Count -gt 0) { Add-F $f 'yellow' ('Рабочий (управляемый) ПК: ' + (@($sec.Managed) -join ', ')) 'Только диагностика, изменения не делаем' }
    if ($sec.MdmNote) { Add-F $f 'info' $sec.MdmNote 'Если ПК рабочий — ничего не менять' }
  }
  $managed = ($script:Sec -and @($script:Sec.Managed).Count -gt 0)
  foreach ($b in @($script:Browsers)) {
    if (-not $b) { continue }
    foreach ($x in @($b.Extensions)) {
      if (-not $x -or -not $x.Enabled) { continue }
      $loc = -1; if ([string]$x.Location -match '^\d+$') { $loc = [int]$x.Location }
      if ($loc -eq 4 -or $loc -eq 8) { Add-F $f 'red' ("ВНИМАНИЕ: расширение {0} «{1}» установлено вручную, не из магазина" -f $b.Browser, $x.Name) 'Спросить клиента; если не знает — удалить расширение в браузере' }
      elseif (@(2, 3, 6) -contains $loc) { Add-F $f 'yellow' ("Расширение {0} «{1}» поставлено другой программой" -f $b.Browser, $x.Name) 'Спросить клиента, пользуется ли' }
      elseif (@(7, 9) -contains $loc -and -not $managed) { Add-F $f 'red' ("ВНИМАНИЕ: расширение {0} «{1}» поставлено принудительно (политикой) на домашнем ПК" -f $b.Browser, $x.Name) 'Частый приём рекламных вирусов — прислать отчёт Claude' }
      elseif ($b.Browser -eq 'Firefox' -and [string]$x.Location -ne 'app-profile') { Add-F $f 'yellow' ("Расширение Firefox «{0}» поставлено другой программой" -f $x.Name) 'Спросить клиента' }
    }
    if ($b.Search -and [string]$b.Search -notmatch $script:GoodSearch) { Add-F $f 'yellow' ("{0}: поиск по умолчанию — {1}" -f $b.Browser, $b.Search) 'Если клиент не выбирал — вернуть Google/Bing в настройках браузера' }
    foreach ($h in @($b.Home)) { if ($h -and [string]$h -notmatch $script:GoodSearch) { Add-F $f 'info' ("{0}: стартовая страница — {1}" -f $b.Browser, $h) 'Проверить с клиентом' } }
  }
  if (@($script:ForcedExt).Count -and -not $managed) { Add-F $f 'red' ('ВНИМАНИЕ: браузеру принудительно ставятся расширения (политика): ' + (@($script:ForcedExt) -join '; ')) 'На домашнем ПК так делают рекламные вирусы — прислать отчёт Claude' }
  foreach ($x in @($script:Shortcuts)) { if ($x) { Add-F $f 'red' ("ВНИМАНИЕ: ярлык браузера открывает сайт: {0} -> {1}" -f (Split-Path -Leaf $x.Shortcut), $x.Args) 'Подмена ярлыка — пересоздать ярлык, прислать отчёт Claude' } }
  if ($script:OldDl -and $script:OldDl.Size -ge 2GB) { Add-F $f 'info' ("В «Загрузках» старые установщики/архивы/видео: {0} шт., {1}" -f $script:OldDl.Count, (Fmt-GB $script:OldDl.Size)) 'Список в отчёте — разобрать с клиентом (файлы пользователя набор не удаляет)' }
  $tw = @($script:Tweaks | Where-Object { $_ -and $_.Pending -gt 0 -and $_.Section -ne 'security' -and $_.Level -eq 'auto' })
  if ($tw.Count) { Add-F $f 'info' ("Реклама и «советы» Windows включены (пунктов: {0})" -f $tw.Count) 'Пункт 2 выключит (обратимо)' }
  if (@($script:Tweaks | Where-Object { $_ -and $_.Id -eq 'def_policy' -and $_.Pending -gt 0 }).Count -and -not $managed) { Add-F $f 'red' 'Защитник Windows запрещён политикой (так делают «оптимизаторы» и вирусы)' 'Пункт 2 снимет запрет (обратимо)' }
  foreach ($x in @($script:Susp)) { Add-F $f 'red' ("ВНИМАНИЕ: {0} — {1}" -f $x.What, $x.Why) ('Команда: ' + $x.Command) }
  foreach ($x in @($script:Pups)) {
    if ($x.Kind -eq 'remote') { Add-F $f 'yellow' ("Удалённый доступ: {0} ({1})" -f $x.Name, $x.Source) $x.Note }
    elseif ($x.Kind -eq 'trial') { Add-F $f 'yellow' ("Пробная/предустановленная программа: {0}" -f $x.Name) $x.Note }
    else { Add-F $f 'yellow' ("Лишняя программа: {0}" -f $x.Name) $x.Note }
  }
  return ,$f
}

function Show-Findings($f) {
  Head 'Что найдено'
  $order = @{ red = 0; yellow = 1; info = 2 }
  $sorted = @($f | Sort-Object { $order[$_.Sev] })
  if ($sorted.Count -eq 0) { Say '  Серьёзных проблем не найдено.' 'Green' }
  foreach ($x in $sorted) {
    $c = 'Gray'; $m = '  · '
    if ($x.Sev -eq 'red') { $c = 'Red'; $m = '  ! ' } elseif ($x.Sev -eq 'yellow') { $c = 'Yellow'; $m = '  ~ ' }
    Say ($m + $x.Text) $c
    if ($x.Advice) { Say ('      -> ' + $x.Advice) 'DarkGray' }
  }
}

function Show-Summary {
  $s = $script:Sys
  Head 'Компьютер'
  Say ("  {0} {1}" -f $s.Manufacturer, $s.Model)
  if ($script:User.Source -eq 'explorer') { Say ('  Рабочий стол открыт у другой учётки: ' + $script:User.Name + ' (права админа — от другой). Настройки автозагрузки берутся для неё.') 'Yellow' }
  Say ("  {0} {1} (сборка {2}.{3}), {4}" -f $s.Caption, $s.DisplayVersion, $s.Build, $s.UBR, $script:Activation)
  Say ("  Процессор: {0} ({1} ядер / {2} потоков)" -f $s.Cpu, $s.Cores, $s.Threads)
  Say ("  Память: {0} ГБ, занято {1}%;  работает без перезагрузки: {2} дн." -f $s.RamGB, $s.RamUsedPct, $s.UptimeDays)
  foreach ($d in @($script:Disks)) {
    if (-not $d) { continue }
    $extra = @(); if ($null -ne $d.Wear) { $extra += "износ $($d.Wear)%" }; if ($d.TempC) { $extra += "$($d.TempC) °C" }; if ($d.PowerOnHours) { $extra += "$($d.PowerOnHours) ч работы" }
    Say ("  Диск: {0} — {1} {2}, {3}, {4}{5}" -f $d.Name, $d.Type, $d.Bus, (Fmt-GB $d.Size), $d.Health, $(if ($extra.Count) { ' (' + ($extra -join ', ') + ')' } else { '' }))
  }
  foreach ($v in @($script:Vols)) { if (-not $v) { continue }; Say ("  {0} свободно {1} из {2} ({3}%)" -f $v.Drive, (Fmt-GB $v.Free), (Fmt-GB $v.Size), $v.FreePct) }
  foreach ($b in @($script:Battery)) { if (-not $b) { continue }; Say ("  Батарея: износ {0}%, циклов {1}" -f $b.WearPct, $b.Cycles) }
  if ($script:Boot.LastBootMs) { Say ("  Последняя загрузка: {0:N0} с" -f ($script:Boot.LastBootMs / 1000)) }
  if ($script:Procs.CpuTotal -ne $null) { Say ("  Процессор загружен сейчас: {0}%" -f $script:Procs.CpuTotal) }
  if ($script:Win11) { Say ('  Windows 11: ' + $script:Win11.Verdict) }
  Show-Compare
}

function Show-Compare {
  $h = Get-MetricsHistory
  $before = @($h | Where-Object { $_.Label -eq 'before-opt' }) | Select-Object -Last 1
  if (-not $before) { return }
  $now = Get-Metrics 'now'
  Head ('Было (до чистки {0}) / сейчас' -f ([datetime]$before.Time).ToString('dd.MM HH:mm'))
  $bootNote = ''
  if ($now.BootEventTime -and $before.BootEventTime -and $now.BootEventTime -eq $before.BootEventTime) { $bootNote = '  (новая загрузка ещё не записана — подождите 2–3 мин после входа и запустите снова)' }
  Say ("  Загрузка Windows:   {0,8} -> {1} с{2}" -f $(if ($before.BootMs) { '{0:N0}' -f ($before.BootMs / 1000) } else { '?' }), $(if ($now.BootMs) { '{0:N0}' -f ($now.BootMs / 1000) } else { '?' }), $bootNote)
  Say ("  Память занята:      {0,8} -> {1} %" -f $before.RamUsedPct, $now.RamUsedPct)
  Say ("  Процессов:          {0,8} -> {1}" -f $before.Processes, $now.Processes)
  Say ("  В автозагрузке:     {0,8} -> {1}" -f $before.StartupEnabled, $now.StartupEnabled)
  Say ("  Свободно на {0}       {1,8} -> {2} ГБ" -f $env:SystemDrive, $before.FreeGB, $now.FreeGB)
}

function Show-Space {
  if (-not $script:Space) { return }
  Head ('Что занимает место на ' + $env:SystemDrive)
  foreach ($x in @($script:Space.Top | Select-Object -First 10)) {
    Say ("  {0,10}  {1}" -f (Fmt-Size $x.Size), $x.Path)
    if ($x.Advice) { Say ('              -> ' + $x.Advice) 'DarkGray' }
  }
  if ($script:Space.Partial) { Say '  (подсчёт остановлен по времени — цифры неполные)' 'DarkGray' }
}

function Protect-Text([string]$t) {
  if (-not $t) { return $t }
  $names = @($script:User.ShortName, $env:USERNAME) | Where-Object { $_ -and $_.Length -ge 3 } | Select-Object -Unique
  foreach ($n in $names) {
    $t = [regex]::Replace($t, ('(?i)(\\\\?Users\\\\?)' + [regex]::Escape($n) + '(?=\\|"|$)'), '${1}<user>')
    $t = [regex]::Replace($t, ('(?i)\b' + [regex]::Escape($n) + '\b'), '<user>')
  }
  if ($env:COMPUTERNAME -and $env:COMPUTERNAME.Length -ge 3) { $t = [regex]::Replace($t, ('(?i)\b' + [regex]::Escape($env:COMPUTERNAME) + '\b'), '<pc>') }
  return $t
}

function New-SessionDir([string]$tag) {
  $base = $ReportDir
  if (-not $base) { $base = Join-Path $script:Root 'reports' }
  $model = ''
  if ($script:Sys) { $model = ('{0}_{1}' -f $script:Sys.Manufacturer, $script:Sys.Model) }
  $model = ($model -replace '[^\w\-]+', '_').Trim('_')
  if ($model.Length -gt 40) { $model = $model.Substring(0, 40) }
  $d = Join-Path $base ('{0}_{1}_{2}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm'), $tag, $model)
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  return $d
}

function Write-TextFile([string]$path, [string]$text) { [IO.File]::WriteAllText($path, (Protect-Text $text), $script:Utf8Bom) }

function Save-DiagReport([string]$dir) {
  $data = [ordered]@{
    kit = "win-kit $script:Version"; created = (Get-Date).ToString('s'); admin = (Test-Admin); targetUserSource = $script:User.Source
    system = $script:Sys; activation = $script:Activation; win11 = $script:Win11; disks = $script:Disks; volumes = $script:Vols; battery = $script:Battery
    boot = $script:Boot; stability = $script:Stab; processes = $script:Procs; power = $script:Power; deviceErrors = $script:DevErr
    updates = $script:Upd; pendingReboot = $script:Pending; security = $script:Sec; suspicious = $script:Susp; pups = $script:Pups
    startup = $script:Startup; tasks = $script:Tasks; services = $script:Services; clean = $script:Clean; programs = $script:Programs
    tweaks = $script:Tweaks; storeApps = $script:Apps; browsers = $script:Browsers; forcedExtensions = $script:ForcedExt; hijackedShortcuts = $script:Shortcuts; oldDownloads = $script:OldDl
    findings = $script:Findings; metricsHistory = (Get-MetricsHistory)
  }
  Write-TextFile (Join-Path $dir 'diag.json') (ConvertTo-Json -InputObject $data -Depth 6)

  $sb = New-Object System.Text.StringBuilder
  $L = { param($x) [void]$sb.AppendLine([string]$x) }
  & $L ("win-kit {0} — отчёт {1}" -f $script:Version, (Get-Date -Format 'dd.MM.yyyy HH:mm'))
  & $L ''
  $start = $script:Log.Count
  foreach ($line in @($script:ReportLines)) { & $L $line }
  & $L ''
  & $L '==== Больше всего памяти ===='
  foreach ($p in @($script:Procs.TopMem)) { & $L ("  {0,-32} {1,6} МБ  ({2} шт.)" -f $p.Name, $p.MemMB, $p.Count) }
  & $L '==== Больше всего процессора (за 2 с) ===='
  foreach ($p in @($script:Procs.TopCpu)) { & $L ("  {0,-32} {1,5} %" -f $p.Name, $p.CpuPct) }
  & $L '==== Что тормозит загрузку (60 дней, по журналу Windows) ===='
  foreach ($x in @($script:Boot.Degraders)) { & $L ("  {0,-40} +{1:N1} с" -f $x.Name, ($x.DelayMs / 1000)) }
  & $L '==== Автозагрузка ===='
  foreach ($x in @($script:Startup)) { & $L ("  [{0}] {1} | {2} | {3} | {4}" -f $(if ($x.Enabled) { 'вкл' } else { 'выкл' }), $x.Name, $x.Where, $x.Publisher, $x.Command) }
  & $L '==== Задачи планировщика (не Microsoft) ===='
  foreach ($x in @($script:Tasks)) { & $L ("  [{0}] {1}{2} | {3} | {4}" -f $(if ($x.Enabled) { 'вкл' } else { 'выкл' }), $x.Path, $x.Name, $x.Triggers, $x.Command) }
  & $L '==== Службы не из Windows ===='
  foreach ($x in @($script:Services | Sort-Object StartMode, Name)) { & $L ("  {0,-8} {1,-8} {2} ({3}) | {4}" -f $x.StartMode, $x.State, $x.Name, $x.Display, $x.Publisher) }
  & $L '==== Настройки Windows (реклама, советы, лишнее) ===='
  foreach ($g in @($script:Tweaks)) { if ($g) { & $L ("  [{0}] {1} ({2})" -f $(if ($g.Pending) { 'включено' } else { 'уже выкл' }), $g.Title, $g.Level) } }
  & $L '==== Приложения из Магазина (можно удалить) ===='
  foreach ($a in @($script:Apps | Sort-Object Name -Unique)) { if ($a) { & $L ("  {0} {1}" -f $a.Name, $a.Version) } }
  & $L '==== Браузеры ===='
  foreach ($b in @($script:Browsers)) {
    if (-not $b) { continue }
    & $L ("  {0} / {1}: поиск {2}; стартовая {3}" -f $b.Browser, $b.Profile, $(if ($b.Search) { $b.Search } else { 'по умолчанию' }), $(if (@($b.Home).Count) { @($b.Home) -join ', ' } else { '—' }))
    foreach ($x in @($b.Extensions)) { if ($x) { & $L ("     [{0}] {1} ({2}) {3}" -f $(if ($x.Enabled) { 'вкл' } else { 'выкл' }), $x.Name, $x.From, $x.Id) } }
  }
  foreach ($x in @($script:ForcedExt)) { & $L ('  ПОЛИТИКА принудительной установки: ' + $x) }
  foreach ($x in @($script:Shortcuts)) { if ($x) { & $L ('  ПОДМЕНЁННЫЙ ЯРЛЫК: ' + $x.Shortcut + ' -> ' + $x.Args) } }
  if ($script:OldDl -and $script:OldDl.Count) {
    & $L ("==== Старые большие файлы в «Загрузках» (старше 90 дней): {0} шт., {1} ====" -f $script:OldDl.Count, (Fmt-Size $script:OldDl.Size))
    foreach ($x in @($script:OldDl.Top)) { & $L ("  {0,10}  {1:dd.MM.yyyy}  {2}" -f (Fmt-Size $x.Size), $x.Date, $x.Name) }
  }
  if ($script:Space) {
    & $L ("==== Что занимает место на {0} (за {1} с{2}) ====" -f $env:SystemDrive, $script:Space.Seconds, $(if ($script:Space.Partial) { ', не до конца — не хватило времени' } else { '' }))
    foreach ($x in @($script:Space.Top)) { & $L ("  {0,10}  {1}{2}" -f (Fmt-Size $x.Size), $x.Path, $(if ($x.Advice) { '  — ' + $x.Advice } else { '' })) }
    & $L '  Самые большие файлы (от 1 ГБ):'
    foreach ($x in @($script:Space.Big)) { & $L ("  {0,10}  {1}{2}" -f (Fmt-Size $x.Size), $x.Path, $(if ($x.Advice) { '  — ' + $x.Advice } else { '' })) }
  }
  & $L '==== Место, которое можно освободить ===='
  foreach ($x in @($script:Clean)) { & $L ("  {0,-10} {1}" -f (Fmt-Size $x.Size), $x.Title) }
  & $L '==== Стабильность (30 дней) ===='
  if ($script:Stab) {
    & $L ("  Синие экраны: {0}; внезапные выключения: {1}; WHEA: {2}; ошибки диска: {3}" -f @($script:Stab.BugChecks).Count, $script:Stab.UnexpectedShutdowns, $script:Stab.Whea, $script:Stab.DiskErrors)
    foreach ($x in @($script:Stab.BugChecks)) { & $L ("  BSOD {0:dd.MM HH:mm} {1}" -f $x.Time, $x.Text) }
    foreach ($x in @($script:Stab.Minidumps)) { & $L ("  дамп {0} {1:dd.MM.yyyy}" -f $x.Name, $x.Time) }
    foreach ($x in @($script:Stab.AppCrashes)) { & $L ("  падения: {0} — {1}" -f $x.App, $x.Count) }
  }
  & $L '==== Безопасность ===='
  if ($script:Sec) {
    if ($script:Sec.Defender) { & $L ("  Защитник: служба {0}, антивирус {1}, в реальном времени {2}, базам {3} дн., режим {4}" -f $script:Sec.Defender.Service, $script:Sec.Defender.Antivirus, $script:Sec.Defender.RealTime, $(if ($script:Sec.Defender.SignaturesAgeDays -ge 65535) { '—' } else { $script:Sec.Defender.SignaturesAgeDays }), $script:Sec.Defender.Mode) }
    foreach ($a in @($script:Sec.AvProducts)) { & $L ("  Антивирус: {0} (вкл: {1}, базы свежие: {2})" -f $a.Name, $a.Enabled, $a.UpToDate) }
    foreach ($t in @($script:Sec.Threats)) { & $L ("  Угроза {0:dd.MM.yyyy}: {1} — {2}" -f $t.Time, $t.Name, $t.Resources) }
    & $L ("  BitLocker: {0}; DNS: {1}" -f $script:Sec.BitLocker, (@($script:Sec.Dns) -join ', '))
    foreach ($h in @($script:Sec.Hosts)) { & $L ("  hosts: {0}" -f $h) }
  }
  & $L '==== Устройства с ошибками ===='
  foreach ($d in @($script:DevErr)) { & $L ("  {0} (код {1}, {2})" -f $d.Name, $d.Code, $d.Class) }
  & $L '==== Обновления ===='
  foreach ($x in @($script:Upd.Recent)) { & $L ("  {0:dd.MM.yyyy} [{1}] {2}" -f $x.Date, $(switch ($x.Result) { 2 { 'ок' } 3 { 'частично' } 4 { 'ОШИБКА' } 5 { 'отменено' } default { $x.Result } }), $x.Title) }
  & $L '==== Установленные программы ===='
  foreach ($p in @($script:Programs)) { & $L ("  {0} {1} | {2} | {3}" -f $p.Name, $p.Version, $p.Publisher, $(if ($p.Installed) { $p.Installed.ToString('dd.MM.yyyy') } else { '' })) }
  Write-TextFile (Join-Path $dir 'report.txt') $sb.ToString()
}

function Close-Session([string]$dir) {
  if ($script:Errors.Count) { Write-TextFile (Join-Path $dir 'errors.txt') (($script:Errors | ForEach-Object { [string]$_ }) -join "`r`n") }
  Write-TextFile (Join-Path $dir 'console.txt') (($script:Log | ForEach-Object { [string]$_ }) -join "`r`n")
  $zip = "$dir.zip"
  try {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip -Force -ErrorAction Stop
    Say ''
    Say ('Отчёт: ' + $zip) 'Green'
  } catch { Say ('Отчёт (папка): ' + $dir) 'Green' }
  if ($script:Errors.Count) { Say ("Внутренних ошибок набора: {0} (errors.txt в отчёте — прислать Claude)" -f $script:Errors.Count) 'DarkYellow' }
}

function Run-Diag {
  Invoke-Diagnostics
  $mark = $script:Log.Count
  Show-Summary
  Show-Findings $script:Findings
  Show-Space
  $script:ReportLines = @($script:Log | Select-Object -Skip $mark)
  $dir = New-SessionDir 'diag'
  Save-Metrics (Get-Metrics 'diag')
  Save-DiagReport $dir
  Close-Session $dir
}

# ================================================================ ОПТИМИЗАЦИЯ

$script:SectionOrder = @('restore', 'security', 'startup', 'task', 'service', 'tweak', 'appx', 'power', 'uninstall', 'trim', 'clean', 'scan')
$script:SectionTitles = @{
  restore = 'Точка восстановления'
  security = 'Безопасность (обратимо)'
  tweak   = 'Реклама, «советы» и лишнее в Windows (обратимо; часть — после перезагрузки)'
  appx    = 'Приложения из Магазина (вернуть — переустановкой из Магазина, набор пробует сам)'
  uninstall = 'Удаление программ (НЕОБРАТИМО — вернуть только переустановкой)'
  scan    = 'Проверка на вирусы'
  startup = 'Автозагрузка программ (обратимо)'
  task    = 'Задачи планировщика сторонних программ (обратимо)'
  service = 'Службы сторонних программ: «Автоматически» -> «Вручную» (обратимо)'
  power   = 'Электропитание (обратимо)'
  trim    = 'Обслуживание SSD (безвредно)'
  clean   = 'Очистка места (НЕОБРАТИМО, но безвредно — только мусор)'
}
$script:LevelNames = @{ auto = 'авто'; base = 'можно'; ask = 'спросить клиента' }
$script:GuidSaver = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$script:GuidBalanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:StdPlans = @($script:GuidSaver, $script:GuidBalanced, '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
$script:ExitCode = 0

function Classify($text, [string]$kind, $item, $rules) {
  if ($text -match $script:HardProtect) { return @{ Level = 'keep'; Note = 'защищено' } }
  if ($kind -eq 'start' -and $item.Exe -match '^[A-Za-z]:\\' -and $item.Exists -eq $false) { return @{ Level = 'auto'; Note = 'Битая запись: программы уже нет на диске' } }
  $r = Get-Rule $rules $kind $text
  if ($r) { return @{ Level = $r.level; Note = $r.note } }
  if ($kind -eq 'start') { return @{ Level = 'ask'; Note = 'Неизвестная программа — спросить клиента' } }
  return @{ Level = 'none'; Note = '' }
}

function New-PlanItem([string]$section, [string]$kind, [string]$title, [string]$detail, [string]$level, $data, $size) {
  return [pscustomobject]@{ Id = 0; Section = $section; Kind = $kind; Title = $title; Detail = $detail; Level = $level
                            Default = ($level -eq 'auto'); Checked = ($level -eq 'auto'); Data = $data; Size = $size; Result = '' }
}

function Build-Plan {
  $rules = Read-Tsv 'startup.tsv'
  $p = New-Object System.Collections.ArrayList
  if ($script:Sys.ProductType -eq 1) {
    [void]$p.Add((New-PlanItem 'restore' 'restore' 'Создать точку восстановления Windows' 'если защита системы выключена — включится на диске C: (откат набора её не выключает)' 'auto' $null $null))
  }
  foreach ($s in @($script:Startup)) {
    if (-not $s.Enabled) { continue }
    $c = Classify ('{0} | {1} | {2}' -f $s.Name, $s.Command, $s.Publisher) 'start' $s $rules
    if (@('auto', 'base', 'ask') -notcontains $c.Level) { continue }
    $pub = $s.Publisher; if (-not $pub) { $pub = 'издатель неизвестен' }
    [void]$p.Add((New-PlanItem 'startup' $s.Kind $s.Name ('{0} | {1} | {2}' -f $c.Note, $pub, $s.Where) $c.Level $s $null))
  }
  foreach ($t in @($script:Tasks)) {
    if (-not $t.Enabled) { continue }
    $c = Classify ('{0}{1} | {2} | {3}' -f $t.Path, $t.Name, $t.Command, $t.Publisher) 'task' $t $rules
    if (@('auto', 'base', 'ask') -notcontains $c.Level) { continue }
    [void]$p.Add((New-PlanItem 'task' 'task' ($t.Path + $t.Name) $c.Note $c.Level $t $null))
  }
  foreach ($sv in @($script:Services)) {
    if (-not $sv.Enabled) { continue }
    $c = Classify ('{0} | {1} | {2} | {3}' -f $sv.Name, $sv.Display, $sv.Command, $sv.Publisher) 'service' $sv $rules
    if (@('auto', 'base', 'ask') -notcontains $c.Level) { continue }
    [void]$p.Add((New-PlanItem 'service' 'service' ('{0} [{1}]' -f $sv.Display, $sv.Name) $c.Note $c.Level $sv $null))
  }
  foreach ($g in @($script:Tweaks)) {
    if (-not $g -or $g.Pending -eq 0 -or @('auto', 'base', 'ask') -notcontains $g.Level) { continue }
    $sec = 'tweak'; if ($g.Section -eq 'security') { $sec = 'security' }
    [void]$p.Add((New-PlanItem $sec 'tweak' $g.Title $g.Note $g.Level $g $null))
  }
  $appRules = Read-Tsv 'apps.tsv'
  $byName = [ordered]@{}
  foreach ($a in @($script:Apps)) { if ($a) { if (-not $byName.Contains($a.Name)) { $byName[$a.Name] = New-Object System.Collections.ArrayList }; [void]$byName[$a.Name].Add($a) } }
  foreach ($n in $byName.Keys) {
    $r = $null
    foreach ($x in $appRules) { try { if ($n -match ('(?i)^(' + $x.match + ')$')) { $r = $x; break } } catch {} }
    if (-not $r -or @('auto', 'base', 'ask') -notcontains $r.level) { continue }
    [void]$p.Add((New-PlanItem 'appx' 'appx' $r.title $r.note $r.level ([pscustomobject]@{ Apps = @($byName[$n]); StoreId = $r.storeid; Name = $n }) $null))
  }
  foreach ($u in (Get-UninstallCandidates)) {
    if (-not $u) { continue }
    $ttl = $u.Program.Name; if ($u.Program.Version -and $ttl -notlike ('*' + $u.Program.Version + '*')) { $ttl += ' ' + $u.Program.Version }
    [void]$p.Add((New-PlanItem 'uninstall' 'uninstall' $ttl $u.Note 'ask' $u.Program $null))
  }
  if ($script:Power -and $script:Power.HiberfilBytes -gt 1GB -and $script:Power.Hibernate -ne 0) {
    $lv = 'base'; $det = 'настольный ПК — гибернация обычно не нужна; быстрый запуск тоже выключится'
    if ($script:Power.HasBattery) { $lv = 'ask'; $det = 'ноутбук — пропадёт «Гибернация» и быстрый запуск; спросить клиента' }
    [void]$p.Add((New-PlanItem 'power' 'hibernate' ('Выключить гибернацию — освободит {0}' -f (Fmt-Size $script:Power.HiberfilBytes)) $det $lv $null $script:Power.HiberfilBytes))
  }
  if ($script:Sec -and $script:Sec.Defender -and $script:Sec.Defender.RealTime) {
    [void]$p.Add((New-PlanItem 'scan' 'scan' 'Быстрая проверка Защитником Windows (5–15 мин)' 'Найденное Защитник сам отправит в карантин' 'base' $null $null))
  }
  $pw = $script:Power
  if ($pw -and $pw.PlanGuid -eq $script:GuidSaver -and @($pw.Plans) -contains $script:GuidBalanced) {
    $lv = 'auto'; $det = 'настольный ПК — экономия только замедляет'
    if ($pw.HasBattery) { $lv = 'ask'; $det = 'ноутбук — спросить, не включал ли клиент экономию сам' }
    [void]$p.Add((New-PlanItem 'power' 'power' 'Схема питания «Экономия энергии» -> «Сбалансированная»' $det $lv @{ New = $script:GuidBalanced } $null))
  }
  $sd = @($script:Disks | Where-Object { $_.System }) | Select-Object -First 1
  if ($sd -and $sd.Type -eq 'SSD') {
    [void]$p.Add((New-PlanItem 'trim' 'trim' ('TRIM для SSD (диск {0})' -f $env:SystemDrive) 'Windows и так делает это раз в неделю; безвредно' 'base' $null $null))
  }
  foreach ($t in @($script:Clean)) {
    if ($t.Special -eq 'dism' -or $t.Special -eq 'drivers') { [void]$p.Add((New-PlanItem 'clean' 'clean' $t.Title 'размер заранее неизвестен; окно не закрывать' $t.Level $t $null)); continue }
    if (-not $t.Size -or $t.Size -lt 1MB) { continue }
    if ($t.Special -eq 'wu' -and @($script:Pending).Count) { continue }
    $det = ''
    if ($t.Special -eq 'browsers') { $det = 'браузеры (Chrome, Edge, Firefox…) должны быть закрыты' }
    if ($t.Key -eq 'memdump') { $det = 'если были синие экраны — сначала прислать отчёт Claude' }
    if ($t.Special -eq 'winold') { $det = 'пропадёт возможность откатить большое обновление Windows («Вернуться к предыдущей версии»)' }
    if ($t.Special -eq 'telegram') { $det = 'сами чаты и файлы на серверах Telegram не пострадают' }
    [void]$p.Add((New-PlanItem 'clean' 'clean' ('{0} — {1}' -f $t.Title, (Fmt-Size $t.Size)) $det $t.Level $t $t.Size))
  }
  $sorted = New-Object System.Collections.ArrayList
  foreach ($sec in $script:SectionOrder) { foreach ($it in $p) { if ($it.Section -eq $sec) { [void]$sorted.Add($it) } } }
  $i = 1; foreach ($it in $sorted) { $it.Id = $i; $i++ }
  return ,$sorted
}

function Show-Plan($plan) {
  Head 'План ([x] — будет сделано)'
  $cur = ''
  foreach ($it in $plan) {
    if ($it.Section -ne $cur) { $cur = $it.Section; Say ''; Say ('  -- ' + $script:SectionTitles[$cur] + ' --') 'Cyan' }
    $mk = ' '; $c = 'Gray'; if ($it.Checked) { $mk = 'x'; $c = 'White' }
    Say ("  {0,3} [{1}] {2}  ({3})" -f $it.Id, $mk, $it.Title, $script:LevelNames[$it.Level]) $c
    if ($it.Detail) { Say ('            ' + $it.Detail) 'DarkGray' }
  }
  $sel = @($plan | Where-Object { $_.Checked })
  $free = ($sel | Where-Object { $_.Size } | Measure-Object Size -Sum).Sum
  Say ''
  Say ("  Отмечено: {0}; освободится примерно {1}" -f $sel.Count, (Fmt-Size $free)) 'Green'
}

function Edit-Plan($plan) {
  if (-not $script:Interactive) { Show-Plan $plan; return $true }
  while ($true) {
    Show-Plan $plan
    Say '  Команды: номера (3 5 7) или диапазон (3-7) — переключить; b — отметить все «можно»; n — снять все;' 'Yellow'
    Say '           d — как было; y — ВЫПОЛНИТЬ; q — выйти без изменений' 'Yellow'
    $a = Ask '>'
    if ($a -eq 'q' -or $a -eq 'й') { return $false }
    if (@('y', 'yes', 'н', 'д', 'да') -contains $a) { return $true }
    if ($a -eq 'b' -or $a -eq 'и') { foreach ($it in $plan) { if ($it.Level -eq 'base') { $it.Checked = $true } }; continue }
    if ($a -eq 'n' -or $a -eq 'т') { foreach ($it in $plan) { $it.Checked = $false }; continue }
    if ($a -eq 'd' -or $a -eq 'в') { foreach ($it in $plan) { $it.Checked = $it.Default }; continue }
    foreach ($tok in ($a -split '[\s,;]+')) {
      if ($tok -match '^(\d+)-(\d+)$') { $from = [int]$Matches[1]; $to = [int]$Matches[2]; foreach ($it in $plan) { if ($it.Id -ge $from -and $it.Id -le $to) { $it.Checked = -not $it.Checked } } }
      elseif ($tok -match '^\d+$') { foreach ($it in $plan) { if ($it.Id -eq [int]$tok) { $it.Checked = -not $it.Checked } } }
    }
  }
}

# ---------------------------------------------------------------- действия

function Invoke-Sc([string[]]$a) {
  $out = & sc.exe @a 2>&1
  if ($LASTEXITCODE -ne 0) { throw ('sc.exe {0}: {1}' -f ($a -join ' '), (($out | Out-String).Trim())) }
}

function New-StartupDisabledBytes {
  $b = New-Object byte[] 12
  $b[0] = 3
  $ft = [BitConverter]::GetBytes([long](Get-Date).ToFileTime())
  [Array]::Copy($ft, 0, $b, 4, 8)
  return ,$b
}

function Invoke-PlanItem($it, [string]$batch) {
  $d = $it.Data
  switch ($it.Kind) {
    'startup' { Set-RegJournaled $d.ApprovedKey $d.ApprovedName 'Binary' (New-StartupDisabledBytes) $batch ('Автозагрузка: ' + $it.Title) }
    'uwp'     { Set-RegJournaled $d.ApprovedKey 'State' 'DWord' 1 $batch ('Автозагрузка (Магазин): ' + $it.Title) }
    'task' {
      if ($d.Path -like '\Microsoft\*') { throw 'задачи Microsoft не трогаем' }
      Add-JournalEntry ([ordered]@{ type = 'task'; path = $d.Path; name = $d.Name; batch = $batch; label = ('Задача: ' + $d.Path + $d.Name); time = (Get-Date).ToString('s') })
      Disable-ScheduledTask -TaskPath $d.Path -TaskName $d.Name -ErrorAction Stop | Out-Null
    }
    'service' {
      if (-not $d.Exe -or $d.Exe.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase)) { throw 'службы Windows не трогаем' }
      if (('{0} {1} {2}' -f $d.Name, $d.Display, $d.Command) -match $script:HardProtect) { throw 'служба защищена' }
      $old = 'auto'; if ($d.Delayed) { $old = 'delayed-auto' }
      Add-JournalEntry ([ordered]@{ type = 'service'; name = $d.Name; old = $old; batch = $batch; label = ('Служба: ' + $d.Display + ' [' + $d.Name + ']'); time = (Get-Date).ToString('s') })
      Invoke-Sc @('config', $d.Name, 'start=', 'demand')
    }
    'power' {
      $old = $script:Power.PlanGuid
      if ($script:StdPlans -notcontains $old -or $script:StdPlans -notcontains $d.New) { throw 'нестандартная схема питания' }
      Add-JournalEntry ([ordered]@{ type = 'power'; old = $old; new = $d.New; batch = $batch; label = 'Схема питания'; time = (Get-Date).ToString('s') })
      & powercfg.exe /setactive $d.New | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "powercfg вернул $LASTEXITCODE" }
    }
    'tweak' { Invoke-Tweak $d $batch ('Настройка: ' + $it.Title) }
    'appx' { foreach ($a in @($d.Apps)) { Remove-StoreApp $a $d.StoreId $batch ('Приложение: ' + $it.Title) } }
    'hibernate' {
      Add-JournalEntry ([ordered]@{ type = 'hibernate'; old = 'on'; batch = $batch; label = 'Гибернация'; time = (Get-Date).ToString('s') })
      & powercfg.exe /hibernate off | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "powercfg вернул $LASTEXITCODE" }
    }
    default { throw ('неизвестный вид: ' + $it.Kind) }
  }
}

function Test-Net { try { $null = [Net.Dns]::GetHostAddresses('www.msftconnecttest.com'); return $true } catch { return $false } }
function Get-Health {
  return [pscustomobject]@{
    'Проводник (рабочий стол)' = [bool](Get-Process explorer -ErrorAction SilentlyContinue)
    'Защитник Windows'         = ((Get-Service WinDefend -ErrorAction SilentlyContinue).Status -eq 'Running')
    'Звук'                     = ((Get-Service Audiosrv -ErrorAction SilentlyContinue).Status -eq 'Running')
    'Интернет (DNS)'           = (Test-Net)
    'Центр обновлений'         = ((Get-Service wuauserv -ErrorAction SilentlyContinue).StartType -ne 'Disabled')
  }
}
function Compare-Health($a, $b) {
  $bad = @()
  foreach ($p in $a.PSObject.Properties) { if ($p.Value -and -not $b.($p.Name)) { $bad += $p.Name } }
  return ,$bad
}

function New-RestorePoint {
  $k = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
  $old = Get-RegValue $k 'SystemRestorePointCreationFrequency'
  try {
    Set-RegValueRaw $k 'SystemRestorePointCreationFrequency' 'DWord' 0
    try { Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop } catch { Note-Error 'Enable-ComputerRestore' $_.Exception.Message }
    Checkpoint-Computer -Description ('win-kit ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    return $true
  } catch { Note-Error 'Checkpoint-Computer' $_.Exception.Message; Say ('  Точка восстановления не создана: ' + $_.Exception.Message) 'Yellow'; return $false }
  finally {
    try { if ($old) { Set-RegValueRaw $k 'SystemRestorePointCreationFrequency' $old.Kind $old.Value } else { Remove-ItemProperty -LiteralPath $k -Name 'SystemRestorePointCreationFrequency' -Force -ErrorAction SilentlyContinue } } catch {}
  }
}

function Remove-FilesIn([string]$root, [int]$age, [string]$filter) {
  $freed = [long]0; $locked = 0
  $rootFull = $root.TrimEnd('\')
  foreach ($f in (Get-FilesSafe $root $age $filter)) {
    $fn = $f.FullName
    if (-not ($fn -eq $rootFull -or $fn.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))) { Note-Error 'clean' "вне папки: $fn"; continue }
    try { $len = $f.Length; if ($f.Attributes -band [IO.FileAttributes]::ReadOnly) { $f.Attributes = 'Normal' }; $f.Delete(); $freed += $len } catch { $locked++ }
  }
  return [pscustomobject]@{ Freed = $freed; Locked = $locked }
}

function Invoke-Clean($t) {
  $freed = [long]0; $locked = 0
  switch ($t.Special) {
    'recycle' { Clear-RecycleBin -Force -ErrorAction Stop; return [pscustomobject]@{ Freed = $t.Size; Locked = 0 } }
    'dism' {
      Say '    DISM работает (5–30 минут), окно не закрывать…' 'DarkGray'
      & dism.exe /Online /Cleanup-Image /StartComponentCleanup /NoRestart
      if ($LASTEXITCODE -ne 0) { throw "DISM вернул $LASTEXITCODE" }
      return [pscustomobject]@{ Freed = 0; Locked = 0 }
    }
    'browsers' {
      $run = @(Get-Process chrome, msedge, firefox, brave, browser, vivaldi -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Select-Object -Unique)
      if ($run.Count) { throw ('закройте браузеры: ' + ($run -join ', ')) }
    }
    'telegram' {
      if (@(Get-Process Telegram -ErrorAction SilentlyContinue).Count) { throw 'закройте Telegram (и в трее)' }
    }
    'winold' {
      Invoke-CleanMgr @('Previous Installations', 'Temporary Setup Files', 'Windows Upgrade Log Files', 'Setup Log Files', 'Windows ESD installation files')
      $left = 0; if (Test-Path -LiteralPath $t.Paths[0]) { $left = (Measure-DirFast $t.Paths[0] (New-Object System.Collections.ArrayList) ((Get-Date).AddSeconds(60))).Size }
      return [pscustomobject]@{ Freed = [math]::Max(0, [long]$t.Size - [long]$left); Locked = 0 }
    }
    'drivers' { Invoke-CleanMgr @('Device Driver Packages'); return [pscustomobject]@{ Freed = 0; Locked = 0 } }
    'do' {
      try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; return [pscustomobject]@{ Freed = $t.Size; Locked = 0 } } catch { Note-Error 'DeliveryOptimization' $_.Exception.Message }
    }
  }
  $wasRunning = $false
  if ($t.Special -eq 'wu') {
    $svc = Get-Service wuauserv -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { $wasRunning = $true; Stop-Service wuauserv -Force -ErrorAction SilentlyContinue }
  }
  try {
    foreach ($p in $t.Paths) { $r = Remove-FilesIn $p $t.Age $t.Filter; $freed += $r.Freed; $locked += $r.Locked }
  } finally {
    if ($wasRunning) { Start-Service wuauserv -ErrorAction SilentlyContinue }
  }
  return [pscustomobject]@{ Freed = $freed; Locked = $locked }
}

function Undo-Entry($e) {
  switch ($e.type) {
    'registry' {
      if (-not (Test-RegWriteAllowed $e.path $e.name)) { throw 'путь вне белого списка' }
      if ($e.existed) { Set-RegValueRaw $e.path $e.name $e.kind (ConvertFrom-JValue $e.kind $e.old) }
      else {
        Remove-ItemProperty -LiteralPath $e.path -Name $e.name -Force -ErrorAction SilentlyContinue
        # ключ создавал набор и он опустел — убрать (например, пустой раздел политик Edge)
        if ($e.keyExisted -eq $false) {
          try { $k = Get-Item -LiteralPath $e.path -ErrorAction Stop; if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $e.path -Force -ErrorAction SilentlyContinue } } catch {}
        }
      }
    }
    'appx' { Restore-StoreApp $e }
    'hibernate' { & powercfg.exe /hibernate on | Out-Null; if ($LASTEXITCODE -ne 0) { throw "powercfg вернул $LASTEXITCODE" } }
    'task' { Enable-ScheduledTask -TaskPath $e.path -TaskName $e.name -ErrorAction Stop | Out-Null }
    'service' {
      if (@('auto', 'delayed-auto') -notcontains $e.old) { throw ('странный тип запуска: ' + $e.old) }
      Invoke-Sc @('config', $e.name, 'start=', $e.old)
    }
    'power' {
      if ($e.old -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { throw 'странная схема' }
      & powercfg.exe /setactive $e.old | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "powercfg вернул $LASTEXITCODE" }
    }
    default { throw ('неизвестная запись: ' + $e.type) }
  }
}

# откат записей журнала (в обратном порядке); $pick — номера записей или $null = все неотменённые
function Undo-Journal([string]$path, $pick) {
  $raw = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
  $entries = @(); foreach ($x in @($raw.entries)) { if ($x) { $entries += $x } }
  $ok = 0; $fail = 0
  for ($i = $entries.Count - 1; $i -ge 0; $i--) {
    $e = $entries[$i]
    if ($null -ne $pick -and (@($pick) -notcontains $i)) { continue }
    if ($e.reverted) { continue }
    if ($e.type -eq 'uninstall') { Say ('  необратимо, вернуть только переустановкой: ' + $e.name) 'Yellow'; continue }
    try {
      Undo-Entry $e
      $e | Add-Member -NotePropertyName reverted -NotePropertyValue ((Get-Date).ToString('s')) -Force
      $ok++; Say ('  возвращено: ' + $e.label) 'Green'
    } catch { $fail++; Note-Error 'undo' ($e.label + ': ' + $_.Exception.Message); Say ('  НЕ удалось вернуть: ' + $e.label + ' — ' + $_.Exception.Message) 'Red' }
  }
  $raw.entries = $entries
  [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $raw -Depth 8), $script:Utf8Bom)
  if ($fail) { $script:ExitCode = 1 }
  return [pscustomobject]@{ Ok = $ok; Fail = $fail }
}

function Invoke-Plan($plan) {
  $sel = @($plan | Where-Object { $_.Checked })
  # 1. точка восстановления
  foreach ($it in @($sel | Where-Object { $_.Kind -eq 'restore' })) {
    Say '  Создаю точку восстановления…' 'Cyan'
    if (New-RestorePoint) { $it.Result = 'ok'; Say '    готово' 'Green' }
    else {
      $it.Result = 'не создана'
      if ($script:Interactive) {
        $a = Ask '    Продолжить без точки восстановления? Журнал отката всё равно будет (y/n)'
        if (-not (Is-Yes $a)) { Say 'Остановлено, ничего не изменено.' 'Yellow'; return }
      }
    }
  }
  # 2. обратимые изменения — партиями по 5 с проверкой
  $jItems = @($sel | Where-Object { @('startup', 'uwp', 'task', 'service', 'power', 'tweak', 'appx', 'hibernate') -contains $_.Kind })
  $uItems = @($sel | Where-Object { $_.Kind -eq 'uninstall' })
  $stopped = $false
  if ($jItems.Count -or $uItems.Count) {
    Start-Journal
    Say ('  Журнал отката: ' + $script:JournalPath) 'DarkGray'
    $base = Get-Health
    $bn = 0
    for ($i = 0; $i -lt $jItems.Count; $i += 5) {
      $bn++; $batch = "b$bn"
      $last = [math]::Min($i + 4, $jItems.Count - 1)
      foreach ($it in $jItems[$i..$last]) {
        try { Invoke-PlanItem $it $batch; $it.Result = 'ok'; Say ('  [ok] ' + $it.Title) 'Green' }
        catch { $it.Result = 'ошибка: ' + $_.Exception.Message; $script:ExitCode = 1; Note-Error ('item ' + $it.Title) $_.Exception.Message; Say ('  [ошибка] ' + $it.Title + ' — ' + $_.Exception.Message) 'Red' }
      }
      Start-Sleep -Seconds 2
      $bad = Compare-Health $base (Get-Health)
      if ($bad.Count) {
        Say ('  ! После партии {0} перестало работать: {1}. Откатываю партию…' -f $bn, ($bad -join ', ')) 'Red'
        $idx = @(); $k = 0; foreach ($e in $script:Journal.entries) { if ($e.batch -eq $batch) { $idx += $k }; $k++ }
        $null = Undo-Journal $script:JournalPath $idx
        foreach ($it in $jItems[$i..$last]) { $it.Result = 'откачено (проверка после партии)' }
        $script:ExitCode = 1; $stopped = $true; break
      }
    }
  }
  if ($stopped) { Say '  Дальнейшие изменения остановлены. Прислать отчёт Claude.' 'Red'; return }
  # 2б. удаление программ — по одной, с окном удаления (необратимо)
  foreach ($it in $uItems) {
    Say ('  Удаляю: ' + $it.Title) 'Cyan'
    try { Invoke-Uninstall $it.Data; $it.Result = 'удалено'; Say ('  [ok] удалено: ' + $it.Title) 'Green' }
    catch { $it.Result = 'не удалено: ' + $_.Exception.Message; Note-Error ('uninstall ' + $it.Title) $_.Exception.Message; Say ('  [не удалено] ' + $it.Title + ' — ' + $_.Exception.Message) 'Yellow' }
  }
  # 3. TRIM
  foreach ($it in @($sel | Where-Object { $_.Kind -eq 'trim' })) {
    try { Optimize-Volume -DriveLetter ($env:SystemDrive.Substring(0, 1)) -ReTrim -ErrorAction Stop; $it.Result = 'ok'; Say ('  [ok] ' + $it.Title) 'Green' }
    catch { $it.Result = 'ошибка: ' + $_.Exception.Message; Note-Error 'trim' $_.Exception.Message; Say ('  [ошибка] ' + $it.Title + ' — ' + $_.Exception.Message) 'Yellow' }
  }
  # 4. очистка (необратимо, в журнал не пишется)
  $total = [long]0
  foreach ($it in @($sel | Where-Object { $_.Kind -eq 'clean' })) {
    try {
      $r = Invoke-Clean $it.Data
      $total += [long]$r.Freed
      $it.Result = ('ok, освобождено {0}' -f (Fmt-Size $r.Freed))
      if ($r.Locked) { $it.Result += (', занято программами: {0} файлов (пропущены)' -f $r.Locked) }
      Say ('  [ok] {0}: освобождено {1}' -f $it.Data.Title, (Fmt-Size $r.Freed)) 'Green'
    } catch { $it.Result = 'ошибка: ' + $_.Exception.Message; Note-Error ('clean ' + $it.Data.Key) $_.Exception.Message; Say ('  [пропущено] ' + $it.Data.Title + ' — ' + $_.Exception.Message) 'Yellow' }
  }
  if ($total -gt 0) { Say ('  Всего освобождено: ' + (Fmt-Size $total)) 'Green' }
  # 5. проверка Защитником (последней — долгая)
  foreach ($it in @($sel | Where-Object { $_.Kind -eq 'scan' })) {
    Say '  Защитник проверяет компьютер (5–15 минут)…' 'Cyan'
    $t0 = Get-Date
    try {
      Start-MpScan -ScanType QuickScan -ErrorAction Stop
      $found = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $t0 })
      if ($found.Count) { $it.Result = ('найдено угроз: {0} (в карантине)' -f $found.Count); Say ('  [!] ' + $it.Result + ' — прислать отчёт Claude') 'Red'; $script:ScanFound = $found.Count }
      else { $it.Result = 'чисто'; Say '  [ok] Защитник ничего не нашёл' 'Green' }
    } catch { $it.Result = 'ошибка: ' + $_.Exception.Message; Note-Error 'scan' $_.Exception.Message; Say ('  [ошибка] проверка — ' + $_.Exception.Message) 'Yellow' }
  }
}

function Run-Optimize {
  if (-not (Test-Admin)) { Say 'Нужны права администратора: запускайте через start.bat.' 'Red'; $script:ExitCode = 1; return }
  Invoke-Diagnostics
  $mark = $script:Log.Count
  Show-Summary
  Show-Findings $script:Findings
  Show-Space
  $script:ReportLines = @($script:Log | Select-Object -Skip $mark)
  $before = Get-Metrics 'before-opt'
  $dir = New-SessionDir 'optimize'
  Save-DiagReport $dir
  if (@($script:Sec.Managed).Count -and -not $AllowManaged) {
    Say ''; Say 'Это рабочий (управляемый) компьютер — изменения не делаем. Только диагностика.' 'Yellow'
    Close-Session $dir; return
  }
  $plan = Build-Plan
  if ($plan.Count -eq 0) { Say 'Предложить нечего — всё уже в порядке.' 'Green'; Close-Session $dir; return }
  $go = Edit-Plan $plan
  if (-not $go) { Say 'Отменено — ничего не изменено.' 'Yellow'; Close-Session $dir; return }
  Head 'Выполняю'
  Save-Metrics $before
  Invoke-Plan $plan
  $lines = @('win-kit ' + $script:Version + ' — оптимизация ' + (Get-Date -Format 'dd.MM.yyyy HH:mm'), '')
  foreach ($it in $plan) { $lines += ('{0,3} [{1}] {2} | {3} | {4}' -f $it.Id, $(if ($it.Checked) { 'x' } else { ' ' }), $it.Title, $script:LevelNames[$it.Level], $it.Result) }
  if ($script:JournalPath) { $lines += ''; $lines += ('Журнал отката: ' + $script:JournalPath); Copy-Item -LiteralPath $script:JournalPath -Destination (Join-Path $dir 'journal.json') -ErrorAction SilentlyContinue }
  Write-TextFile (Join-Path $dir 'optimize.txt') ($lines -join "`r`n")
  Head 'Готово'
  Say '  Проверьте с клиентом: Пуск, поиск, интернет, звук, принтер, камера, его главные программы.'
  Say '  Отключённое из автозагрузки перестанет запускаться со следующего входа в Windows.'
  Say '  Откат: start.bat -> 3 (журнал хранится на этом ПК в C:\ProgramData\CleanMyPC\backups).'
  Close-Session $dir
  if ($script:Interactive -and -not $NoReboot) {
    Say ''
    Say '  Перезагрузка покажет результат («было/стало» — пункт 1 через 2–3 минуты после входа).' 'Cyan'
    Say '  AnyDesk отключится — клиенту нужно будет снова дать доступ.' 'Cyan'
    $a = Ask '  Перезагрузить через 30 секунд? (y/n)'
    if (Is-Yes $a) { & shutdown.exe /r /t 30 /c 'win-kit: restart' }
    elseif (@($plan | Where-Object { $_.Kind -eq 'tweak' -and $_.Result -eq 'ok' }).Count) {
      $a = Ask '  Перезапустить Проводник, чтобы настройки Пуска и поиска применились сейчас? (y/n)'
      if (Is-Yes $a) { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3; if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe } }
    }
  }
}

# ================================================================ ОТКАТ

function Run-Rollback {
  if (-not (Test-Admin)) { Say 'Нужны права администратора: запускайте через start.bat.' 'Red'; $script:ExitCode = 1; return }
  Head 'Откат по журналу'
  $files = @(Get-ChildItem -LiteralPath $script:BackupDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ($files.Count -eq 0) { Say '  Журналов нет — откатывать нечего.' 'Yellow'; return }
  $info = @()
  $n = 1
  foreach ($f in $files) {
    $cnt = 0; $act = 0
    try { $j = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json; foreach ($e in @($j.entries)) { if ($e) { $cnt++; if (-not $e.reverted) { $act++ } } } } catch {}
    $info += [pscustomobject]@{ N = $n; File = $f; Count = $cnt; Active = $act }
    Say ('  {0}) {1}  изменений: {2}, ещё не отменено: {3}' -f $n, $f.BaseName, $cnt, $act)
    $n++
  }
  $pickS = 1
  if ($script:Interactive) {
    $a = Ask 'Номер сеанса (Enter — последний, q — выход)'
    if ($a -eq 'q' -or $a -eq 'й') { return }
    if ($a -match '^\d+$') { $pickS = [int]$a }
  }
  $s = @($info | Where-Object { $_.N -eq $pickS }) | Select-Object -First 1
  if (-not $s) { Say 'Нет такого номера.' 'Yellow'; return }
  $j = (Get-Content -LiteralPath $s.File.FullName -Raw -Encoding UTF8) | ConvertFrom-Json
  $entries = @(); foreach ($e in @($j.entries)) { if ($e) { $entries += $e } }
  $k = 0
  foreach ($e in $entries) { $mk = ' '; if ($e.reverted) { $mk = 'отменено' }; Say ('  {0,3} {1} {2}' -f ($k + 1), $e.label, $mk); $k++ }
  $pick = $null
  if ($script:Interactive) {
    $a = Ask 'a — отменить всё; номера через пробел — выборочно; q — выход'
    if ($a -eq 'q' -or $a -eq 'й' -or $a -eq '') { return }
    if ($a -ne 'a' -and $a -ne 'ф') {
      $pick = @(); foreach ($tok in ($a -split '[\s,;]+')) { if ($tok -match '^\d+$') { $pick += ([int]$tok - 1) } }
    }
  }
  $dir = New-SessionDir 'rollback'
  $r = Undo-Journal $s.File.FullName $pick
  Say ('  Возвращено: {0}; ошибок: {1}' -f $r.Ok, $r.Fail) $(if ($r.Fail) { 'Red' } else { 'Green' })
  Say '  Автозагрузка вернётся со следующего входа в Windows (или после перезагрузки).'
  Copy-Item -LiteralPath $s.File.FullName -Destination (Join-Path $dir 'journal.json') -ErrorAction SilentlyContinue
  Close-Session $dir
}

# ================================================================ МЕНЮ

function Show-Menu {
  while ($true) {
    $script:Errors.Clear(); $script:Log.Clear()
    Head ('win-kit {0} — диагностика и чистка Windows' -f $script:Version)
    if (-not (Test-Admin)) { Say '  ! Нет прав администратора: диагностика неполная, оптимизация и откат недоступны. Запускайте через start.bat.' 'Yellow' }
    if ($script:User.Source -eq 'explorer') { Say ('  Рабочий стол пользователя: ' + $script:User.Name + ' (права админа — от другой учётки)') 'Yellow' }
    Say '  1) Диагностика (только чтение)'
    Say '  2) Оптимизация (план -> «y» -> точка восстановления и журнал -> изменения)'
    Say '  3) Откат по журналу'
    Say '  0) Выход'
    $a = Ask 'Выбор'
    switch ($a) {
      '1' { Run-Diag }
      '2' { Run-Optimize }
      '3' { Run-Rollback }
      '0' { return }
      'q' { return }
      default { }
    }
  }
}

# ================================================================ ЗАПУСК

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
  Write-Host 'PowerShell работает в ограниченном режиме (политика организации) — набор здесь не работает.' -ForegroundColor Red
  exit 3
}
$script:User = Get-TargetUser
try {
  switch ($Mode) {
    'menu'     { Show-Menu }
    'diag'     { Run-Diag }
    'optimize' { Run-Optimize }
    'rollback' { Run-Rollback }
  }
} catch {
  Say ('Сбой набора: ' + $_.Exception.Message) 'Red'
  Say ($_.InvocationInfo.PositionMessage) 'DarkGray'
  Say ($_.ScriptStackTrace) 'DarkGray'
  $script:ExitCode = 2
}
exit $script:ExitCode
