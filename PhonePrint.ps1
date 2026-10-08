<#
  PhonePrint — печать с телефона на принтер, подключённый к этому ПК.

  Обычный запуск — PhonePrint.vbs (без окна, значок в трее).
  Вручную:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File PhonePrint.ps1
  Проверка без бумаги:  ... -File PhonePrint.ps1 -DryRun   (вместо печати кладёт PDF в %TEMP%\PhonePrint)
#>
param(
    [int]$Port = 8080,
    [string]$Printer = '',      # пусто = принтер Windows по умолчанию
    [switch]$DryRun,
    [switch]$LocalOnly          # слушать только localhost (для отладки)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$AppName        = 'PhonePrint'
$Root           = $PSScriptRoot
$WorkDir        = Join-Path $env:TEMP $AppName
$LogFile        = Join-Path $Root 'phoneprint.log'
$MaxUploadBytes = 200MB
New-Item -ItemType Directory -Force $WorkDir | Out-Null

# --- один экземпляр -----------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\$AppName", [ref]$createdNew)
if (-not $createdNew) {
    Start-Process "http://localhost:$Port/qr"
    exit
}

# --- утилиты ------------------------------------------------------------------
function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
}

# --- PIN-код ------------------------------------------------------------------
# Хранится только хэш (соль + SHA-256) в phoneprint.pin рядом со скриптом. Нет файла = PIN не задан.
$PinFile = Join-Path $Root 'phoneprint.pin'
$script:Pin   = $null     # @{ Salt; Hash } или $null
$script:Fails = @{}       # IP -> @{ Count; Until } — защита от подбора

function Get-PinHash([string]$salt, [string]$pin) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$salt$pin"))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Load-Pin {
    $script:Pin = $null
    try {
        if (Test-Path $PinFile) {
            $p = (Get-Content $PinFile -Raw).Trim().Split(':')
            if ($p.Count -eq 2) { $script:Pin = @{ Salt = $p[0]; Hash = $p[1] } }
        }
    } catch {}
}

function Save-Pin([string]$pin) {
    $salt = [Guid]::NewGuid().ToString('N')
    Set-Content -Path $PinFile -Value ("{0}:{1}" -f $salt, (Get-PinHash $salt $pin)) -Encoding ASCII
    $script:Fails = @{}
    Load-Pin
}

function Remove-Pin {
    Remove-Item $PinFile -Force -ErrorAction SilentlyContinue
    $script:Pin = $null
    $script:Fails = @{}
}

# 200 — пускаем, 401 — нужен (или неверный) PIN, 429 — слишком много неверных попыток
function Get-AuthStatus($req) {
    if (-not $script:Pin) { return 200 }
    $ip = "$($req.RemoteEndPoint.Address)"
    $f = $script:Fails[$ip]
    if ($f -and $f.Until -gt (Get-Date)) { return 429 }
    $given = Get-HeaderText $req 'X-Pin'
    if (-not $given) { return 401 }
    if ((Get-PinHash $script:Pin.Salt $given) -eq $script:Pin.Hash) {
        $script:Fails.Remove($ip)
        return 200
    }
    $count = 1 + $(if ($f) { $f.Count } else { 0 })
    $until = [DateTime]::MinValue
    if ($count -ge 5) {
        $until = (Get-Date).AddSeconds(60)
        $count = 0
        Write-Log "WARN неверный PIN с $ip — блокировка на 60 с"
    }
    $script:Fails[$ip] = @{ Count = $count; Until = $until }
    return 401
}

function Send-AuthError($ctx, [int]$status) {
    $msg = if ($status -eq 429) { 'Слишком много неверных попыток. Подождите минуту.' }
           elseif (Get-HeaderText $ctx.Request 'X-Pin') { 'Неверный PIN-код' }
           else { 'Нужен PIN-код' }
    Send-Json $ctx @{
        app = $AppName; pinRequired = $true; ok = $false; message = $msg
        error = $(if ($status -eq 429) { 'locked' } else { 'pin' })
    } $status
}

