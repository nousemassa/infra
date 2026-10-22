#!/usr/bin/env bash
# ЕДИНЫЙ вход доставки алерта владельцу — ОДИН вместо копий `alert()` в каждом стороже.
#
# **Зачем один вход.** Функция `alert()` в каждом стороже (`health.sh`,
# `health-news/mcp/reminders/embed/solver/search/drift.sh`) расходится: у одной `BRIDGE_URL` берётся из
# окружения, у других зашит; у одной ключ читается лениво, у других сразу. Механизм, нужный двум
# потребителям, имеет ОДИН вход — иначе копии молча расходятся.
#
# **Зачем знает режим.** Доставка идёт через мост (`POST /api/ops/alert`), а мост умеет пользоваться
# Telegram только пока САМ жив. У вендора без возможности `runtime` он погашен осознанно ⇒ алертов не
# существует вовсе; та же слепота наступает, когда мост УПАЛ у вендора с `runtime` — ровно тогда,
# когда сообщение нужнее всего. Отсюда три пути, и каждый НАЗЫВАЕТ себя:
#
#   1) МОСТ (он же шлёт и менеджерам), когда мост отвечает;
#   2) MTProto БЕЗ МОСТА (`infra/alert-send.py`, сессия моста) — только если сессия СВОБОДНА, то есть
#      контейнер моста не работает и хостовый юнит не активен. Иначе нарушилось бы правило проекта
#      «одна сессия Telegram — один процесс»; проверка здесь ЯВНАЯ, а не подразумеваемая;
#   3) МАРКЕР + журнал — последний рубеж, с НАЗВАННОЙ причиной. Молчаливого отказа не бывает.
#
# Подключение (из сторожа):  source "$INFRA/lib/alert.sh"
# Вызов:                     alert_send "<префикс>" "<текст>"
# Проверка доставки:         bash lib/alert.sh --probe
#
# ❗ Это файл-библиотека: `set -e/-u` здесь НЕ выставляются — они уже заданы вызывающим, а менять флаги
# чужой оболочки из подключённого файла значит менять поведение того, кто тебя позвал.

# При прямом запуске (проверка) корни берём из общего помощника; при подключении они уже есть.
if [[ -z "${INFRA:-}" || -z "${WORKSPACE:-}" ]]; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workspace.sh" || exit 2
fi

#: Куда писать, когда доставить нечем. Читатель есть: `alert_marker_pending` (счётчик) и
#: `alert_flush_marker` (досылка при восстановлении доставки): файл без читателя — «страховка», о
#: которой никто не узнаёт.
ALERT_MARKER="${TMPDIR:-/tmp}/agent-health-alerts.log"
ALERT_BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:8085}"
ALERT_BRIDGE_PROJECT="realty"
ALERT_BRIDGE_SERVICE="bridge"
ALERT_BRIDGE_UNIT="bridge.service"

alert_bridge_key() {
  sed -n 's/^BRIDGE_API_KEY=//p' "$WORKSPACE/.env" 2>/dev/null | head -1 | tr -d '"'"'"''
}

#: Мост ЖИВ? Спрашиваем его `/health`, а не наличие контейнера: контейнер может быть поднят, а транспорт
#: внутри — нет (тогда ручка ответит 503, и это увидит путь 1).
alert_bridge_live() {
  curl -fsS --max-time 3 "${ALERT_BRIDGE_URL}/health" >/dev/null 2>&1
}

#: Держит ли кто-то файл сессии моста. Два владельца возможны: контейнер (наш обычный режим) и хостовый
#: юнит (`bridge.service`, режим отката). Спрашиваем ОБОИХ — иначе два процесса на одной сессии.
alert_session_busy() {
  local container
  container="$(docker ps \
      --filter "label=com.docker.compose.service=${ALERT_BRIDGE_SERVICE}" \
      --filter "label=com.docker.compose.project=${ALERT_BRIDGE_PROJECT}" \
      --format '{{.Names}}' 2>/dev/null | head -1)"
  [[ -n "$container" ]] && return 0
  systemctl --user is-active --quiet "$ALERT_BRIDGE_UNIT" 2>/dev/null && return 0
  return 1
}

alert_marker() {
  #: ❗ `ALERT_NO_MARKER=1` — запись В МАРКЕР ЗАПРЕЩЕНА. Нужно ровно для алерта «есть недоставленные»:
  #: без этого его собственная неудача дописывала бы маркер, и счётчик рос бы вечно (петля «алерт об
  #: алертах не доставлен»).
  [[ "${ALERT_NO_MARKER:-0}" == "1" ]] && return 0
  printf '%s %s\n' "$(date -Is)" "$1" >> "$ALERT_MARKER" 2>/dev/null || true
}

