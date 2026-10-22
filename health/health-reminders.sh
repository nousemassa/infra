#!/usr/bin/env bash
# Сторож ПРОЦЕССА ГРАФА НАПОМИНАНИЙ: /health → при 2 фейлах подряд алерт владельцу;
# лечение — по режиму: контейнер перезапускаем `docker restart`, юнит — из `failed`.
#
# Почему ОТДЕЛЬНЫЙ скрипт, а не строка в `infra/health/health.sh`. Выходной код `health.sh` — ГЕЙТ ВЫКАТА
# моста; «красный» из-за недоступного графа блокировал бы выкат бота записей, хотя граф — отдельная
# служба. Свой state-файл, свой юнит, своя судьба.
#
# Почему сторож вообще нужен, если граф — отдельный процесс. Отдельный процесс даёт независимый
# рестарт, но не даёт лечения: без сторожа упавший процесс лежит до ручного `systemctl --user start`.
# Сторож закрывает ровно этот разрыв и заодно делает поломку видимой.
set -uo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
PORT="${BRIDGE_GRAPH_PORT:-8089}"
URL="http://127.0.0.1:${PORT}/health"
UNIT="bridge-reminders.service"
# Граф живёт КОНТЕЙНЕРОМ, юнит выключен. Режим («контейнер или юнит») определяет ОБЩИЙ помощник
# `infra/lib/service_guard.sh`: копия этой логики в каждом стороже — ровно тот путь, которым появляется
# ложный алерт от чужого шаблона.
GUARD_CONTAINER="${GRAPH_CONTAINER:-}"
GUARD_SERVICE="reminders"
GUARD_PROJECT="realty"
GUARD_UNIT="$UNIT"
GUARD_URL="$URL"
source "$INFRA/lib/service_guard.sh"
# ЕДИНЫЙ вход доставки алерта: мост → MTProto без моста → маркер.
source "$INFRA/lib/alert.sh"
STATE_FILE="${TMPDIR:-/tmp}/agent-health-reminders-fails"
# Доставка — ОБЩИЙ вход (`infra/lib/alert.sh`): мост → MTProto без моста → маркер+журнал.
# Мост здесь почтальон, а не проверяемый объект: его смерть больше не глушит алерт.

# Режим наблюдаемости: у вендора без `runtime` продукты гасятся ОСОЗНАННО — проверять нечего.
# ❗ Строка стоит ДО счётчика фейлов и ДО лечения: иначе два тика дадут ложный алерт владельцу, а
# `guard_heal` рестартом ВОСКРЕСИТ погашенное. Счётчик обнуляем — «мягкий режим», как ниже с токеном.
if guard_skip_if_other_vendor "граф напоминаний"; then
  echo 0 > "$STATE_FILE"
  exit 0
fi

fails=0
why=""

if guard_in_container; then
  state="$(guard_state)"; health="$(guard_health)"
  if [[ "$state" != "running" ]]; then
    echo "[health-reminders] FAIL: $(guard_where) в состоянии $state"
    why="${why}$(guard_where) $state, "; fails=$((fails + 1))
  elif [[ "$health" != "healthy" && "$health" != "none" ]]; then
    echo "[health-reminders] FAIL: $(guard_where) health=$health"
    why="${why}$(guard_where) health=$health, "; fails=$((fails + 1))
  fi
else
  systemctl --user is-active --quiet "$UNIT" \
    || { echo "[health-reminders] FAIL: юнит $UNIT не активен"; why="${why}юнит не активен, "; fails=$((fails + 1)); }
fi

payload="$(curl -fsS --max-time 8 "$URL" 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  echo "[health-reminders] FAIL: $URL недоступен"
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
if data.get("service") != "visit-reminders":
    # Отвечает ЧТО-ТО другое на нашем порту — например, чужой сервер после смены привязки.
    problems.append("service=" + str(data.get("service")))
if data.get("enabled") is not True:
    # Процесс поднялся, а граф в нём НЕ включён (VISIT_REMINDER_ENABLED=false или граф не собрался):
    # снаружи это выглядит как «всё живо», а напоминания не ходят. Именно этот случай и ловим.
    problems.append("граф не включён (enabled=" + str(data.get("enabled")) + ")")
print("; ".join(problems) if problems else "ok")
' 2>/dev/null)"
  if [[ "$verdict" == "ok" ]]; then
    echo "[health-reminders] ok"
  else
    echo "[health-reminders] FAIL: ${verdict:-не удалось разобрать ответ}"
    why="${why}${verdict}, "
    fails=$((fails + 1))
  fi
fi

if [[ "$fails" -gt 0 ]]; then
  n=$(cat "$STATE_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_FILE"
  if [[ "$n" -ge 2 ]]; then
    healed="$(guard_heal)" || healed=""
    alert_send "[health-reminders]" "Напоминания о визитах недоступны (${n} проверок подряд): ${why%, }${healed:+; $healed}"
  fi
  # Код 1 — намеренно: сторож обязан быть виден в `systemctl --user --failed`. На гейт выката моста
  # он не влияет (`infra/health/health.sh` — отдельный скрипт и отдельный юнит).
  exit 1
fi

#: Долг 2: о ВОССТАНОВЛЕНИИ сообщаем так же, как об отказе. Зовётся ДО обнуления
#: счётчика — иначе «было N» уже неоткуда взять. Молчит, если отказа не было.
alert_recovered "[health-reminders]" "граф напоминаний" "$STATE_FILE"
echo 0 > "$STATE_FILE"
exit 0
