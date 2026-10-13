#!/usr/bin/env python3
"""
PhonePrint для Raspberry Pi / Linux с CUPS.

Тот же HTTP API, что у Windows-версии (PhonePrint.ps1), поэтому приложение и веб-страница работают без изменений:
  GET  /               веб-страница печати (web/index.html)
  GET  /qr             страница с адресом для установки приложения
  GET  /app            скачать PhonePrint.apk
  GET  /api/info       принтеры, статус, очередь, история (нужен PIN, если задан)
  POST /api/print      печать: тело — байты файла; ?copies=N&pages=1-3,5&duplex=1;
                       заголовки X-File-Name, X-Printer (URL-encoded), X-Pin

Печать идёт через CUPS (lp). PDF и фото CUPS печатает сам, Word/Excel/ODT/RTF конвертируются через LibreOffice,
текст (txt) отдаётся CUPS напрямую. Только стандартная библиотека Python (для фото нужен python3-pil).

Запуск вручную:  python3 phoneprint_server.py [--port 8080] [--dry-run]
PIN-код:         python3 phoneprint_server.py --set-pin   |   --clear-pin
"""
import argparse
import getpass
import hashlib
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

APP_NAME = "PhonePrint"
APP_DIR = Path(__file__).resolve().parent
MAX_UPLOAD = 200 * 1024 * 1024
HISTORY_MAX = 30

DATA_DIR = Path(os.environ.get("PHONEPRINT_DATA", "/var/lib/phoneprint"))
PIN_FILE = DATA_DIR / "pin"
LOG_FILE = DATA_DIR / "phoneprint.log"
FIXED_PRINTER = os.environ.get("PHONEPRINT_PRINTER", "").strip()   # пусто = принтер CUPS по умолчанию / первый

DRY_RUN = False
JOB_LOCK = threading.Lock()          # печать и конвертация — по одному заданию, Pi не резиновый
HISTORY = deque(maxlen=HISTORY_MAX)
HISTORY_LOCK = threading.Lock()

IMAGE_EXT = {"jpg", "jpeg", "png", "bmp", "gif", "tif", "tiff", "webp"}
WORD_EXT = {"doc", "docx", "rtf", "odt"}
EXCEL_EXT = {"xls", "xlsx", "csv", "ods"}
SOFFICE = shutil.which("soffice") or shutil.which("libreoffice")


# ------------------------------------------------------------------ утилиты

