#!/usr/bin/env bash
# Проект `__PROJECT__`: поднять, посмотреть, остановить. Свой лончер — потому что проект должен
# подниматься и проверяться БЕЗ воркспейса (правило 5 контракта: лончер, `Makefile`, `README`).
#
#   bash __PROJECT__/__PROJECT__-up.sh            # поднять и дождаться готовности
#   bash __PROJECT__/__PROJECT__-up.sh status     # состояние
#   bash __PROJECT__/__PROJECT__-up.sh stop       # остановить (данные и тома НЕ трогаются)
#
# **Чего лончер НЕ делает намеренно:** `down` и `--remove-orphans`. Откат — всегда `stop`: `down` снёс бы
# базы, а `--remove-orphans` мог бы забрать службы соседних проектов из общей сети.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$PROJECT_DIR/.." && pwd)"
COMPOSE="$PROJECT_DIR/compose.__PROJECT__.yaml"
ENV_FILE="${__PROJECT___ENV:-$WORKSPACE/.env}"

[[ -f "$ENV_FILE" ]] || { echo "[__PROJECT__] ОСТАНОВ: нет файла окружения $ENV_FILE" >&2; exit 2; }
#: Адреса задаём ЯВНО (правило 3 контракта): значения для контейнера и для хоста разные, и «возьмётся из
#: общего `.env`» даёт молчаливую поломку — служба поднимается и не работает.
HOST_URL="${__PROJECT___HOST_URL:-http://127.0.0.1:__PORT__}"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE" "$@"; }

status() {
  local code
  code="$(curl -fsS -m 6 -o /dev/null -w '%{http_code}' "$HOST_URL/health" 2>/dev/null || echo '—')"
  printf '  %-28s %s\n' "__PROJECT__ (__PORT__)" "$code"
  compose ps --format 'table {{.Service}}\t{{.Status}}' | tail -n +2 | sed 's/^/  /' || true
  [[ "$code" == "200" ]]
}

case "${1:-up}" in
  status) status ;;
  stop)
    compose stop
    echo "[__PROJECT__] службы остановлены. Тома и данные не тронуты."
    ;;
  up|*)
    compose up -d
    for _ in $(seq 1 40); do status >/dev/null 2>&1 && { sleep 2; status; exit 0; }; sleep 3; done
    echo "[__PROJECT__] ОСТАНОВ: служба не ответила за 120 с — смотрите docker compose -f $COMPOSE logs" >&2
    exit 1
    ;;
esac