#: Сколько алертов лежит НЕдоставленными. Это и есть читатель маркера: без него файл — «страховка»,
#: о которой никто не узнаёт.
alert_marker_pending() {
  #: ❗ Проверка существования ОБЯЗАТЕЛЬНА: `wc -l < отсутствующего файла` — это отказ ПЕРЕНАПРАВЛЕНИЯ, он
  #: печатается в stderr вызывающего и не глушится `2>/dev/null`.
  local count=0
  [[ -f "$ALERT_MARKER" ]] && count="$(wc -l < "$ALERT_MARKER" 2>/dev/null || echo 0)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s' "$count"
}

alert_marker_clear() { : > "$ALERT_MARKER" 2>/dev/null || true; }

#: Сообщить владельцу, что доставить не удалось. 0 — сообщать нечего (или уже сообщено).
#: ❗ После УСПЕШНОЙ доставки маркер очищается: факт доставлен, и повторять его на каждом тике нельзя.
alert_flush_marker() {
  local prefix="${1:-[alert]}" count last
  count="$(alert_marker_pending)"
  (( count > 0 )) || return 0
  last="$(tail -1 "$ALERT_MARKER" 2>/dev/null | cut -c1-180)"
  if ALERT_NO_MARKER=1 alert_send "$prefix" \
      "ранее НЕ доставлено алертов: $count (последний: $last). Доставка восстановлена, маркер очищен"; then
    alert_marker_clear
    return 0
  fi
  return 1
}

#: Уведомление о ВОССТАНОВЛЕНИИ: звать в ветке «всё хорошо», ДО обнуления счётчика.
#: Молчит, если предыдущего отказа не было — иначе после ребута (файлы в /tmp пропали) полетело бы
#: ложное «восстановлено» на ровном месте.
alert_recovered() {
  local prefix="${1:-[alert]}" what="${2:-служба}" state_file="${3:-}" prev
  [[ -n "$state_file" ]] || return 0
  prev="$(cat "$state_file" 2>/dev/null || echo 0)"
  [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  (( prev > 0 )) || return 0
  alert_send "$prefix" "ВОССТАНОВЛЕНО: $what снова в норме (было $prev неудачных проверок подряд)"
}

#: Доставить алерт. Возвращает 0 только если ДЕЙСТВИТЕЛЬНО доставлено; иначе 1 (и пишет маркер).
alert_send() {
  local prefix="${1:-[alert]}" text="${2:-}" key body out rc
  [[ -n "$text" ]] || text="(пустой текст алерта)"

  # --- путь 1: мост -----------------------------------------------------------------------------
  if alert_bridge_live; then
    key="$(alert_bridge_key)"
    if [[ -z "$key" ]]; then
      echo "$prefix алерт не доставлен: BRIDGE_API_KEY не найден в $WORKSPACE/.env" >&2
      alert_marker "$prefix $text"
      return 1
    fi
    body="$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1]}))' "$text" 2>/dev/null)"
    if curl -fsS --max-time 10 -X POST "${ALERT_BRIDGE_URL}/api/ops/alert" \
        -H "X-API-Key: $key" -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1; then
      echo "$prefix АЛЕРТ доставлен (мост): $text"
      [[ "${ALERT_NO_MARKER:-0}" == "1" ]] || alert_flush_marker "$prefix" || true
      return 0
    fi
    echo "$prefix мост ответил отказом — пробую MTProto без моста" >&2
  fi

  # --- путь 2: MTProto без моста (только при СВОБОДНОЙ сессии) ------------------------------------
  if alert_session_busy; then
    echo "$prefix MTProto не пробую: сессия моста занята (правило «одна сессия Telegram — один процесс»)" >&2
  else
    out="$(printf '%s' "$prefix ⚠️ $text" | env -u PYTHONPATH \
        SESSIONS_DIR="$WORKSPACE/realty/.sessions" \
        AGENT_ENV_FILES="$WORKSPACE/.env:$WORKSPACE/realty/.env" \
        "$WORKSPACE/.venv/bin/python" "$INFRA/alert-send.py" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "$prefix АЛЕРТ доставлен (MTProto без моста): $text"
      [[ "${ALERT_NO_MARKER:-0}" == "1" ]] || alert_flush_marker "$prefix" || true
      return 0
    fi
    echo "$prefix MTProto не сработал (код $rc): $(printf '%s' "$out" | tail -1)" >&2
  fi

  # --- путь 3: последний рубеж ------------------------------------------------------------------
  alert_marker "$prefix $text"
  echo "$prefix АЛЕРТ НЕ доставлен — записан маркер: $ALERT_MARKER" >&2
  return 1
}

# --- проверка доставки ----------------------------------------------------------------------------
# `--probe` — тот же путь с проверочным текстом: он проходит ТЕМ ЖЕ кодом, каким идут настоящие алерты,
# поэтому «проверка прошла» и «алерты доходят» — одно утверждение.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --probe)
      alert_send "[probe]" "проверка доставки алертов: режим $(sed -n 's/^PLATFORM_VENDOR=//p' "$WORKSPACE/.env" 2>/dev/null | head -1 | tr -d '[:space:]')"
      exit $? ;;
    *) echo "использование: $0 --probe   (или подключить как библиотеку: source …; alert_send <префикс> <текст>)" >&2
       exit 2 ;;
  esac
fi
