#!/usr/bin/env bash
# status.sh — быстрый снимок состояния для владельца/разработчика.
set -uo pipefail
#: РУЧНОЙ инструмент (ни гейт, ни таймер его не зовут): одним взглядом — контейнеры и ошибки в логе.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/workspace.sh"
echo "== containers =="
docker compose --env-file "$WORKSPACE/.env" --env-file "$WORKSPACE/realty/.env" -f "$WORKSPACE/realty/compose.realty.yaml" ps 2>/dev/null || docker ps --format '{{.Names}}\t{{.Status}}'
echo
echo "== агента/раннер (глубже = вендор) =="
docker ps --format '{{.Names}}\t{{.Status}}' | grep -Ei 'runner|api|services|web' || true
echo
echo "== логи bridge: ошибки за сутки =="
docker compose --env-file "$WORKSPACE/.env" --env-file "$WORKSPACE/realty/.env" -f "$WORKSPACE/realty/compose.realty.yaml" logs --since 24h --no-color bridge 2>/dev/null | grep -iE 'error|traceback' | tail -20 || true
