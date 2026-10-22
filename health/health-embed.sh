#!/usr/bin/env bash
# Сторож СЕРВИСА ЭМБЕДДИНГОВ: здоровье контейнера → при 2 фейлах подряд алерт владельцу.
#
# **Зачем сторож, если есть docker.** `restart: unless-stopped` поднимает контейнер после падения, но
# НЕ лечит случай «контейнер стоит, потому что не смог занять порт» и ничего не
# говорит владельцу. Сторож закрывает оба разрыва: лечит и делает поломку видимой.
#
# **Что именно проверяется.** Здоровье контейнера: его healthcheck в `models/compose.models.yaml` задаёт два
# вопроса сразу — эмбеддинг считается ПО ДЕЛУ (значит модель загружена и ключ принят: без ключа этот
# путь отдаёт 401) и GPU действительно занят (`nvidia-smi`). Значит «контейнер healthy» здесь сильнее
# обычного «процесс ответил»: ни тихий CPU-фолбэк, ни служба без ключа в это состояние не попадают.
#
# **Почему алерт называет последствие.** Отказ эмбеддингов не роняет бота: ход деградирует в полнотекст
# (`dialog.py`, `pgvector.py`), новостной инструмент отдаёт пусто. Владельцу важно знать не «сервис лёг»,
# а «поиск без векторной половины» — иначе поломку примут за обычный ответ.
set -uo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
PORT="${EMBED_PORT:-8082}"
URL="http://127.0.0.1:${PORT}/health"
UNIT="llama-embed.service"
STATE_FILE="${TMPDIR:-/tmp}/agent-health-embed-fails"
# Сервис живёт КОНТЕЙНЕРОМ (`models/compose.models.yaml`). Режим определяет общий помощник — тот же, что
# у сторожей графа и MCP: копия этой логики в каждом стороже давала ложный алерт.
GUARD_CONTAINER="${EMBED_CONTAINER:-}"
GUARD_SERVICE="embed"
GUARD_PROJECT="models"
GUARD_UNIT="$UNIT"
GUARD_URL="$URL"
source "$INFRA/lib/service_guard.sh"
# ЕДИНЫЙ вход доставки алерта: мост → MTProto без моста → маркер.
source "$INFRA/lib/alert.sh"
# Доставка — ОБЩИЙ вход (`infra/lib/alert.sh`): мост → MTProto без моста → маркер+журнал.
# Мост здесь почтальон, а не проверяемый объект: его смерть больше не глушит алерт.

fails=0
why=""

if guard_in_container; then
  state="$(guard_state)"; health="$(guard_health)"
  if [[ "$state" != "running" ]]; then
    echo "[health-embed] FAIL: $(guard_where) в состоянии $state"
    why="${why}$(guard_where) $state, "; fails=$((fails + 1))
  elif [[ "$health" != "healthy" && "$health" != "none" ]]; then
    echo "[health-embed] FAIL: $(guard_where) health=$health"
    why="${why}$(guard_where) health=$health, "; fails=$((fails + 1))
  fi
else
  systemctl --user is-active --quiet "$UNIT" \
    || { echo "[health-embed] FAIL: юнит $UNIT не активен"; why="${why}юнит не активен, "; fails=$((fails + 1)); }
fi

payload="$(curl -fsS --max-time 8 "$URL" 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  echo "[health-embed] FAIL: $URL недоступен"
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
# Поля `service` у этого сервиса НЕТ: `llama-server` отдаёт ровно `{"status":"ok"}`.
# Роль «на нашем порту отвечает ИМЕННО наш сервис» здесь играет проверка здоровья контейнера из
# `models/compose.models.yaml`: её healthcheck спрашивает настоящий эмбеддинг (с ключом) и GPU — на чужого
# отвечающего это не пройдёт, а на «процесс жив, модель на CPU» не пройдёт тем более.
print("; ".join(problems) if problems else "ok")
' 2>/dev/null)"
  if [[ "$verdict" == "ok" ]]; then
    echo "[health-embed] ok"
  else
    echo "[health-embed] FAIL: ${verdict:-не удалось разобрать ответ}"
    why="${why}${verdict}, "
    fails=$((fails + 1))
  fi
fi

if [[ "$fails" -gt 0 ]]; then
  n=$(cat "$STATE_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STATE_FILE"
  if [[ "$n" -ge 2 ]]; then
    healed="$(guard_heal)" || healed=""
    alert_send "[health-embed]" "Сервис эмбеддингов недоступен (${n} проверок подряд): ${why%, }${healed:+; $healed}"
    alert_send "[health-embed]" "Следствие: поиск идёт без векторной половины (деградация в полнотекст), новостной инструмент отдаёт пусто."
  fi
  # Код 1 — намеренно: сторож обязан быть виден в `systemctl --user --failed`. На гейт выката моста
  # он не влияет (`infra/health/health.sh` — отдельный скрипт и отдельный юнит).
  exit 1
fi

#: Долг 2: о ВОССТАНОВЛЕНИИ сообщаем так же, как об отказе. Зовётся ДО обнуления
#: счётчика — иначе «было N» уже неоткуда взять. Молчит, если отказа не было.
alert_recovered "[health-embed]" "эмбеддинги" "$STATE_FILE"
echo 0 > "$STATE_FILE"
exit 0