def log(msg: str) -> None:
    line = "{}  {}".format(time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError:
        return 127, "не найдена команда: " + cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "команда не ответила за {} с".format(timeout)


def lan_ip() -> str:
    """IP-адрес этого устройства в локальной сети (без отправки пакетов)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        try:
            out = subprocess.run(["hostname", "-I"], capture_output=True, text=True).stdout.split()
            return out[0] if out else "127.0.0.1"
        except OSError:
            return "127.0.0.1"


# ------------------------------------------------------------------ принтеры (CUPS)

def list_printers():
    rc, out = run(["lpstat", "-p"])
    names = []
    for line in out.splitlines():
        m = re.match(r"^printer (\S+) ", line)
        if m:
            names.append(m.group(1))
    return sorted(names)


def default_printer(printers=None):
    printers = printers if printers is not None else list_printers()
    if FIXED_PRINTER and FIXED_PRINTER in printers:
        return FIXED_PRINTER
    rc, out = run(["lpstat", "-d"])
    m = re.search(r"destination:\s*(\S+)", out)
    if m and m.group(1) in printers:
        return m.group(1)
    return printers[0] if printers else ""


def target_printer(requested: str, printers=None) -> str:
    printers = printers if printers is not None else list_printers()
    if requested and requested in printers:
        return requested
    return default_printer(printers)


def printer_status(name: str) -> str:
    if not name:
        return "Нет принтера"
    rc, out = run(["lpstat", "-p", name])
    if "disabled" in out:
        return "Отключён"
    return "Normal"


def queue_length(name: str) -> int:
    if not name:
        return 0
    rc, out = run(["lpstat", "-o", name])
    return len([l for l in out.splitlines() if l.strip()])


_duplex_cache = {}


def duplex_option(name: str):
    """Как включить двустороннюю печать у принтера: ('Duplex', 'DuplexNoTumble') / ('sides', 'two-sided-long-edge') / None.
    Берём из опций драйвера CUPS (lpoptions -l); кэш на минуту."""
    now = time.time()
    c = _duplex_cache.get(name)
    if c and now - c[0] < 60:
        return c[1]
    result = None
    rc, out = run(["lpoptions", "-p", name, "-l"])
    for line in out.splitlines():
        m = re.match(r"^([^/\s]+)/[^:]*:\s*(.*)$", line)
        if not m:
            continue
        key, values = m.group(1), m.group(2).replace("*", "").split()
        if "two-sided-long-edge" in values and key.lower() == "sides":
            result = ("sides", "two-sided-long-edge")
            break
        if "DuplexNoTumble" in values:
            result = (key, "DuplexNoTumble")
            break
    _duplex_cache[name] = (now, result)
    return result


# ------------------------------------------------------------------ PIN-код

_pin_cache = {"mtime": None, "value": None}
_fails = {}                      # ip -> [счётчик, до_какого_времени_блок]
_fails_lock = threading.Lock()


def pin_hash(salt: str, pin: str) -> str:
    return hashlib.sha256((salt + pin).encode("utf-8")).hexdigest()


def load_pin():
    """(salt, hash) или None. Формат файла такой же, как у Windows-версии: salt:hash."""
    try:
        mtime = PIN_FILE.stat().st_mtime
    except OSError:
        _pin_cache.update(mtime=None, value=None)
        return None
    if _pin_cache["mtime"] != mtime:
        try:
            parts = PIN_FILE.read_text(encoding="ascii").strip().split(":")
            _pin_cache.update(mtime=mtime, value=(parts[0], parts[1]) if len(parts) == 2 else None)
        except (OSError, UnicodeDecodeError):
            _pin_cache.update(mtime=mtime, value=None)
    return _pin_cache["value"]


def save_pin(pin: str) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    salt = secrets.token_hex(16)
    tmp = PIN_FILE.with_suffix(".tmp")
    tmp.write_text("{}:{}".format(salt, pin_hash(salt, pin)), encoding="ascii")
    os.chmod(tmp, 0o644)             # там только хэш
    os.replace(tmp, PIN_FILE)


def auth_status(handler) -> int:
    """200 — пускаем, 401 — нужен (или неверный) PIN, 429 — слишком много неверных попыток."""
    pin = load_pin()
    if pin is None:
        return 200
    ip = handler.client_address[0]
    now = time.time()
    with _fails_lock:
        f = _fails.get(ip)
        if f and f[1] > now:
            return 429
    given = urllib.parse.unquote(handler.headers.get("X-Pin", ""))
    if not given:
        return 401
    if secrets.compare_digest(pin_hash(pin[0], given), pin[1]):
        with _fails_lock:
            _fails.pop(ip, None)
        return 200
    with _fails_lock:
        count = (f[0] if f else 0) + 1
        until = 0
        if count >= 5:
            until, count = now + 60, 0
            log("WARN неверный PIN с {} — блокировка на 60 с".format(ip))
        _fails[ip] = [count, until]
    return 401


def cli_set_pin() -> int:
    pin = getpass.getpass("Новый PIN-код (4–8 цифр): ")
    if not re.fullmatch(r"\d{4,8}", pin):
        print("PIN — от 4 до 8 цифр", file=sys.stderr)
        return 1
    if getpass.getpass("Повторите PIN-код: ") != pin:
        print("PIN-коды не совпадают", file=sys.stderr)
        return 1
    try:
        save_pin(pin)
    except OSError as e:
        print("Не удалось записать {} ({}). Запустите через sudo.".format(PIN_FILE, e), file=sys.stderr)
        return 1
    print("PIN-код задан.")
    return 0


def cli_clear_pin() -> int:
    try:
        PIN_FILE.unlink()
    except FileNotFoundError:
        pass
    except OSError as e:
        print("Не удалось удалить {} ({}). Запустите через sudo.".format(PIN_FILE, e), file=sys.stderr)
        return 1
    print("PIN-код убран.")
    return 0


# ------------------------------------------------------------------ печать

def convert_to_pdf(src: Path, outdir: Path) -> Path:
    if not SOFFICE:
        raise RuntimeError("На этом устройстве не установлен LibreOffice — Word/Excel не напечатать. "
                           "Пересохраните файл в PDF на телефоне.")
    profile = DATA_DIR / "lo-profile"
    cmd = [SOFFICE, "--headless", "--norestore", "-env:UserInstallation=file://" + str(profile),
           "--convert-to", "pdf", "--outdir", str(outdir), str(src)]
    rc, out = run(cmd, timeout=240)
    pdf = outdir / (src.stem + ".pdf")
    if rc != 0 or not pdf.exists():
        raise RuntimeError("Не удалось преобразовать в PDF: " + out.strip()[-200:])
    return pdf


def image_to_pdf(src: Path, outdir: Path) -> Path:
    try:
        from PIL import Image, ImageOps
    except ImportError:
        raise RuntimeError("Для печати фото нужен пакет python3-pil (sudo apt install python3-pil)")
    pdf = outdir / (src.stem + "_img.pdf")
    with Image.open(src) as im:
        im = ImageOps.exif_transpose(im)
        if im.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", im.size, "white")
            bg.paste(im.convert("RGBA"), mask=im.convert("RGBA").split()[-1])
            im = bg
        else:
            im = im.convert("RGB")
        if im.width > im.height:             # альбомное фото на портретном листе — повернуть
            im = im.rotate(90, expand=True)
        im.save(pdf, "PDF", resolution=200.0)
    return pdf


def lp_print(file: Path, printer: str, copies: int, pages: str, duplex: bool, title: str, fit: bool):
    cmd = ["lp", "-d", printer, "-n", str(copies), "-t", title]
    if pages:
        cmd += ["-o", "page-ranges=" + pages]
    if duplex:
        opt = duplex_option(printer)
        cmd += ["-o", "{}={}".format(*opt)]
    if fit:
        cmd += ["-o", "fit-to-page"]
    cmd.append(str(file))
    if DRY_RUN:
        log("DRY  " + " ".join(cmd))
        return
    rc, out = run(cmd, timeout=120)
    if rc != 0:
        raise RuntimeError("CUPS: " + out.strip()[-300:])


def print_job(path: Path, ext: str, name: str, printer: str, copies: int, pages: str, duplex: bool):
    if not printer:
        raise RuntimeError("На устройстве не настроен ни один принтер (CUPS).")
    with JOB_LOCK, tempfile.TemporaryDirectory(prefix="pp_") as tmp:
        tmpdir = Path(tmp)
        if ext == "pdf":
            lp_print(path, printer, copies, pages, duplex, name, fit=True)
        elif ext in IMAGE_EXT:
            lp_print(image_to_pdf(path, tmpdir), printer, copies, "", False, name, fit=True)
        elif ext == "txt":
            # Текстовый фильтр CUPS (texttopdf) теряет кириллицу — у его шрифтов нет русских букв.
            # Поэтому текст превращаем в PDF через LibreOffice (шрифт Liberation Mono умеет кириллицу).
            if SOFFICE:
                lp_print(convert_to_pdf(path, tmpdir), printer, copies, pages, duplex, name, fit=True)
            else:
                lp_print(path, printer, copies, pages, duplex, name, fit=False)
        elif ext in WORD_EXT or ext in EXCEL_EXT:
            lp_print(convert_to_pdf(path, tmpdir), printer, copies, pages, duplex, name, fit=True)
        elif ext in ("heic", "heif"):
            raise RuntimeError("Формат HEIC не поддерживается. На iPhone: Настройки → Камера → Форматы → «Наиболее совместимый».")
        else:
            raise RuntimeError("Формат .{} не поддерживается. Подходят PDF, фото (JPG/PNG), Word, Excel, TXT.".format(ext))


# ------------------------------------------------------------------ HTTP

QR_PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PhonePrint — адрес для телефона</title>
<style>
  body{margin:0;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;
       font-family:system-ui,sans-serif;background:#f4f3ef;color:#1d1d1b;text-align:center;padding:24px}
  h1{font-weight:600;font-size:26px;margin:0 0 24px}
  #qr{background:#fff;padding:18px;border-radius:16px;box-shadow:0 2px 16px rgba(0,0,0,.08)}
  .url{font:600 26px/1.2 monospace;margin-top:24px}
  p{color:#6b6a65;max-width:440px;line-height:1.5}
</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
</head><body>
<h1>Установка приложения на Android</h1>
<div id="qr"></div>
<div class="url">__URL__/app</div>
<p>Наведите камеру телефона на код или наберите адрес в браузере, скачайте и откройте файл PhonePrint.apk.
Android попросит разрешить установку из браузера — разрешите.</p>
<p>Без приложения тоже можно: откройте в браузере телефона <b>__URL__</b></p>
<script>
  if (window.QRCode) new QRCode(document.getElementById('qr'), {text:'__URL__/app', width:260, height:260});
  else document.getElementById('qr').textContent = 'QR-код не загрузился (нет интернета) — введите адрес вручную.';
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "PhonePrint"
    sys_version = ""

    def log_message(self, fmt, *args):      # свой журнал вместо построчного access-лога
        pass

    # --- ответы
    def send_bytes(self, status, ctype, body: bytes, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, status=200):
        self.send_bytes(status, "application/json; charset=utf-8", json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def send_auth_error(self, status):
        if status == 429:
            msg, err = "Слишком много неверных попыток. Подождите минуту.", "locked"
        elif self.headers.get("X-Pin"):
            msg, err = "Неверный PIN-код", "pin"
        else:
            msg, err = "Нужен PIN-код", "pin"
        self.send_json({"app": APP_NAME, "pinRequired": True, "ok": False, "message": msg, "error": err}, status)

    # --- GET
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path.lower()
        try:
            if path in ("/", "/index.html"):
                self.send_bytes(200, "text/html; charset=utf-8", (APP_DIR / "web" / "index.html").read_bytes())
            elif path == "/qr":
                html = QR_PAGE.replace("__URL__", "http://{}:{}".format(lan_ip(), self.server.server_address[1]))
                self.send_bytes(200, "text/html; charset=utf-8", html.encode("utf-8"))
            elif path in ("/app", "/app.apk"):
                apk = APP_DIR / "PhonePrint.apk"
                if not apk.exists():
                    return self.send_json({"error": "PhonePrint.apk ещё не загружен на устройство"}, 404)
                self.send_bytes(200, "application/vnd.android.package-archive", apk.read_bytes(),
                                {"Content-Disposition": 'attachment; filename="PhonePrint.apk"'})
            elif path == "/api/info":
                auth = auth_status(self)
                if auth != 200:
                    return self.send_auth_error(auth)
                self.send_json(self.info())
            else:
                self.send_json({"error": "Not found"}, 404)
        except Exception as e:             # noqa: BLE001 — любой сбой превращаем в ответ, сервер не падает
            log("ERR  GET {}: {}".format(path, e))
            try:
                self.send_json({"ok": False, "message": str(e)}, 500)
            except OSError:
                pass

    def info(self):
        printers = list_printers()
        target = target_printer("", printers)
        with HISTORY_LOCK:
            history = list(HISTORY)
        return {
            "app": APP_NAME,
            "printer": target,
            "printers": printers,
            "duplex": {p: duplex_option(p) is not None for p in printers},
            "status": printer_status(target),
            "queue": queue_length(target),
            "word": bool(SOFFICE),
            "excel": bool(SOFFICE),
            "dryRun": DRY_RUN,
            "pinRequired": load_pin() is not None,
            "history": history,
        }

    # --- POST
    def read_body_to(self, dest: Path) -> int:
        """Сохраняет тело запроса (Content-Length или chunked) в файл, не больше MAX_UPLOAD."""
        total = 0
        with open(dest, "wb") as f:
            if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
                while True:
                    size_line = self.rfile.readline(64)
                    if not size_line:
                        break
                    size = int(size_line.split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        self.rfile.readline()          # завершающая пустая строка
                        break
                    total += size
                    if total > MAX_UPLOAD:
                        raise RuntimeError("Файл слишком большой (больше 200 МБ).")
                    remaining = size
                    while remaining:
                        chunk = self.rfile.read(min(remaining, 1 << 16))
                        if not chunk:
                            raise RuntimeError("Соединение оборвалось при загрузке файла.")
                        f.write(chunk)
                        remaining -= len(chunk)
                    self.rfile.readline()              # CRLF после чанка
            else:
                length = int(self.headers.get("Content-Length") or 0)
                if length > MAX_UPLOAD:
                    raise RuntimeError("Файл слишком большой (больше 200 МБ).")
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1 << 16))
                    if not chunk:
                        raise RuntimeError("Соединение оборвалось при загрузке файла.")
                    f.write(chunk)
                    remaining -= len(chunk)
                    total += len(chunk)
        return total

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path.lower()
        if path != "/api/print":
            return self.send_json({"error": "Not found"}, 404)
        auth = auth_status(self)
        if auth != 200:
            return self.send_auth_error(auth)

        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        name = urllib.parse.unquote(self.headers.get("X-File-Name", "")) or "document"
        name = os.path.basename(name.replace("\\", "/")) or "document"
        ext = os.path.splitext(name)[1].lstrip(".").lower()
        if not ext:
            by_type = {"application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "text/plain": "txt"}
            ext = by_type.get(self.headers.get("Content-Type", "").split(";")[0].strip().lower(), "")
        try:
            copies = min(max(int(q.get("copies", ["1"])[0]), 1), 50)
        except ValueError:
            copies = 1
        pages = re.sub(r"\s", "", q.get("pages", [""])[0])
        want_duplex = q.get("duplex", [""])[0] == "1"

        printers = list_printers()
        printer = target_printer(urllib.parse.unquote(self.headers.get("X-Printer", "")), printers)
        duplex = want_duplex and bool(printer) and duplex_option(printer) is not None
        entry = {"time": time.strftime("%H:%M"), "name": name, "printer": printer, "copies": copies,
                 "pages": pages, "duplex": duplex, "ok": False, "message": ""}

        tmpdir = tempfile.mkdtemp(prefix="pp_up_")
        try:
            if pages and not re.fullmatch(r"\d+(-\d+)?(,\d+(-\d+)?)*", pages):
                raise RuntimeError("Неверный диапазон страниц. Пример: 1-3,5")
            f = Path(tmpdir) / ("job." + (ext or "bin"))
            size = self.read_body_to(f)
            if size == 0:
                raise RuntimeError("Пустой файл.")
            print_job(f, ext, name, printer, copies, pages, duplex)
            entry["ok"] = True
            entry["message"] = "Пробный режим: задание не отправлено на принтер" if DRY_RUN else "Отправлено на печать"
            if duplex:
                entry["message"] += " (двусторонняя)"
            if want_duplex and not duplex:
                entry["message"] += " (этот принтер не поддерживает двустороннюю печать — печать с одной стороны)"
            log("OK   {} -> {}, копий: {}, страницы: {}{}".format(
                name, printer, copies, pages or "все", ", двусторонняя" if duplex else ""))
        except Exception as e:             # noqa: BLE001
            entry["message"] = str(e) or e.__class__.__name__
            log("ERR  {} : {}".format(name, entry["message"]))
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
            with HISTORY_LOCK:
                HISTORY.appendleft(entry)
        try:
            self.send_json(entry)
        except OSError:
            pass


# ------------------------------------------------------------------ запуск

def main() -> int:
    global DRY_RUN, DATA_DIR, PIN_FILE, LOG_FILE
    ap = argparse.ArgumentParser(description="PhonePrint для Raspberry Pi / Linux (CUPS)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--dry-run", action="store_true", help="не печатать, только показывать команды lp в журнале")
    ap.add_argument("--data-dir", help="где хранить PIN и журнал (по умолчанию /var/lib/phoneprint)")
    ap.add_argument("--set-pin", action="store_true", help="задать PIN-код и выйти")
    ap.add_argument("--clear-pin", action="store_true", help="убрать PIN-код и выйти")
    args = ap.parse_args()

    if args.data_dir:
        DATA_DIR = Path(args.data_dir)
        PIN_FILE, LOG_FILE = DATA_DIR / "pin", DATA_DIR / "phoneprint.log"
    if args.set_pin:
        return cli_set_pin()
    if args.clear_pin:
        return cli_clear_pin()

    DRY_RUN = args.dry_run
    try:
        httpd = ThreadingHTTPServer((args.bind, args.port), Handler)
    except OSError as e:
        print("Не удалось открыть порт {}: {}".format(args.port, e), file=sys.stderr)
        return 1
    httpd.daemon_threads = True
    log("Запущен: http://{}:{}{}{}".format(
        lan_ip(), args.port, "  (пробный режим)" if DRY_RUN else "", "  (PIN включён)" if load_pin() else ""))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    log("Остановлен")
    return 0


if __name__ == "__main__":
    sys.exit(main())
