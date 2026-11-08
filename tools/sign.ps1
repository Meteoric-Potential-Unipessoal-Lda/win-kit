# Подпись winkit.ps1 сертификатом для подписи кода (Authenticode).
# Нужен свой сертификат «Code Signing» (покупается у центра сертификации) — в хранилище «Личное» или файл .pfx.
# Самоподписанный сертификат доверия на чужих ПК не даёт — для клиентов он бесполезен.
# Подписывать ПОСЛЕ всех правок: любое изменение файла делает подпись недействительной.
param([string]$Pfx = '', [string]$Thumbprint = '', [string]$TimestampServer = 'http://timestamp.digicert.com')
$root = Split-Path -Parent $PSScriptRoot
$cert = $null
if ($Pfx) { $cert = Get-PfxCertificate -FilePath $Pfx }
elseif ($Thumbprint) { $cert = Get-Item -LiteralPath ("Cert:\CurrentUser\My\" + $Thumbprint) }
else { $cert = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Sort-Object NotAfter -Descending)[0] }
if (-not $cert) { Write-Host 'Сертификат для подписи кода не найден.' -ForegroundColor Red; exit 1 }
$r = Set-AuthenticodeSignature -FilePath (Join-Path $root 'winkit.ps1') -Certificate $cert -TimestampServer $TimestampServer -HashAlgorithm SHA256
Write-Host ('Подпись: ' + $r.Status + ' — ' + $cert.Subject)
if ($r.Status -ne 'Valid') { exit 1 }
