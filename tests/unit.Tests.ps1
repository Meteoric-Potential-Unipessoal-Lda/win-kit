# Модульные тесты win-kit (Pester 5). Загружают функции из winkit.ps1 без запуска меню.
BeforeAll {
  $script:KitRoot = Split-Path -Parent $PSScriptRoot
  $txt = [IO.File]::ReadAllText((Join-Path $script:KitRoot 'winkit.ps1'))
  $mark = '# ' + ('=' * 64) + ' ЗАПУСК'
  $engine = $txt.Substring(0, $txt.LastIndexOf($mark)).TrimStart([char]0xFEFF)
  $WinKitRoot = $script:KitRoot
  . ([ScriptBlock]::Create($engine))
  $script:Root = $script:KitRoot
  $script:User = [pscustomobject]@{ Sid = 'S-1-5-21-1-2-3-1001'; Name = 'PC\test'; Profile = $env:TEMP; Source = 'current'; ShortName = 'test' }
  $script:Master = Get-MasterConfig
}

Describe 'Fmt-Size' {
  It 'показывает КБ для маленьких размеров' { Fmt-Size 0 | Should -Be '0 КБ'; Fmt-Size 1 | Should -Match '^1 КБ$'; Fmt-Size 5000 | Should -Match '^5 КБ$' }
  It 'показывает МБ и ГБ' { Fmt-Size (5MB) | Should -Match 'МБ$'; Fmt-Size (3GB) | Should -Match 'ГБ$' }
  It 'неизвестный размер — ?' { Fmt-Size $null | Should -Be '?' }
}

Describe 'Коды синих экранов' {
  It 'достаёт код из английского текста' { Get-BugcheckCode 'The computer has rebooted from a bugcheck. The bugcheck was: 0x0000009f (0x0000000000000003, 0xffff).' | Should -Be '0x0000009F' }
  It 'достаёт код из русского текста' { Get-BugcheckCode 'Компьютер был перезагружен после критической ошибки. Код ошибки: 0x00000124 (0x0, 0x1).' | Should -Be '0x00000124' }
  It 'короткий код дополняется нулями' { Get-BugcheckCode 'bugcheck 0xd1' | Should -Be '0x000000D1' }
  It 'без кода — пусто' { Get-BugcheckCode 'нет кода' | Should -BeNullOrEmpty }
  It 'у частых кодов есть объяснение' { foreach ($c in @('0x0000009F', '0x00000124', '0x000000D1', '0x00000116')) { $script:BugcheckInfo[$c] | Should -Not -BeNullOrEmpty } }
}

Describe 'hosts: перенаправления' {
  It 'находит перенаправление сайта на чужой IP' {
    $r = @((Get-HostsHijack @('1.2.3.4 www.mybank.com', '127.0.0.1 ads.example.com', '0.0.0.0 tracker.net', '192.168.1.5 nas', '10.0.0.2 printer.local', '# 5.6.7.8 commented.com', '5.6.7.8 a.com b.org # x')))
    @($r | ForEach-Object { $_.Host }) | Should -Be @('www.mybank.com', 'a.com', 'b.org')
  }
}