# Диалог задания PIN: 4–8 цифр, с подтверждением. Возвращает PIN или $null.
function Show-PinDialog {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "$AppName — PIN-код"
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.TopMost = $true
    $f.ClientSize = New-Object System.Drawing.Size(340, 210)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $mk = {
        param($text, $y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Left = 16; $l.Top = $y; $l.Width = 308; $l.Height = 20
        $f.Controls.Add($l)
    }.GetNewClosure()
    $mkBox = {
        param($y)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Left = 16; $t.Top = $y; $t.Width = 308; $t.MaxLength = 8; $t.UseSystemPasswordChar = $true
        $f.Controls.Add($t)
        $t
    }.GetNewClosure()

    & $mk 'PIN-код (4–8 цифр). Его нужно будет ввести на телефоне:' 12
    $t1 = & $mkBox 38
    & $mk 'Повторите PIN-код:' 76
    $t2 = & $mkBox 102

    $err = New-Object System.Windows.Forms.Label
    $err.Left = 16; $err.Top = 134; $err.Width = 308; $err.Height = 20
    $err.ForeColor = [System.Drawing.Color]::Firebrick
    $f.Controls.Add($err)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Сохранить'; $ok.Left = 130; $ok.Top = 164; $ok.Width = 95
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Отмена'; $cancel.Left = 229; $cancel.Top = 164; $cancel.Width = 95
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.AddRange(@($ok, $cancel))
    $f.AcceptButton = $ok; $f.CancelButton = $cancel

    $ok.add_Click({
        if ($t1.Text -notmatch '^\d{4,8}$') { $err.Text = 'PIN — от 4 до 8 цифр'; return }
        if ($t1.Text -ne $t2.Text)          { $err.Text = 'PIN-коды не совпадают'; return }
        $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
    }.GetNewClosure())

    try {
        if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $t1.Text }
        return $null
    } finally { $f.Dispose() }
}

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

$Gs       = Find-Ghostscript
$HasWord  = Test-Path 'Registry::HKEY_CLASSES_ROOT\Word.Application'
$HasExcel = Test-Path 'Registry::HKEY_CLASSES_ROOT\Excel.Application'
$History  = New-Object System.Collections.ArrayList

# IPv4-адрес этого ПК в локальной сети. Перебираем сетевые адаптеры и выбираем лучший: с основным шлюзом,
# из частного диапазона, физический (не VPN/виртуальный). Раньше брался только адаптер со шлюзом, и на ПК без
# шлюза/с нестандартной сетью показывался 127.0.0.1.
function Get-LanCandidates {
    $found = New-Object System.Collections.ArrayList
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.OperationalStatus -ne 'Up') { continue }
            if ($nic.NetworkInterfaceType -in 'Loopback', 'Tunnel') { continue }
            $props = $nic.GetIPProperties()
            $label = "$($nic.Name) $($nic.Description)"
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
                $ip = $ua.Address.ToString()
                if ($ip.StartsWith('127.') -or $ip.StartsWith('169.254.')) { continue }
                $score = 0
                if (@($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' }).Count) { $score += 100 }
                $o1 = [int]$ip.Split('.')[0]; $o2 = [int]$ip.Split('.')[1]
                if ($o1 -eq 10 -or ($o1 -eq 192 -and $o2 -eq 168) -or ($o1 -eq 172 -and $o2 -ge 16 -and $o2 -le 31)) { $score += 50 }
                if ($nic.NetworkInterfaceType -in 'Wireless80211', 'Ethernet', 'GigabitEthernet') { $score += 20 }
                if ($label -match 'vEthernet|VirtualBox|VMware|Hyper-V|Hamachi|TAP|VPN|Wintun|WireGuard|Tailscale|ZeroTier|Bluetooth|Docker|WSL|Loopback') { $score -= 150 }
                [void]$found.Add([pscustomobject]@{ Ip = $ip; Score = $score; Name = $nic.Name; Prefix = $ua.PrefixLength })
            }
        }
    } catch {}
    return @($found | Sort-Object Score -Descending)
}

function Get-LanIp {
    $all = @(Get-LanCandidates)
    if ($all.Count) { return $all[0].Ip }
    return '127.0.0.1'
}

