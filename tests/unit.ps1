# Модульные тесты (Pester 5) и проверка кода (PSScriptAnalyzer) — для GitHub Actions
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' })) { Install-Module Pester -MinimumVersion 5.5 -Force -SkipPublisherCheck -Scope CurrentUser }
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { Install-Module PSScriptAnalyzer -Force -Scope CurrentUser }
Import-Module Pester -MinimumVersion 5.5
$cfg = New-PesterConfiguration
$cfg.Run.Path = (Join-Path $root 'tests\unit.Tests.ps1')
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$res = Invoke-Pester -Configuration $cfg
$bad = 0
if ($res.FailedCount -gt 0) { Write-Host ("Pester: провалено {0}" -f $res.FailedCount) -ForegroundColor Red; $bad++ }
Import-Module PSScriptAnalyzer
$an = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'winkit.ps1') -Severity Error, Warning -ExcludeRule PSAvoidUsingWriteHost, PSUseShouldProcessForStateChangingFunctions, PSUseApprovedVerbs, PSUseSingularNouns, PSAvoidGlobalVars, PSUseDeclaredVarsMoreThanAssignments, PSAvoidUsingPositionalParameters, PSUseBOMForUnicodeEncodedFile, PSReviewUnusedParameter, PSAvoidUsingEmptyCatchBlock, PSUseOutputTypeCorrectly, PSAvoidDefaultValueSwitchParameter, PSPossibleIncorrectUsageOfAssignmentOperator, PSUseCmdletCorrectly)
$err = @($an | Where-Object { $_.Severity -eq 'Error' })
Write-Host ("ScriptAnalyzer: ошибок {0}, предупреждений {1}" -f $err.Count, ($an.Count - $err.Count))
foreach ($x in @($an | Select-Object -First 60)) { Write-Host ('  [{0}] {1}:{2} {3}' -f $x.Severity, $x.RuleName, $x.Line, $x.Message) }
if ($err.Count) { $bad++ }
if ($bad) { exit 1 }
Write-Host 'UNIT OK' -ForegroundColor Green
