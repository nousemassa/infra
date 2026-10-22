#!/usr/bin/env bash
# Сторож БОТА НОВОСТЕЙ: /health → при 2 фейлах подряд алерт владельцу; лечение юнита из `failed`.
#
# Почему ОТДЕЛЬНЫЙ скрипт, а не расширение `infra/health/health.sh`: выходной код `health.sh` — ГЕЙТ ВЫКАТА
# моста, и «красный» из-за неготового новостного бота блокировал бы выкат бота записей.
# Здесь свой state-файл; пока токен бота не задан — мягкий режим (всегда exit 0).
set -uo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
PORT="${BRIDGE_NEWS_PORT:-8086}"
URL="http://127.0.0.1:${PORT}/health"
UNIT="bridge-news.service"
# Режим определяет общий помощник (см. пояснение в `infra/health/health.sh`). Пока службы в compose нет,
# помощник вернёт юнит-режим.
GUARD_CONTAINER="${NEWS_CONTAINER:-}"
GUARD_SERVICE="news"
GUARD_PROJECT="news"
GUARD_UNIT="$UNIT"
GUARD_URL="$URL"
source "$INFRA/lib/service_guard.sh"
# ЕДИНЫЙ вход доставки алерта: мост → MTProto без моста → маркер.
source "$INFRA/lib/alert.sh"
STATE_FILE="${TMPDIR:-/tmp}/agent-health-news-fails"
# Доставка — ОБЩИЙ вход (`infra/lib/alert.sh`): мост → MTProto без моста → маркер+журнал.
# Мост здесь почтальон, а не проверяемый объект: его смерть больше не глушит алерт.

TOKEN="$(sed -n 's/^TELEGRAM_NEWS_BOT_TOKEN=//p' "$WORKSPACE/.env" | head -1 | tr -d '"'"'"'')"

if [[ -z "$TOKEN" ]]; then
  echo "[health-news] мягкий режим: TELEGRAM_NEWS_BOT_TOKEN не задан — бот ещё не зарегистрирован, проверок нет"
  echo 0 > "$STATE_FILE"
  exit 0
fi

# Режим наблюдаемости: у вендора без `runtime` продукты гасятся ОСОЗНАННО — проверять нечего.
# ❗ Строка стоит ДО счётчика фейлов и ДО лечения: иначе два тика дадут ложный алерт владельцу, а
# `guard_heal` рестартом ВОСКРЕСИТ погашенное. Счётчик обнуляем — «мягкий режим», как ниже с токеном.
if guard_skip_if_other_vendor "бот новостей"; then
  echo 0 > "$STATE_FILE"
  exit 0
fi

fails=0
why=""

if guard_in_container; then
  state="$(guard_state)"
  [[ "$state" == "running" ]] || { echo "[health-news] FAIL: $(guard_where) в состоянии $state"; why="${why}$(guard_where) $state, "; fails=$((fails + 1)); }
else
  systemctl --user is-active --quiet "$UNIT" || { echo "[health-news] FAIL: юнит $UNIT не активен"; why="${why}юнит не активен, "; fails=$((fails + 1)); }
fi

payload="$(curl -fsS --max-time 8 "$URL" 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  echo "[health-news] FAIL: $URL недоступен"
  why="${why}нет ответа /health, "
  fails=$((fails + 1))
else
  verdict="$(printf '%s' "$payload" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("невалидный JSON")
    raise SystemExit

problems = []
if data.get("status") != "ok":
    problems.append("status=" + str(data.get("status")))
if data.get("configured") is True and data.get("telegram") is not True:
    problems.append("бот не подключён (токен задан, но Telegram недоступен)")
print("; ".join(problems) if problems else "ok")
' 2>/dev/null)"
  if [[ "$verdict" == "ok" ]]; then
    echo "[health-news] ok"
  else
    echo "[health-news] FAIL: ${verdict:-не удалось разобрать ответ}"
    why="${why}${verdict}, "
    fails=$((fails + 1))
  fi
fi

if [[ "$fails" -gt 0 ]]; then
  n=$(cat "$STATE_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_FILE"
  if [[ "$n" -ge 2 ]]; then
    healed="$(guard_heal)" || healed=""
    alert_send "[health-news]" "бот новостей недоступен (${n} проверок подряд): ${why%, }${healed:+; $healed}"
    alert_send "[health-news]" "следствие: выпуски в канал не выходят до восстановления бота"
  fi
  exit 1
fi

#: Долг 2: о ВОССТАНОВЛЕНИИ сообщаем так же, как об отказе. Зовётся ДО обнуления
#: счётчика — иначе «было N» уже неоткуда взять. Молчит, если отказа не было.
alert_recovered "[health-news]" "бот новостей" "$STATE_FILE"
echo 0 > "$STATE_FILE"
exit 0
