#!/usr/bin/env bash
# /health-cron: проверяет api и bridge; 2 фейла подряд → алерт владельцу/менеджерам в Telegram.
#
# Почему проверяем ПОЛЯ, а не только код ответа: процесс моста может отвечать 200, а Telegram-канал
# при этом быть мёртвым («бот молчит»). Поэтому: status=ok И telegram=true, плюс для справки возраст
# последнего апдейта (last_update_age_s) — он отличает «тихо, потому что никто не пишет» от «канал не
# принимает».
#
# Алерт доставляется ручкой моста POST /api/ops/alert (заглушка через `realty_agent.outbox` не
# используется). Плюс самоизлечение: если лимитер юнита увёл мост в `failed`, сторож делает
# `reset-failed` + `start`, иначе мост остаётся в `failed` без самоподъёма.
set -uo pipefail
STATE_FILE="${TMPDIR:-/tmp}/agent-health-fails"
API_URL="${PLATFORM_API_URL:-http://127.0.0.1:8680/api}"
BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:8085}"
#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
UNIT="bridge.service"
# Служба может жить КОНТЕЙНЕРОМ. Режим («контейнер или юнит») определяет общий помощник
# (`infra/lib/service_guard.sh`): копия этой логики в стороже проверяла бы выключенный юнит и
# ругалась на живую службу.
GUARD_CONTAINER="${BRIDGE_CONTAINER:-}"
GUARD_SERVICE="bridge"
GUARD_PROJECT="realty"
GUARD_UNIT="$UNIT"
GUARD_URL="${BRIDGE_URL:-http://127.0.0.1:8085}/health"
source "$INFRA/lib/service_guard.sh"
# ЕДИНЫЙ вход доставки алерта: мост → MTProto без моста → маркер.
source "$INFRA/lib/alert.sh"

fails=0
why=""

# Ключ берём из .env и не печатаем: ручка /api/ops/alert закрыта X-API-Key.

# ДВЕ ОСИ, ДВА ПРЕДМЕТА. `PLATFORM_VENDOR` — кто ИСПОЛНЯЕТ ход (рантайм). `TELEMETRY_VENDOR` — чью
# форму имеет спан и КУДА он уходит (приёмник). Одна переменная на оба вопроса оставила бы сторожа
# ОДНООСЕВЫМ: приёмник проверялся бы только внутри ветки «рантайм», и мёртвый стек наблюдаемости давал
# бы зелёный `make health`. Поэтому каждая ось стережёт свой предмет, а всякий пропуск НАЗВАН вслух
# (молчаливый пропуск неотличим от «всё хорошо»).
platform="$(sed -n 's/^PLATFORM_VENDOR=//p' "$WORKSPACE/.env" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
platform="${platform:-$(vendor_capability_default)}"   # пусто = значение таблицы вендоров
telemetry="$(sed -n 's/^TELEMETRY_VENDOR=//p' "$WORKSPACE/.env" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
telemetry="${telemetry:-$platform}"   # пусто = «как у рантайма» (значение по умолчанию)

runtime_failed=0      # отказы оси рантайма (мост) — их лечим
observer_failed=0     # отказы оси наблюдаемости (стек + приёмник) — их НЕ лечим, о них сообщаем

# Ось наблюдаемости стережёт СВОЙ предмет, а проба берётся у вендора: файл `lib/vendor-probes/<вендор>.sh`
# с функцией `vendor_probe_telemetry`. Обязательство одинаково для всех вендоров: нет файла — названный
# отказ, а не молчаливый пропуск (молчание неотличимо от «всё хорошо»).
probe_file="$INFRA/lib/vendor-probes/$telemetry.sh"
if [[ ! -f "$probe_file" ]]; then
  echo "[health] FAIL: у вендора $telemetry нет пробы оси наблюдаемости ($probe_file)"
  why="${why}проба $telemetry не найдена, "
  fails=$((fails + 1)); observer_failed=$((observer_failed + 1))
else
  source "$probe_file"
  vendor_probe_telemetry
fi

# Мост: код ответа + разбор полей. ❗ У вендора без `runtime` мост ПОГАШЕН осознанно (продукты не
# работают без рантайма платформы) — пропуск НАЗВАН и счётчик НЕ наращивается, но **выхода здесь
# НЕТ**: иначе провал стека/приёмника (найденный выше) остался бы только в журнале, и владелец не
# узнал бы о мёртвом приёмнике вообще.
if [[ "$(vendor_capability "$platform" runtime)" != "yes" ]]; then
  echo "[health] мост не проверяется: у вендора $platform нет возможности 'runtime' — контур остановлен осознанно"
  payload=""
else
payload="$(curl -fsS --max-time 8 "$BRIDGE_URL/health" 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  echo "[health] FAIL: bridge $BRIDGE_URL/health недоступен"
  why="${why}мост не отвечает на /health, "
  fails=$((fails + 1)); runtime_failed=$((runtime_failed + 1))
