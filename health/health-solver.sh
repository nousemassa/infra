#!/usr/bin/env bash
# Сторож РЕШАТЕЛЯ `solver`: /health → при 2 фейлах подряд алерт владельцу и лечение.
#
# **Почему нужен, если у контейнера есть `restart` и healthcheck.** `restart: unless-stopped` закрывает
# ПАДЕНИЕ, а healthcheck — деградацию на CPU, но оба живут ВНУТРИ docker: алерта нет ни у кого, а
# контейнер, который жив и заклинен, `restart: unless-stopped` не трогает вовсе (autoheal у нас нет).
#
# **Почему это не «ещё один сторож на всякий случай».** Отказ решателя в продукте МОЛЧАЛИВ и стоит денег:
# `app/decisions/client.py` бросает `SolverUnavailable`, его ловит `local_close/gate.py`
# ⇒ лестница решений (порог 0.75, p50 737 мс, локально и бесплатно) отключается, и ход уходит
# в облако — дороже и медленнее, без единой записи о причине. Тот же класс, что деградация эмбеддингов
# в контейнере `mcp`: служба жива, ответы хуже, причины в журнале нет.
#
# **Почему проверяется не только «жив».** `/health` решателя отдаёт `n_gpu_layers` (у `llama-server`
# такого поля нет): ноль означает работу на CPU. Это надо называть ПРИЧИНОЙ алерта, а не диагнозом
# «недоступен»: лечение у двух случаев разное по смыслу, а разбираться владельцу.
set -uo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
#: ❗ `JEV_PORT` — переменная ЧУЖОГО сервера (его читает `jev_server.py`), поэтому имя не наше и не меняется.
PORT="${SOLVER_PORT:-${JEV_PORT:-8083}}"
URL="http://127.0.0.1:${PORT}/health"
UNIT="solver.service"
STATE_FILE="${TMPDIR:-/tmp}/agent-health-solver-fails"
# Решатель живёт КОНТЕЙНЕРОМ, а хостовый юнит оставлен откатом ⇒ режим определяет общий помощник,
# своих копий логики не заводим (копия шаблона давала ложный алерт).
GUARD_CONTAINER="${SOLVER_CONTAINER:-}"
GUARD_SERVICE="solver"
GUARD_PROJECT="models"
GUARD_UNIT="$UNIT"
GUARD_URL="$URL"
source "$INFRA/lib/service_guard.sh"
# ЕДИНЫЙ вход доставки алерта: мост → MTProto без моста → маркер.
source "$INFRA/lib/alert.sh"
# Доставка — ОБЩИЙ вход (`infra/lib/alert.sh`): мост → MTProto без моста → маркер+журнал.

fails=0
why=""

if guard_in_container; then
  state="$(guard_state)"; health="$(guard_health)"
  if [[ "$state" != "running" ]]; then
    echo "[health-solver] FAIL: $(guard_where) в состоянии $state"
    why="${why}$(guard_where) $state, "; fails=$((fails + 1))
  elif [[ "$health" != "healthy" && "$health" != "none" ]]; then
    echo "[health-solver] FAIL: $(guard_where) health=$health"
    why="${why}$(guard_where) health=$health, "; fails=$((fails + 1))
  fi
else
  systemctl --user is-active --quiet "$UNIT" \
    || { echo "[health-solver] FAIL: юнит $UNIT не активен"; why="${why}юнит не активен, "; fails=$((fails + 1)); }
fi

payload="$(curl -fsS --max-time 8 "$URL" 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  echo "[health-solver] FAIL: $URL недоступен"
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
if not data.get("ready"):
    problems.append("не готов (ready=false) — модель не загружена")
try:
    layers = int(data.get("n_gpu_layers") or 0)
except (TypeError, ValueError):
    layers = 0
if layers < 1:
    # Ноль слоёв на GPU = работа на CPU: лестница решений теряет смысл (латентность), и это надо
    # назвать причиной, а не «недоступен».
    problems.append("на CPU (n_gpu_layers=0) — лестница решений отключается, ход уходит в облако")
print("; ".join(problems) if problems else "ok")
' 2>/dev/null)"
  if [[ "$verdict" == "ok" ]]; then
    echo "[health-solver] ok"
  else
    echo "[health-solver] FAIL: ${verdict:-не удалось разобрать ответ}"
    why="${why}${verdict}, "
    fails=$((fails + 1))
  fi
fi

if [[ "$fails" -gt 0 ]]; then
  n=$(cat "$STATE_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_FILE"
  if [[ "$n" -ge 2 ]]; then
    healed="$(guard_heal)" || healed=""
    alert_send "[health-solver]" "решатель решений (solver) недоступен или деградировал (${n} проверок подряд): ${why%, }${healed:+; $healed} — пока он лежит, ходы идут в облако (дороже и медленнее)"
  fi
  # Код 1 — намеренно: сторож обязан быть виден в `systemctl --user --failed`.
  exit 1
fi

#: Долг 2: о ВОССТАНОВЛЕНИИ сообщаем так же, как об отказе. Зовётся ДО обнуления
#: счётчика — иначе «было N» уже неоткуда взять. Молчит, если отказа не было.
alert_recovered "[health-solver]" "решатель solver" "$STATE_FILE"
echo 0 > "$STATE_FILE"
exit 0