Describe 'Белый список реестра' {
  It 'все ключи из tweaks.tsv разрешены' {
    foreach ($r in (Read-Tsv 'tweaks.tsv')) {
      $full = $(if ($r.scope -eq 'user') { 'Registry::HKEY_USERS\S-1-5-21-1\' + $r.path } else { 'Registry::HKEY_LOCAL_MACHINE\' + $r.path })
      Test-RegWriteAllowed $full $r.name | Should -BeTrue -Because $r.path
    }
  }
  It 'политики браузеров разрешены, Run — нет' {
    Test-RegWriteAllowed 'Registry::HKEY_LOCAL_MACHINE\Software\Policies\Google\Chrome\ExtensionInstallForcelist' '1' | Should -BeTrue
    Test-RegWriteAllowed 'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run' 'x' | Should -BeFalse
    Test-RegWriteAllowed 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\WinDefend' 'Start' | Should -BeFalse
  }
}

Describe 'Списки data\*.tsv' {
  It '<_> — число столбцов и регулярные выражения' -ForEach @('startup.tsv', 'pup.tsv', 'tweaks.tsv', 'apps.tsv') {
    $p = Join-Path $script:KitRoot ('data\' + $_)
    $lines = @(Get-Content -LiteralPath $p -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
    $n = @($lines[0].TrimStart([char]0xFEFF) -split "`t").Count
    foreach ($l in $lines[1..($lines.Count - 1)]) { @($l -split "`t").Count | Should -BeLessOrEqual $n -Because $l }
    foreach ($r in (Read-Tsv $_)) { if ($r.PSObject.Properties['match'] -and $r.match) { { [void][regex]::new($r.match) } | Should -Not -Throw -Because $r.match } }
  }
  It 'уровни и типы допустимые' {
    foreach ($r in (Read-Tsv 'startup.tsv')) { @('auto', 'base', 'ask', 'keep') | Should -Contain $r.level }
    foreach ($r in (Read-Tsv 'tweaks.tsv')) { @('auto', 'base', 'ask') | Should -Contain $r.level; @('set', 'fix', 'with') | Should -Contain $r.mode; @('DWord', 'String', 'delete') | Should -Contain $r.type }
    foreach ($r in (Read-Tsv 'apps.tsv')) { @('auto', 'base', 'ask', 'keep') | Should -Contain $r.level }
    foreach ($r in (Read-Tsv 'pup.tsv')) { @('remote', 'pup', 'trial') | Should -Contain $r.kind }
  }
  It 'AnyDesk никогда не попадает в план' { 'AnyDesk | "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"' | Should -Match $script:HardProtect }
}

Describe 'Языки (data\lang.tsv)' {
  BeforeAll { $script:LangRows = @(Get-Content -LiteralPath (Join-Path $script:KitRoot 'data\lang.tsv') -Encoding UTF8 | Select-Object -Skip 1 | Where-Object { $_ }) }
  It 'в каждой строке 4 перевода и одинаковые {0}' {
    foreach ($l in $script:LangRows) {
      $c = $l -split "`t"; $c.Count | Should -Be 4 -Because $l
      $ph = ([regex]::Matches($c[0], '\{\d[^}]*\}') | ForEach-Object { $_.Value } | Sort-Object) -join ','
      foreach ($x in $c[1..3]) { $x | Should -Not -BeNullOrEmpty; (([regex]::Matches($x, '\{\d[^}]*\}') | ForEach-Object { $_.Value } | Sort-Object) -join ',') | Should -Be $ph -Because $x }
    }
  }
  It 'нет повторов' { $k = @($script:LangRows | ForEach-Object { ($_ -split "`t")[0] }); ($k | Select-Object -Unique).Count | Should -Be $k.Count }
  It 'T переводит и возвращает русский без перевода' {
    Set-Lang 'pt'; T 'Корзина' | Should -Be 'Reciclagem'; T 'нет такой строки' | Should -Be 'нет такой строки'
    Set-Lang 'en'; T 'Отчёт об обслуживании компьютера' | Should -Be 'Computer service report'
    Set-Lang 'ru'; T 'Корзина' | Should -Be 'Корзина'
  }
}

Describe 'Версии и обновление' {
  It 'сравнивает версии' {
    Compare-KitVersion '0.5' '0.5.0' | Should -Be 0
    Compare-KitVersion '0.5.1' '0.5' | Should -Be 1
    Compare-KitVersion '0.4.1' '0.5' | Should -Be -1
    Compare-KitVersion '1.0' '0.9.9' | Should -Be 1
  }
  It 'без update_url проверка не идёт' { $script:Master = [pscustomobject]@{ update_url = '' }; Get-KitUpdate | Should -BeNullOrEmpty; $script:Master = Get-MasterConfig }
}

Describe 'Наборы галочек' {
  BeforeAll {
    function New-T($kind, $title, $level, $id) { $it = New-PlanItem 'x' $kind $title '' $level ([pscustomobject]@{ Id = $id }) $null; return $it }
  }
  It 'игровой не трогает Steam и запись игр, удаление всегда вручную' {
    $plan = @((New-T 'startup' 'Steam' 'auto' ''), (New-T 'startup' 'Spotify' 'auto' ''), (New-T 'tweak' 'GameDVR' 'base' 'gamedvr'), (New-T 'uninstall' 'CCleaner' 'ask' ''), (New-T 'tweak' 'Виджеты' 'ask' 'widgets'))
    Set-PlanPreset $plan 'gaming'
    @($plan | Where-Object Checked | ForEach-Object Title) | Should -Be @('Spotify')
    Set-PlanPreset $plan 'weak'
    @($plan | Where-Object Checked | ForEach-Object Title) | Should -Be @('Steam', 'Spotify', 'GameDVR', 'Виджеты')
    Set-PlanPreset $plan 'recommended'
    @($plan | Where-Object Checked | ForEach-Object Title) | Should -Be @('Steam', 'Spotify')
  }
  It 'офис оставляет Teams и Zoom' {
    $plan = @((New-T 'startup' 'Microsoft Teams' 'base' ''), (New-T 'startup' 'Zoom' 'auto' ''), (New-T 'startup' 'Discord' 'auto' ''))
    Set-PlanPreset $plan 'office'
    @($plan | Where-Object Checked | ForEach-Object Title) | Should -Be @('Discord')
  }
}

Describe 'Отчёт клиенту' {
  It 'HTML собирается на всех языках, без «сырых» данных мастера' {
    foreach ($l in @('ru', 'uk', 'en', 'pt')) {
      Set-Lang $l
      $d = [ordered]@{ created = '2026-11-09T10:00:00'; stage = 'after-reboot'; lang = $l; kit = '0.5'; pcId = 'abcd1234'
        pc = [ordered]@{ model = 'ASUS TUF <Gaming>'; os = 'Windows 11 Home 25H2'; build = '26200'; cpu = 'Ryzen 5'; ram = 16; win11 = $true; activation = 'активирована' }
        master = [ordered]@{ name = 'Андрюха'; contacts = @([ordered]@{ k = 'Telegram'; v = '@master' }); logo = '' }
        before = [ordered]@{ FreeGB = 8.5; StartupEnabled = 14; BootMs = 98000; RamUsedPct = 71 }
        after = [ordered]@{ FreeGB = 31.2; StartupEnabled = 6; BootMs = 41000; RamIdlePct = 38 }
        done = @([ordered]@{ cat = 'Автозагрузка'; title = 'Discord'; kind = 'startup' }, [ordered]@{ cat = 'Очистка'; title = (T 'Корзина'); kind = 'clean' })
        freed = 23GB; disk = [ordered]@{ type = 'SSD'; wear = 3; temp = 41; model = 'Micron'; health = 'Healthy' }; battery = @(37)
        bsod = @([ordered]@{ code = '0x0000009F'; count = 2; meaning = 'драйвер' }); av = 'Защитник Windows'; threats = 0; problems = @('Тест')
        recs = @((T 'Перезагружайте компьютер хотя бы раз в неделю.')); history = @([ordered]@{ time = '2026-10-01T10:00:00'; kind = 'optimize' }, [ordered]@{ time = '2026-11-09T10:00:00'; kind = 'postcheck' }) }
      $h = New-ClientReportHtml $d
      $h | Should -Match ('<html lang="' + $l + '"')
      $h | Should -Match 'ASUS TUF &lt;Gaming&gt;'
      $h | Should -Match '@master'
      $h | Should -Match '31,2|31\.2'
      $h | Should -Not -Match '<script'
    }
    Set-Lang 'ru'
  }
}

Describe 'Только посмотреть' {
  It 'описывает пункты и ничего не меняет' {
    $script:Log = New-Object System.Collections.ArrayList
    $it = New-PlanItem 'tweak' 'tweak' 'Рекламный ID' '' 'auto' ([pscustomobject]@{ Keys = @([pscustomobject]@{ Done = $false; Type = 'DWord'; Name = 'Enabled'; Value = '0' }) }) $null
    $script:DryRun = $true
    Invoke-Plan @($it)
    $script:DryRun = $false
    $it.Result | Should -Be 'проверено'
    ($script:Log -join "`n") | Should -Match 'Enabled = 0'
  }
}
