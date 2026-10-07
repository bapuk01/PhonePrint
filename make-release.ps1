<#
  Сборка файлов для релиза (запускать на машине разработчика):
    dist\PhonePrint-<версия>.apk             — отдельный APK для телефона
    dist\PhonePrint-<версия>-windows.zip     — программа для ПК + установщик Ghostscript (работает без интернета)
  Версия берётся из android\app\build.gradle.kts. Перед запуском соберите APK (android\build.cmd).
  Установщик Ghostscript скачивается один раз в папку redist\ (в git не попадает).
#>
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot

$gradle = Get-Content (Join-Path $root 'android\app\build.gradle.kts') -Raw
if ($gradle -notmatch 'versionName = "([^"]+)"') { throw 'Не нашёл versionName в build.gradle.kts' }
$ver = $Matches[1]

$apk = Join-Path $root 'PhonePrint.apk'
if (-not (Test-Path $apk)) { throw 'Нет PhonePrint.apk — сначала соберите приложение (android\build.cmd).' }

# --- Ghostscript ---
$redist = Join-Path $root 'redist'
New-Item -ItemType Directory -Force $redist | Out-Null
$gsExe = Get-ChildItem $redist -Filter 'gs*w64.exe' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $gsExe) {
    Write-Host 'Скачиваю установщик Ghostscript...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/ArtifexSoftware/ghostpdl-downloads/releases/latest' -Headers @{ 'User-Agent' = 'PhonePrint-release' }
    $asset = @($rel.assets | Where-Object { $_.name -like 'gs*w64.exe' }) | Select-Object -First 1
    if (-not $asset) { throw 'В релизе Ghostscript нет установщика для Windows x64' }
    Invoke-WebRequest $asset.browser_download_url -OutFile (Join-Path $redist $asset.name) -UseBasicParsing
    $gsExe = Get-Item (Join-Path $redist $asset.name)
}
Write-Host "Ghostscript: $($gsExe.Name)"

# --- сборка ---
$dist  = Join-Path $root 'dist'
$stage = Join-Path $dist "stage\PhonePrint"
if (Test-Path (Join-Path $dist 'stage')) { Remove-Item (Join-Path $dist 'stage') -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($f in 'PhonePrint.ps1', 'PhonePrint.vbs', 'setup.cmd', 'setup.ps1', 'README.md', 'LICENSE', 'THIRD-PARTY.txt', 'PhonePrint.apk') {
    Copy-Item (Join-Path $root $f) $stage
}
Copy-Item (Join-Path $root 'web') (Join-Path $stage 'web') -Recurse
New-Item -ItemType Directory (Join-Path $stage 'redist') | Out-Null
Copy-Item $gsExe.FullName (Join-Path $stage 'redist')

$zip = Join-Path $dist "PhonePrint-$ver-windows.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal
Copy-Item $apk (Join-Path $dist "PhonePrint-$ver.apk") -Force
Remove-Item (Join-Path $dist 'stage') -Recurse -Force

Get-ChildItem $dist | ForEach-Object { '{0}  {1:N1} МБ' -f $_.Name, ($_.Length / 1MB) }
