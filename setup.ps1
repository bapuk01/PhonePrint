<#
  Одноразовая настройка PhonePrint (нужны права администратора — окно UAC появится само):
    - разрешает программе слушать порт (netsh http urlacl);
    - открывает порт в брандмауэре только для локальной сети;
    - добавляет PhonePrint в автозагрузку и запускает его;
    - если на ПК нет Ghostscript (нужен для печати PDF), скачивает и тихо устанавливает его
      с официального сайта разработчиков (Artifex). Отключить: setup.cmd -NoGhostscript
  Удаление:  setup.cmd -Uninstall
#>
param(
    [int]$Port = 8080,
    [switch]$Uninstall,
    [switch]$NoGhostscript,
    [string]$UserSid = '',
    [string]$StartupDir = '',
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$ruleName = 'PhonePrint'
$url      = "http://+:$Port/"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $Elevated) {
    # Обычный пользователь: запоминаем его SID и папку автозагрузки, поднимаем права
    $sid     = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $startup = [Environment]::GetFolderPath('Startup')
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-Elevated', '-Port', $Port, '-UserSid', $sid, '-StartupDir', "`"$startup`"")
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($NoGhostscript) { $argList += '-NoGhostscript' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Host 'Настройка не завершена.' -ForegroundColor Red; exit 1 }
    if (-not $Uninstall) {
        Start-Process wscript.exe "`"$PSScriptRoot\PhonePrint.vbs`""
        Write-Host 'Готово. PhonePrint запущен — значок принтера в трее.' -ForegroundColor Green
    }
    exit 0
}

if (-not $isAdmin) { Write-Host 'Нужны права администратора.'; exit 1 }

$lnk = Join-Path $StartupDir 'PhonePrint.lnk'

# --- Ghostscript --------------------------------------------------------------
function Find-Ghostscript {
    $candidates = @(
        "$env:ProgramFiles\PDF24\gs\bin\gswin64c.exe",
        "${env:ProgramFiles(x86)}\PDF24\gs\bin\gswinc.exe"
    )
    $candidates += @(Get-ChildItem "$env:ProgramFiles\gs\gs*\bin\gswin64c.exe" -ErrorAction SilentlyContinue |
                     Sort-Object FullName -Descending | ForEach-Object FullName)
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# Ставит Ghostscript, если его нет. Ошибка здесь не должна ломать остальную настройку.
# Сначала берёт установщик из папки redist (он лежит в архиве PhonePrint-...-windows.zip — работает без интернета),
# если его нет — скачивает последний с официального сайта.
function Install-Ghostscript {
    $existing = Find-Ghostscript
    if ($existing) { Write-Host "Ghostscript уже установлен: $existing"; return }

    $installer = $null; $downloaded = $false
    $local = Get-ChildItem (Join-Path $PSScriptRoot 'redist') -Filter 'gs*w64.exe' -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1
    try {
        if ($local) {
            $installer = $local.FullName
            Write-Host "Ghostscript не найден - ставлю из комплекта ($($local.Name))..."
        } else {
            Write-Host 'Ghostscript не найден - скачиваю с официального сайта (около 65 МБ)...'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $installer = Join-Path $env:TEMP 'ghostscript-setup.exe'
            $downloaded = $true
            $rel = Invoke-RestMethod 'https://api.github.com/repos/ArtifexSoftware/ghostpdl-downloads/releases/latest' `
                -Headers @{ 'User-Agent' = 'PhonePrint-setup' } -TimeoutSec 30
            $asset = @($rel.assets | Where-Object { $_.name -like 'gs*w64.exe' }) | Select-Object -First 1
            if (-not $asset) { throw 'в релизе нет установщика для Windows x64' }
            Invoke-WebRequest $asset.browser_download_url -OutFile $installer -UseBasicParsing -TimeoutSec 900
            Write-Host "Устанавливаю $($asset.name)..."
        }
        $p = Start-Process $installer -ArgumentList '/S' -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "установщик завершился с кодом $($p.ExitCode)" }
    } catch {
        Write-Host "Не удалось установить Ghostscript автоматически: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'Установите его вручную: https://ghostscript.com/releases/gsdnld.html (или PDF24 Creator). Без него PDF не печатаются.' -ForegroundColor Yellow
        return
    } finally {
        if ($downloaded -and $installer) { Remove-Item $installer -Force -ErrorAction SilentlyContinue }
    }
    $found = Find-Ghostscript
    if ($found) { Write-Host "Ghostscript установлен: $found" -ForegroundColor Green }
    else { Write-Host 'Установщик отработал, но Ghostscript не найден - проверьте установку вручную.' -ForegroundColor Yellow }
}


try {
    netsh http delete urlacl url=$url 2>&1 | Out-Null
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

    if ($Uninstall) {
        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        Write-Host 'PhonePrint удалён из автозагрузки, порт закрыт.'
    } else {
        $out = netsh http add urlacl url=$url "sddl=D:(A;;GX;;;$UserSid)"
        if ($LASTEXITCODE -ne 0) { throw "netsh: $out" }

        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
            -LocalPort $Port -RemoteAddress LocalSubnet -Profile Any | Out-Null

        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = "$env:WINDIR\System32\wscript.exe"
        $s.Arguments        = "`"$PSScriptRoot\PhonePrint.vbs`""
        $s.WorkingDirectory = $PSScriptRoot
        $s.IconLocation     = "$env:WINDIR\System32\printui.exe,0"
        $s.Save()
        Write-Host 'Порт открыт, автозагрузка добавлена.'
        if (-not $NoGhostscript) { Install-Ghostscript }
    }
    Start-Sleep -Seconds 3
    exit 0
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Нажмите Enter'
    exit 1
}