# Остальные адреса ПК (кроме основного) — на случай, если телефон в другой сети/подсети, чем выбранный адаптер
function Get-OtherLanIps {
    $main = Get-LanIp
    return @(Get-LanCandidates | Where-Object { $_.Ip -ne $main } | ForEach-Object Ip)
}

function Get-AppUrl { "http://$(Get-LanIp):$Port" }

# Окно «Проверка сети»: что видит ПК и что чаще всего мешает телефону его найти
function Show-NetworkDiagnostics {
    $nl = [Environment]::NewLine
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("Порт: $Port")
    [void]$lines.Add('')
    [void]$lines.Add('Адреса этого ПК:')
    $cands = @(Get-LanCandidates)
    if (-not $cands.Count) { [void]$lines.Add('  нет рабочего IPv4-подключения') }
    foreach ($c in $cands) { [void]$lines.Add("  $($c.Ip)/$($c.Prefix)  — $($c.Name)") }
    [void]$lines.Add('')
    [void]$lines.Add('Телефон должен быть в той же подсети: первые три числа адреса совпадают')
    [void]$lines.Add('(например, у ПК 192.168.1.2 — у телефона 192.168.1.x). Адрес телефона:')
    [void]$lines.Add('Wi-Fi → ваша сеть → «Подробности» (или в приложении при ошибке поиска).')
    [void]$lines.Add('')
    try {
        $rule = @(Get-NetFirewallRule -DisplayName $AppName -ErrorAction Stop | Where-Object Enabled -eq 'True')
        if ($rule.Count) { [void]$lines.Add('Брандмауэр: правило «PhonePrint» есть.') }
        else { [void]$lines.Add('Брандмауэр: правило «PhonePrint» ОТКЛЮЧЕНО — запустите setup.cmd.') }
    } catch {
        [void]$lines.Add('Брандмауэр: правила «PhonePrint» НЕТ — запустите setup.cmd на этом ПК.')
    }
    try {
        $cat = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { "$($_.Name): $($_.NetworkCategory)" })
        if ($cat.Count) { [void]$lines.Add('Тип сети: ' + ($cat -join '; ')) }
    } catch {}
    [void]$lines.Add('Если стоит антивирус со своим брандмауэром (Kaspersky, ESET, Dr.Web и т.п.) — разрешите в нём порт TCP ' + $Port + '.')
    [void]$lines.Add('Если всё верно, а телефон не находит ПК: в роутере выключите «Изоляцию клиентов (AP isolation)»')
    [void]$lines.Add('и проверьте, что телефон не в гостевой Wi-Fi сети.')
    $ok = 'нет'
    try {
        $tc = New-Object System.Net.Sockets.TcpClient
        try { $tc.Connect((Get-LanIp), $Port); $ok = 'да' } finally { $tc.Close() }
    } catch {}
    [void]$lines.Add('')
    [void]$lines.Add("Сервер отвечает на $(Get-LanIp):$Port с самого ПК: $ok")
    [void][System.Windows.Forms.MessageBox]::Show(($lines -join $nl), "$AppName — проверка сети", 'OK', 'Information')
}

function Get-DefaultPrinter {
    (Get-CimInstance Win32_Printer -Filter 'Default=TRUE' | Select-Object -First 1).Name
}

function Get-TargetPrinter([string]$requested) {
    $all = @(Get-Printer | ForEach-Object Name)
    if ($requested -and $all -contains $requested) { return $requested }
    if ($Printer -and $all -contains $Printer) { return $Printer }
    return Get-DefaultPrinter
}

# --- двусторонняя печать ------------------------------------------------------
# Принтер «поддерживает» дуплекс, если его драйвер в PrintCapabilities заявляет двустороннюю печать.
# Результат кэшируется: опрос драйвера бывает небыстрым (особенно у сетевых принтеров).
$script:DuplexCache  = @{}
$script:PrintServer  = $null
try { Add-Type -AssemblyName System.Printing; $script:PrintServer = New-Object System.Printing.LocalPrintServer } catch {}

