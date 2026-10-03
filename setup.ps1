<#
  Одноразовая настройка PhonePrint (нужны права администратора — окно UAC появится само):
    - разрешает программе слушать порт (netsh http urlacl);
    - открывает порт в брандмауэре только для локальной сети;
    - добавляет PhonePrint в автозагрузку и запускает его.
  Удаление:  setup.cmd -Uninstall
#>
param(
    [int]$Port = 8080,
    [switch]$Uninstall,
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
    }
    Start-Sleep -Seconds 2
    exit 0
} catch {
    Write-Host $_ -ForegroundColor Red
    Read-Host 'Нажмите Enter'
    exit 1
}
