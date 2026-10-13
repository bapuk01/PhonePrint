#!/usr/bin/env bash
# Установка PhonePrint на Raspberry Pi / Debian:   sudo ./install.sh [--no-office]
# --no-office — не ставить LibreOffice (тогда Word/Excel печатать нельзя, останутся PDF, фото и текст).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Запустите через sudo: sudo ./install.sh"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
SVC_USER="${SUDO_USER:-admin}"
APP=/opt/phoneprint
DATA=/var/lib/phoneprint
OFFICE=1
[ "${1:-}" = "--no-office" ] && OFFICE=0

# Каталоги с веб-страницей и APK: рядом со скриптом (архив) или уровнем выше (репозиторий)
WEB=""; APK=""
for d in "$SRC" "$SRC/.."; do
  [ -z "$WEB" ] && [ -f "$d/web/index.html" ] && WEB="$d/web"
  [ -z "$APK" ] && [ -f "$d/PhonePrint.apk" ] && APK="$d/PhonePrint.apk"
done
[ -n "$WEB" ] || { echo "Не найдена папка web/ с index.html"; exit 1; }

echo "==> Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends python3 python3-pil cups-client fonts-liberation fonts-dejavu-core
if [ "$OFFICE" = 1 ]; then
  echo "==> LibreOffice (для Word/Excel) — это несколько минут"
  apt-get install -y --no-install-recommends libreoffice-writer-nogui libreoffice-calc-nogui
fi

echo "==> Файлы"
install -d -m 755 "$APP" "$APP/web"
install -m 755 "$SRC/phoneprint_server.py" "$APP/phoneprint_server.py"
cp -r "$WEB/." "$APP/web/"
[ -n "$APK" ] && install -m 644 "$APK" "$APP/PhonePrint.apk" || echo "(PhonePrint.apk не найден — раздача /app не будет работать)"
install -d -m 755 -o "$SVC_USER" "$DATA"

cat > /usr/local/bin/phoneprint-pin <<'WRAP'
#!/bin/sh
# phoneprint-pin set | clear  — задать / убрать PIN-код (запускать через sudo)
case "${1:-}" in
  set)   exec env PHONEPRINT_DATA=/var/lib/phoneprint python3 /opt/phoneprint/phoneprint_server.py --set-pin ;;
  clear) exec env PHONEPRINT_DATA=/var/lib/phoneprint python3 /opt/phoneprint/phoneprint_server.py --clear-pin ;;
  *) echo "Использование: sudo phoneprint-pin set | clear"; exit 1 ;;
esac
WRAP
chmod 755 /usr/local/bin/phoneprint-pin

echo "==> Служба systemd (автозапуск при включении)"
sed "s/__USER__/$SVC_USER/" "$SRC/phoneprint.service" > /etc/systemd/system/phoneprint.service
systemctl daemon-reload
systemctl enable phoneprint.service >/dev/null
systemctl restart phoneprint.service

# Если в CUPS нет принтера по умолчанию, а принтер один — сделать его основным
if ! lpstat -d 2>/dev/null | grep -q 'destination:'; then
  PRINTERS="$(lpstat -p 2>/dev/null | awk '/^printer /{print $2}')"
  if [ "$(echo "$PRINTERS" | grep -c .)" = 1 ]; then
    lpoptions -d "$PRINTERS" >/dev/null && echo "Принтер по умолчанию: $PRINTERS"
  fi
fi

sleep 2
systemctl --no-pager --lines=0 status phoneprint.service || true
IP="$(hostname -I | awk '{print $1}')"
echo
echo "Готово. Адрес: http://$IP:8080   (приложение на телефоне найдёт его само)"
echo "PIN-код (по желанию):  sudo phoneprint-pin set"