function Test-Duplex([string]$name) {
    if (-not $name -or -not $script:PrintServer) { return $false }
    $c = $script:DuplexCache[$name]
    if ($c -and ((Get-Date) - $c.At).TotalSeconds -lt 120) { return $c.Value }
    $ok = $false
    try {
        $bs = [string][char]92
        $server = $script:PrintServer; $queueName = $name; $remote = $null
        # Сетевой принтер вида (два обратных слэша)сервер(слэш)имя: очередь запрашиваем у компьютера, где он общий
        if ($name.StartsWith($bs + $bs)) {
            $parts = $name.Substring(2).Split([char[]]@(92), 2)
            $remote = New-Object System.Printing.PrintServer($bs + $bs + $parts[0])
            $server = $remote; $queueName = $parts[1]
        }
        try {
            $q = $server.GetPrintQueue($queueName)
            try { $ok = @($q.GetPrintCapabilities().DuplexingCapability) -contains [System.Printing.Duplexing]::TwoSidedLongEdge }
            finally { $q.Dispose() }
        } finally { if ($remote) { $remote.Dispose() } }
    } catch {}
    $script:DuplexCache[$name] = @{ Value = $ok; At = Get-Date }
    return $ok
}

# --- печать -------------------------------------------------------------------
function Invoke-Ghostscript([string[]]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $Gs, ($arguments -join ' ')
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(15 * 60 * 1000)) {
        try { $p.Kill() } catch {}
        throw 'Ghostscript не ответил за 15 минут.'
    }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        throw ('Ошибка Ghostscript: ' + ($errTask.Result + ' ' + $outTask.Result).Trim())
    }
}