else
  verdict="$(printf '%s' "$payload" | python3 -c '
import json, sys;

try:
    data = json.load(sys.stdin)
except Exception:
    print("невалидный JSON")
    raise SystemExit

problems = []
if data.get("status") != "ok":
    problems.append("status=" + str(data.get("status")))
if data.get("telegram") is not True:
    problems.append("telegram!=true (канал не принимает)")
#: Живые петли: `not_started`/`not_configured` — норма (свопер без `turns`, outbox без базы),
#: красный только `dead`. Без этого поля смерть петли видит только журнал, а `/health` остаётся
#: зелёным — синхронизация может исчезнуть незамеченной.
dead = sorted(name for name, state in (data.get("loops") or {}).items() if state == "dead")
if dead:
    problems.append("петли умерли: " + ",".join(dead))
print("; ".join(problems) if problems else "ok")
' 2>/dev/null)"
  age="$(printf '%s' "$payload" | python3 -c '
import json, sys;

try:
    print(json.load(sys.stdin).get("last_update_age_s"))
except Exception:
    print("?")
' 2>/dev/null)"
  if [[ "$age" == "None" || -z "$age" ]]; then
    age_note="апдейтов ещё не было"
  else
    age_note="последний апдейт: ${age} с назад"
  fi
  if [[ "$verdict" == "ok" ]]; then
    echo "[health] bridge ok (${age_note})"
  else
    echo "[health] FAIL: bridge — ${verdict:-не удалось разобрать ответ} (${age_note})"
    why="${why}${verdict:-невалидный ответ}, "
    fails=$((fails + 1)); runtime_failed=$((runtime_failed + 1))
  fi
fi
fi   # конец ветки «мост проверяем только у вендора с возможностью runtime»

if [[ "$fails" -gt 0 ]]; then
  n=$(cat "$STATE_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_FILE"
  if [[ "$n" -ge 2 ]]; then
    # Лимитер юнита (`StartLimitBurst=5`/60 с) при долгом холодном старте уводит мост в `failed` без
    # самоподъёма — лечим; помощник понимает оба режима (юнит и контейнер), `infra/lib/service_guard.sh`.
    # ❗ Лечение — ТОЛЬКО у вендора с возможностью `runtime`. У остальных объект сторожа (мост) погашен
    # осознанно, и `docker restart` из `guard_heal` ВОСКРЕСИЛ бы его — нарушив и режим, и бюджет памяти,
    # ради которого гасили. Тот же приём, что у продуктовых сторожей (`guard_skip_if_other_vendor`).
    #: ❗ Лечим ТОЛЬКО тот предмет, который умеем и которому верим: мост у вендора с `runtime`. Стек
    #: наблюдаемости не лечим вовсе — он поднимается и гасится владельцем (правило «нет автолечения»),
    #: а `docker restart` МОСТА по падению приёмника был бы лечением не того объекта.
    healed=""
    if (( runtime_failed > 0 )) && [[ "$(vendor_capability "$platform" runtime)" == "yes" ]]; then
      healed="$(guard_heal)" || healed=""
    fi
    what="бот недоступен"
    if (( observer_failed > 0 )); then what="приём наблюдаемости ($telemetry) недоступен"; fi
    if (( runtime_failed > 0 )) && (( observer_failed > 0 )); then
      what="бот и приём наблюдаемости недоступны"
    fi
    alert_send "[health]" "${what} (${n} проверок подряд): ${why%, }${healed:+; $healed}"
  fi
else
  #: О ВОССТАНОВЛЕНИИ сообщаем так же, как об отказе. Зовётся ДО обнуления
  #: счётчика — иначе «было N» уже неоткуда взять. Молчит, если отказа не было.
  alert_recovered "[health]" "мост и приём телеметрии" "$STATE_FILE"
  echo 0 > "$STATE_FILE"
  #: Обе оси печатаем ЯВНО и в одном виде: журнал обязан называть и режим, и приём, иначе «спаны не
  #: там» неотличимо от «спанов нет».
  echo "[health] ok (режим $platform, спаны: $telemetry)"
fi

# --- читатель маркера недоставленных алертов ---------------------------------------------------
# ❗ Факт «доставить не удалось» без читателя — тихий отказ с диском, поэтому недоставленное
# становится алертом (и просьбой дослать).
pending="$(alert_marker_pending)"
if (( pending > 0 )); then
  echo "[health] недоставленных ранее алертов: $pending — пробую дослать"
  if alert_flush_marker "[health]"; then
    echo "[health] недоставленное дослано, маркер очищен"
  else
    echo "[health] досылка не удалась — маркер сохранён (повторю на следующем тике)" >&2
  fi
fi

# Код выхода = есть ли фейлы: гейт выката не должен проходить на мёртвом канале.
exit "$(( fails > 0 ? 1 : 0 ))"
