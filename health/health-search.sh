#!/usr/bin/env bash
# Сторож ПРОЕКТА ПОИСКА (`search`): движок и его MCP-обёртка — ОДИН сторож на пару.
#
#: **Зачем сторож у поиска.** Отказ поиска не роняет продукт: он ТИХО ухудшает ответы — инструмент отдаёт
#: пусто, выпуск выходит без свежих ссылок, и при этом все состояния зелёные. Поэтому у поиска свой сторож,
#: а не «проверим заодно с другими».
#
# **Почему ОДИН скрипт на две службы.** Обёртка без движка не работает: это одна возможность, а не
# две, и раздельные сторожа дали бы два алерта об одном и том же. Причина в тексте называет, ЧТО
# именно упало.
#
# **Что проверяется.** (1) контейнеры ОБЕИХ служб живы; (2) движок отвечает на НАСТОЯЩИЙ запрос —
# `/search?q=…&format=json`, тот же путь, которым ходит обёртка («порт открыт» о готовности движка
# не говорит); (3) `/health` обёртки отвечает и ГОВОРИТ `healthy` — этого адреса достаточно, чтобы
# отличить живую обёртку от зависшей.
#
# **Порог, дедуп и возврат (отличие от прочих сторожей, и это осознанно).** Первый фейл молчит
# (порог против дрожания). Начиная со второго — ЛЕЧЕНИЕ пробуется КАЖДЫЙ прогон, а АЛЕРТ уходит
# только когда набор причин ИЗМЕНИЛСЯ, плюс отдельное сообщение «восстановлен». Причина: у прочих
# сторожей счётчик без потолка, и при суточном отказе владелец с менеджерами получают ~288
# сообщений (образец дедупа — `infra/health/health-drift.sh`).
#
# **Названная граница.** Хостового ЮНИТА у проекта нет вовсе (поиск поднимается только контейнерами,
# `search/compose.search.yaml`). Если контейнеров нет совсем (проект не поднят или docker лежит),
# сторож говорит об этом СВОИМ текстом: `guard_where` назвал бы несуществующий юнит, а `guard_heal`
# вернул бы 1 молча. Поднять проект целиком — `bash search/search-up.sh`; это не дело сторожа.
set -uo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
SEARXNG_PORT="${SEARXNG_HOST_PORT:-8090}"
MCP_PORT="${MCP_SEARXNG_HOST_PORT:-3001}"
#: Обе службы публикуются ТОЛЬКО на loopback (см. композ), поэтому адреса с хоста.
SEARXNG_URL="http://127.0.0.1:${SEARXNG_PORT}/search?q=agent-health&format=json"
MCP_URL="http://127.0.0.1:${MCP_PORT}/health"

#: Проект и служба для общего помощника. ❗ Первые две строки — ЛИТЕРАЛЫ в начале строки: их читает
#: гейт разбора композов (берёт первое совпадение `^GUARD_*="…"`) и
#: сверяет с композом проекта. Переопределение ниже (`SEARCH_GUARD_PROJECT`) служит ТОЛЬКО пробе
#: ветки «проекта нет» и на гейт не влияет.
GUARD_PROJECT="search"
GUARD_SERVICE="searxng"
#: Юнита у проекта нет, но переменная обязана быть: помощник читает `$GUARD_UNIT` без `:-`, а
#: сторож идёт с `set -u` — без неё скрипт падает на первой же ветке (`service_guard.sh:49`).
GUARD_UNIT="search.service"
GUARD_URL="$SEARXNG_URL"
source "$INFRA/lib/service_guard.sh"
# ЕДИНЫЙ вход доставки алерта: мост → MTProto без моста → маркер.
source "$INFRA/lib/alert.sh"
GUARD_PROJECT="${SEARCH_GUARD_PROJECT:-$GUARD_PROJECT}"

STATE_FILE="${TMPDIR:-/tmp}/agent-health-search-fails"
# Алерт идёт через ОБЩИЙ вход (`infra/lib/alert.sh`): мост → MTProto без моста → маркер. Адрес моста
# берётся оттуда и уважает внешнее окружение — проба может подставить свой `BRIDGE_URL`, чтобы
# проверить ветку доставки, НЕ отправляя ложное «поиск недоступен» живым людям.

#: Адрес готовности службы — по нему помощник ждёт возвращения после лечения.
url_of() {
  case "$1" in
    searxng) printf '%s' "$SEARXNG_URL" ;;
    mcp-searxng) printf '%s' "$MCP_URL" ;;
  esac
}

fails=0
why=""

