#!/usr/bin/env bash
# Ротация лога моста БЕЗ root.
#
# Почему так: systemd `StandardOutput=append:` не умеет ограничивать размер, а logrotate требует прав root.
# Поэтому потолок держим своим таймером пользователя: при превышении MAX_KB лог уезжает в .1 (предыдущий .1
# удаляем) и мост перезапускается — systemd переоткрывает файл и создаёт свежий. Перезапуск нужен потому,
# что после `mv` процесс продолжает писать в переименованный файл (держит дескриптор).
#
#   bash infra/logs/bridge-log-trim.sh            # разово, порог 20 МБ (лог моста)
#   MAX_KB=5000 bash infra/logs/bridge-log-trim.sh
#   bash infra/logs/bridge-log-trim.sh --log news/logs/news.log --unit bridge-news
#
# Параметры --log/--unit позволяют обрезать лог любого процесса: без аргументов берётся лог моста
# и юнит `bridge` (так скрипт зовёт таймер `bridge-logtrim`).
set -euo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
LOG_REL="realty/logs/bridge.log"
UNIT="bridge"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)  LOG_REL="${2:?--log требует значение}"; shift 2 ;;
    --unit) UNIT="${2:?--unit требует значение}"; shift 2 ;;
    *) echo "[bridge] неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done
LOG="$WORKSPACE/$LOG_REL"
KEEP="$LOG.1"
MAX_KB="${MAX_KB:-20000}"

[[ -f "$LOG" ]] || exit 0
size_kb="$(du -k "$LOG" | cut -f1)"
if (( size_kb <= MAX_KB )); then
  exit 0
fi

mv -f "$LOG" "$KEEP"
if ! systemctl --user restart "$UNIT" 2>/dev/null; then
  mv -f "$KEEP" "$LOG"   # рестарт не удался (например, краш-луп) — возвращаем имя, иначе .1 растёт без потолка
  echo "[bridge] лог ${size_kb} КБ, но $UNIT не перезапустился — обрезка отменена"
  exit 1
fi
echo "[bridge] лог был ${size_kb} КБ (> ${MAX_KB}) → ${KEEP}, $UNIT перезапущен"