function Print-Pdf([string]$pdf, [string]$printerName, [int]$copies, [string]$pages, [bool]$duplex = $false) {
    if (-not $Gs) { throw 'Не найден Ghostscript (ставится вместе с PDF24).' }
    $a = @('-dBATCH', '-dNOPAUSE', '-dSAFER', '-dNoCancel', '-dQUIET', '-dPDFFitPage')
    if ($DryRun) {
        $out = Join-Path $WorkDir ('dryrun_{0:HHmmss}_{1}.pdf' -f (Get-Date), (Get-Random -Maximum 9999))
        $a += @('-sDEVICE=pdfwrite', "`"-sOutputFile=$out`"")
    } else {
        $a += @('-sDEVICE=mswinpr2', "`"-sOutputFile=%printer%$printerName`"")
    }
    if ($pages) { $a += "-sPageList=$pages" }
    if ($duplex -and -not $DryRun) {
        # Двусторонняя печать по длинному краю. Каждая копия — отдельное задание, чтобы следующая копия
        # начиналась с чистого листа, а не на обороте последней страницы предыдущей.
        $a += @('-c', '"<</Duplex true /Tumble false>> setpagedevice"', '-f')
        1..$copies | ForEach-Object { Invoke-Ghostscript ($a + "`"$pdf`"") }
        return
    }
    # Один и тот же файл N раз = N копий одним заданием (с подбором по копиям)
    $a += @(1..$copies | ForEach-Object { "`"$pdf`"" })
    Invoke-Ghostscript $a
}

function Set-ImageOrientation($img) {
    if ($img.PropertyIdList -notcontains 0x0112) { return }
    $o = [int]$img.GetPropertyItem(0x0112).Value[0]
    $map = @{ 2 = 'RotateNoneFlipX'; 3 = 'Rotate180FlipNone'; 4 = 'Rotate180FlipX'; 5 = 'Rotate90FlipX'
              6 = 'Rotate90FlipNone'; 7 = 'Rotate270FlipX'; 8 = 'Rotate270FlipNone' }
    if ($map.ContainsKey($o)) { $img.RotateFlip($map[$o]) }
}

function Print-Image([string]$path, [string]$printerName, [int]$copies, [string]$docName) {
    $img = [System.Drawing.Image]::FromFile($path)
    try {
        Set-ImageOrientation $img
        $pd = New-Object System.Drawing.Printing.PrintDocument
        $pd.DocumentName = $docName
        if ($DryRun) {
            $pd.PrinterSettings.PrinterName   = 'Microsoft Print to PDF'
            $pd.PrinterSettings.PrintToFile   = $true
            $pd.PrinterSettings.PrintFileName = Join-Path $WorkDir ('dryrun_{0:HHmmss}_image.pdf' -f (Get-Date))
        } else {
            $pd.PrinterSettings.PrinterName = $printerName
        }
        if (-not $pd.PrinterSettings.IsValid) { throw "Принтер «$printerName» не найден." }
        $pd.PrinterSettings.Copies = [int16]$copies
        $pd.PrintController = New-Object System.Drawing.Printing.StandardPrintController   # без окна «Печать…»
        $pd.DefaultPageSettings.Landscape = ($img.Width -gt $img.Height)
        $pd.DefaultPageSettings.Margins   = New-Object System.Drawing.Printing.Margins(25, 25, 25, 25)
        $pd.add_PrintPage({
            param($s, $e)
            $area  = $e.MarginBounds
            $scale = [Math]::Min($area.Width / $img.Width, $area.Height / $img.Height)
            $w = $img.Width * $scale
            $h = $img.Height * $scale
            $x = $area.X - $e.PageSettings.HardMarginX + ($area.Width - $w) / 2
            $y = $area.Y - $e.PageSettings.HardMarginY + ($area.Height - $h) / 2
            $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $e.Graphics.DrawImage($img, [single]$x, [single]$y, [single]$w, [single]$h)
            $e.HasMorePages = $false
        })
        $pd.Print()
    } finally {
        $img.Dispose()
    }
}

function Convert-TextToUtf8Bom([string]$file) {
    $bytes  = [IO.File]::ReadAllBytes($file)
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try   { $text = $strict.GetString($bytes) }
    catch { $text = [Text.Encoding]::GetEncoding(1251).GetString($bytes) }
    $text = $text.TrimStart([char]0xFEFF)
    [IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($true)))
}

function Convert-WordToPdf([string]$src, [string]$pdf) {
    if (-not $HasWord) { throw 'Для этого формата нужен Microsoft Word.' }
    $word = $null; $doc = $null
    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $word.DisplayAlerts = 0
        $m = [Type]::Missing
        # Неверный пароль вместо пустого — чтобы защищённый файл дал ошибку, а не скрытый диалог
        $doc = $word.Documents.Open($src, $false, $true, $false, 'x-no-password', $m, $m, $m, $m, $m, 65001)
        $doc.ExportAsFixedFormat($pdf, 17)   # wdExportFormatPDF
    } finally {
        if ($doc)  { try { $doc.Close(0) } catch {} }
        if ($word) { try { $word.Quit() } catch {}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word) }
    }
}

function Convert-ExcelToPdf([string]$src, [string]$pdf) {
    if (-not $HasExcel) { throw 'Для этого формата нужен Microsoft Excel.' }
    $xl = $null; $wb = $null
    try {
        $xl = New-Object -ComObject Excel.Application
        $xl.Visible = $false
        $xl.DisplayAlerts = $false
        $wb = $xl.Workbooks.Open($src, 0, $true)
        $wb.ExportAsFixedFormat(0, $pdf)     # xlTypePDF
    } finally {
        if ($wb) { try { $wb.Close($false) } catch {} }
        if ($xl) { try { $xl.Quit() } catch {}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xl) }
    }
}

function Invoke-PrintJob([string]$file, [string]$ext, [string]$name, [string]$printerName, [int]$copies, [string]$pages, [bool]$duplex = $false) {
    if ($ext -eq 'pdf') {
        Print-Pdf $file $printerName $copies $pages $duplex
    } elseif ($ext -match '^(jpe?g|png|bmp|gif|tiff?)$') {
        Print-Image $file $printerName $copies $name
    } elseif ($ext -match '^(docx?|rtf|odt|txt)$') {
        if ($ext -eq 'txt') { Convert-TextToUtf8Bom $file }
        $pdf = "$file.pdf"
        try { Convert-WordToPdf $file $pdf; Print-Pdf $pdf $printerName $copies $pages $duplex }
        finally { Remove-Item $pdf -Force -ErrorAction SilentlyContinue }
    } elseif ($ext -match '^(xlsx?|csv|ods)$') {
        $pdf = "$file.pdf"
        try { Convert-ExcelToPdf $file $pdf; Print-Pdf $pdf $printerName $copies $pages $duplex }
        finally { Remove-Item $pdf -Force -ErrorAction SilentlyContinue }
    } elseif ($ext -match '^hei[cf]$') {
        throw 'Формат HEIC не поддерживается. На iPhone: Настройки → Камера → Форматы → «Наиболее совместимый».'
    } else {
        throw "Формат .$ext не поддерживается. Подходят PDF, фото (JPG/PNG), Word, Excel, TXT."
    }
}