#: Проверка одной службы. Помощник читает `GUARD_*` В МОМЕНТ ВЫЗОВА, поэтому переопределение перед
#: каждым вызовом — штатный путь (см. `infra/lib/service_guard.sh`).
check_service() {
  local service="$1" name="$2" state health
  GUARD_SERVICE="$service"
  GUARD_URL="$(url_of "$service")"
  if ! guard_in_container; then
    echo "[health-search] FAIL: контейнер службы $service не найден — проект search не поднят?"
    why="${why}${name}: контейнера нет, "; fails=$((fails + 1)); return 0
  fi
  state="$(guard_state)"; health="$(guard_health)"
  if [[ "$state" != "running" ]]; then
    echo "[health-search] FAIL: $(guard_where) в состоянии $state"
    why="${why}${name}: $(guard_where) $state, "; fails=$((fails + 1))
  elif [[ "$health" != "healthy" && "$health" != "none" ]]; then
    echo "[health-search] FAIL: $(guard_where) health=$health"
    why="${why}${name}: health=$health, "; fails=$((fails + 1))
  fi
}

check_service searxng "движок"
check_service mcp-searxng "обёртка MCP"

# Движок — НАСТОЯЩИМ поиском: этим путём ходит обёртка, и пустой ответ на «порт открыт» не похож.
curl -fsS --max-time 20 "$SEARXNG_URL" >/dev/null 2>&1 \
  || { echo "[health-search] FAIL: JSON-поиск не отвечает на 127.0.0.1:${SEARXNG_PORT}";
       why="${why}JSON-поиск без ответа, "; fails=$((fails + 1)); }

#: Обёртка — по её собственному `/health` и с проверкой САМООТЧЁТА: 200 без `healthy` означал бы
#: «процесс жив, а поиск не готов».
payload="$(curl -fsS --max-time 10 "$MCP_URL" 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  echo "[health-search] FAIL: $MCP_URL недоступен"
  why="${why}нет ответа /health обёртки, "; fails=$((fails + 1))
else
  verdict="$(printf '%s' "$payload" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("невалидный JSON")
    raise SystemExit

status = str(data.get("status"))
print("ok" if status == "healthy" else "status=" + status)
' 2>/dev/null)"
  if [[ "$verdict" != "ok" ]]; then
    echo "[health-search] FAIL: обёртка отвечает, но ${verdict:-не удалось разобрать ответ}"
    why="${why}${verdict}, "; fails=$((fails + 1))
  fi
fi

#: Состояние: первая строка — счётчик подряд, вторая — ПОДПИСЬ последнего сообщённого набора причин.
state_count() { sed -n 1p "$STATE_FILE" 2>/dev/null | tr -d '\n'; }
state_sig() { sed -n 2p "$STATE_FILE" 2>/dev/null | tr -d '\n'; }

if [[ "$fails" -gt 0 ]]; then
  n=$(( $(state_count || echo 0) + 1 ))
  signature="${why%, }"
  prev="$(state_sig)"
  printf '%s\n%s\n' "$n" "$prev" > "$STATE_FILE"

  if [[ "$n" -ge 2 ]]; then
    # Лечим КАЖДЫЙ прогон (служба обязана вернуться сама), а сообщаем — только про НОВУЮ причину.
    healed=""
    for service in searxng mcp-searxng; do
      GUARD_SERVICE="$service"; GUARD_URL="$(url_of "$service")"
      part="$(guard_heal)" && healed="${healed}${healed:+; }${part}"
    done
    if [[ "$signature" != "$prev" ]]; then
      alert_send "[health-search]" "поиск недоступен (${n} проверок подряд): ${signature}${healed:+; $healed}"
      alert_send "[health-search]" "следствие: выпуск новостей идёт без свежих ссылок, у шлюза платформы инструмент поиска отдаёт пусто — поднять проект: bash search/search-up.sh"
      printf '%s\n%s\n' "$n" "$signature" > "$STATE_FILE"
    else
      echo "[health-search] причина та же, что в прошлом сообщении — повторный алерт не отправляю"
    fi
    [[ -n "$healed" ]] && echo "[health-search] лечение: $healed"
  fi

  # Последняя строка — ИТОГ с отказом: её берёт ребут-чек (`infra/checks/reboot-roundtrip.sh`), а строку
  # алерта он бы показал вердиктом.
  echo "[health-search] FAIL: поиск недоступен — ${signature}"
  # Код 1 — намеренно: сторож обязан быть виден в `systemctl --user --failed`. На гейт выката моста
  # он не влияет (`infra/health/health.sh` — отдельный скрипт и отдельный юнит).
  exit 1
fi

if [[ -n "$(state_sig)" ]]; then
  alert_send "[health-search]" "поиск восстановлен: движок отвечает на поиск, обёртка — healthy"
fi
echo "[health-search] ok"
printf '0\n\n' > "$STATE_FILE"
exit 0