# --- HTTP ---------------------------------------------------------------------
function Send-Bytes($ctx, [int]$status, [string]$contentType, [byte[]]$body) {
    $res = $ctx.Response
    $res.StatusCode = $status
    $res.ContentType = $contentType
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $body.Length
    $res.OutputStream.Write($body, 0, $body.Length)
    $res.Close()
}

function Send-Json($ctx, $obj, [int]$status = 200) {
    $json = ConvertTo-Json -InputObject $obj -Depth 5 -Compress
    Send-Bytes $ctx $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Get-HeaderText($req, [string]$name) {
    $v = $req.Headers[$name]
    if ($v) { return [Uri]::UnescapeDataString($v) }
    return ''
}

function Get-Info {
    $target = Get-TargetPrinter ''
    $status = ''
    $queue  = 0
    try { $status = "$((Get-Printer -Name $target).PrinterStatus)" } catch {}
    try { $queue  = @(Get-PrintJob -PrinterName $target).Count } catch {}
    $names = @(Get-Printer | Sort-Object Name | ForEach-Object Name)
    $duplexMap = @{}
    foreach ($n in $names) { $duplexMap[$n] = [bool](Test-Duplex $n) }
    @{
        app      = $AppName
        printer  = $target
        printers = $names
        duplex   = $duplexMap
        status   = $status
        queue    = $queue
        word     = $HasWord
        excel    = $HasExcel
        dryRun   = [bool]$DryRun
        pinRequired = [bool]$script:Pin
        history  = @($History)
    }
}

function Receive-PrintJob($ctx) {
    $req  = $ctx.Request
    $name = Get-HeaderText $req 'X-File-Name'
    if (-not $name) { $name = 'document' }
    $ext = [IO.Path]::GetExtension($name).TrimStart('.').ToLowerInvariant()
    if (-not $ext) {
        $byType = @{ 'application/pdf' = 'pdf'; 'image/jpeg' = 'jpg'; 'image/png' = 'png'; 'text/plain' = 'txt' }
        $ct = "$($req.ContentType)".Split(';')[0].Trim().ToLowerInvariant()
        if ($byType.ContainsKey($ct)) { $ext = $byType[$ct] }
    }

    $copies = 1
    [void][int]::TryParse("$($req.QueryString['copies'])", [ref]$copies)
    $copies = [Math]::Min([Math]::Max($copies, 1), 50)
    $pages = "$($req.QueryString['pages'])" -replace '\s', ''
    $printerName = Get-TargetPrinter (Get-HeaderText $req 'X-Printer')
    $duplex = "$($req.QueryString['duplex'])" -eq '1'
    $duplexSkipped = $false
    if ($duplex -and -not (Test-Duplex $printerName)) { $duplex = $false; $duplexSkipped = $true }

    $entry = [ordered]@{
        time = (Get-Date).ToString('HH:mm'); name = $name; printer = $printerName
        copies = $copies; pages = $pages; duplex = $duplex; ok = $false; message = ''
    }
    $file = Join-Path $WorkDir ('{0:yyyyMMdd_HHmmss}_{1}.{2}' -f (Get-Date), (Get-Random -Maximum 99999), $ext)
    try {
        if ($pages -and $pages -notmatch '^\d+(-\d+)?(,\d+(-\d+)?)*$') { throw 'Неверный диапазон страниц. Пример: 1-3,5' }
        if ($req.ContentLength64 -gt $MaxUploadBytes) { throw 'Файл слишком большой (больше 200 МБ).' }
        $fs = [IO.File]::Create($file)
        try { $req.InputStream.CopyTo($fs) } finally { $fs.Close() }
        if ((Get-Item $file).Length -eq 0) { throw 'Пустой файл.' }

        Invoke-PrintJob $file $ext $name $printerName $copies $pages $duplex
        $entry.ok = $true
        $entry.message = if ($DryRun) { "Пробный режим: PDF в $WorkDir" } else { 'Отправлено на печать' }
        if ($duplex) { $entry.message += ' (двусторонняя)' }
        if ($duplexSkipped) { $entry.message += ' (этот принтер не поддерживает двустороннюю печать — печать с одной стороны)' }
        Write-Log "OK   $name -> $printerName, копий: $copies, страницы: $(if ($pages) { $pages } else { 'все' })$(if ($duplex) { ', двусторонняя' })"
        Show-Balloon 'Печать' "$name → $printerName"
    } catch {
        $entry.message = $_.Exception.Message
        Write-Log "ERR  $name : $($entry.message)"
    } finally {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        [void]$History.Insert(0, $entry)
        while ($History.Count -gt 30) { $History.RemoveAt(30) }
    }
    Send-Json $ctx $entry
}

$QrPageTemplate = @'
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>PhonePrint — адрес для телефона</title>
<style>
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
       font-family:"Segoe UI",system-ui,sans-serif;background:#f4f3ef;color:#1d1d1b;text-align:center;padding:24px}
  h1{font-weight:600;font-size:26px;margin:0 0 24px}
  #qr{background:#fff;padding:18px;border-radius:16px;box-shadow:0 2px 16px rgba(0,0,0,.08)}
  .url{font:600 30px/1.2 Consolas,monospace;margin-top:24px;letter-spacing:.5px}
  p{color:#6b6a65;max-width:440px;line-height:1.5}
</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
</head><body>
<h1>Установка приложения на Android</h1>
<div id="qr"></div>
<div class="url">__URL__/app</div>
<p>Наведите камеру телефона на код или наберите адрес в браузере, скачайте и откройте файл PhonePrint.apk.
Android попросит разрешить установку из браузера — разрешите.</p>
<p>Без приложения тоже можно: просто откройте в браузере телефона <b>__URL__</b></p>
<p>Телефон должен быть подключён к той же сети (Wi-Fi роутера), что и этот компьютер.</p>
__OTHERS__
<script>
  if (window.QRCode) new QRCode(document.getElementById('qr'), {text:'__URL__/app', width:260, height:260});
  else document.getElementById('qr').textContent = 'QR-код не загрузился (нет интернета) — введите адрес вручную.';
</script>
</body></html>
'@

function Handle-Request($ctx) {
    $req  = $ctx.Request
    $path = $req.Url.AbsolutePath.ToLowerInvariant()
    try {
        if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            Send-Bytes $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $Root 'web\index.html')))
        } elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/qr') {
            $others = @(Get-OtherLanIps | ForEach-Object { "<b>http://${_}:$Port</b>" })
            $othersHtml = if ($others.Count) { '<p>Не открывается? У компьютера есть и другие адреса, попробуйте: ' + ($others -join ', ') + '</p>' } else { '' }
            $html = $QrPageTemplate.Replace('__URL__', (Get-AppUrl)).Replace('__OTHERS__', $othersHtml)
            Send-Bytes $ctx 200 'text/html; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($html))
        } elseif ($req.HttpMethod -eq 'GET' -and ($path -eq '/app' -or $path -eq '/app.apk')) {
            $apk = Join-Path $Root 'PhonePrint.apk'
            if (-not (Test-Path $apk)) { Send-Json $ctx @{ error = 'PhonePrint.apk ещё не собран' } 404; return }
            $ctx.Response.Headers['Content-Disposition'] = 'attachment; filename="PhonePrint.apk"'
            Send-Bytes $ctx 200 'application/vnd.android.package-archive' ([IO.File]::ReadAllBytes($apk))
        } elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/info') {
            $auth = Get-AuthStatus $req
            if ($auth -ne 200) { Send-AuthError $ctx $auth } else { Send-Json $ctx (Get-Info) }
        } elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/print') {
            $auth = Get-AuthStatus $req
            if ($auth -ne 200) { Send-AuthError $ctx $auth } else { Receive-PrintJob $ctx }
        } else {
            Send-Json $ctx @{ error = 'Not found' } 404
        }
    } catch {
        Write-Log "ERR  запрос $path : $($_.Exception.Message)"
        try { Send-Json $ctx @{ ok = $false; message = $_.Exception.Message } 500 } catch {}
    }
}

# --- запуск -------------------------------------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($(if ($LocalOnly) { "http://localhost:$Port/" } else { "http://+:$Port/" }))
try {
    $listener.Start()
} catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Не удалось открыть порт $Port.`n`nЗапустите один раз setup.cmd (он попросит права администратора).`n`n$($_.Exception.Message)",
        $AppName, 'OK', 'Error')
    exit 1
}
Load-Pin
Write-Log "Запущен: $(Get-AppUrl)$(if ($DryRun) { '  (пробный режим)' })$(if ($script:Pin) { '  (PIN включён)' })"

try   { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:WINDIR\System32\printui.exe") }
catch { $icon = [System.Drawing.SystemIcons]::Application }

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icon
$tray.Text = "$AppName  $(Get-AppUrl)"
$tray.Visible = $true

function Show-Balloon([string]$title, [string]$text) {
    try { $tray.ShowBalloonTip(3000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miAddr = $menu.Items.Add("Адрес: $(Get-AppUrl)")
$miAddr.Enabled = $false
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Установить приложение на телефон (QR-код)', $null, { Start-Process "http://localhost:$Port/qr" })
[void]$menu.Items.Add('Открыть страницу печати', $null, { Start-Process "http://localhost:$Port/" })
[void]$menu.Items.Add('Проверка сети (если телефон не находит ПК)', $null, { Show-NetworkDiagnostics })
[void]$menu.Items.Add('Журнал', $null, { if (Test-Path $LogFile) { Start-Process notepad.exe "`"$LogFile`"" } })
$miPinSet = $menu.Items.Add('Задать PIN-код…', $null, {
    $pin = Show-PinDialog
    if ($pin) {
        Save-Pin $pin
        Write-Log 'PIN-код задан'
        Show-Balloon 'PIN-код' 'Задан. Теперь его спросят на телефоне.'
    }
})
$miPinClear = $menu.Items.Add('Убрать PIN-код', $null, {
    Remove-Pin
    Write-Log 'PIN-код убран'
    Show-Balloon 'PIN-код' 'Убран. Печатать может любой в вашей сети.'
})
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Выход', $null, {
    $timer.Stop()
    $tray.Visible = $false
    try { $listener.Stop() } catch {}
    [System.Windows.Forms.Application]::Exit()
})
$menu.add_Opening({
    $url = Get-AppUrl
    $miAddr.Text = "Адрес: $url"
    $miPinSet.Text = if ($script:Pin) { 'Сменить PIN-код…' } else { 'Задать PIN-код…' }
    $miPinClear.Visible = [bool]$script:Pin
    $tray.Text = "$AppName  $url"
})
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ Start-Process "http://localhost:$Port/qr" })

# Запросы обрабатываются по таймеру в UI-потоке: так меню трея и COM (Word/Excel) живут в одном STA-потоке.
$script:pending = $listener.GetContextAsync()
$script:busy = $false
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.add_Tick({
    if ($script:busy -or -not $script:pending.IsCompleted) { return }
    $script:busy = $true
    try {
        $ctx = $null
        try { $ctx = $script:pending.Result } catch {}
        if ($listener.IsListening) { $script:pending = $listener.GetContextAsync() }
        if ($ctx) { Handle-Request $ctx }
    } catch {
        Write-Log "ERR  цикл: $($_.Exception.Message)"
    } finally {
        $script:busy = $false
    }
})
$timer.Start()

Show-Balloon $AppName "Работает. Откройте на телефоне $(Get-AppUrl)"
[System.Windows.Forms.Application]::Run()

# --- выход --------------------------------------------------------------------
try { $listener.Close() } catch {}
$tray.Dispose()
Write-Log 'Остановлен'
$mutex.ReleaseMutex()
