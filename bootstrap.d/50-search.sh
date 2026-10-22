#!/usr/bin/env bash
# Поиск: свой инстанс и MCP-обёртка. Секрет инстанса обязан быть в .env проекта — иначе шаг откажет.
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SEARCH="$WORKSPACE/search"
[[ -d "$SEARCH" ]] || { echo "[50] каталога search нет — пропускаю"; exit 0; }
if [[ ! -f "$SEARCH/.env" ]]; then
  [[ "$CHECK" == "1" ]] && { echo "[50] проверка: search/.env создаст шаг 10"; exit 0; }
  echo "[50] ОСТАНОВ: нет search/.env — сначала шаг 10" >&2; exit 1
fi
if ! grep -qE '^SEARXNG_SECRET=.+' "$SEARCH/.env"; then
  echo "[50] ОСТАНОВ: в search/.env пустой SEARXNG_SECRET — секрет задаётся ЯВНО." >&2
  echo "     Сгенерировать: python3 -c \"import secrets; print(secrets.token_urlsafe(48))\"" >&2
  exit 1
fi
[[ "$CHECK" == "1" ]] && { echo "[50] проверка пройдена"; exit 0; }

#: ❗ Сеть платформы могла быть ПЕРЕСОЗДАНА (стек вендора сносят и поднимают заново). У остановленных
#: контейнеров проекта остаётся ссылка на удалённую сеть, и обычный `up` падает «network … not found».
#: Поэтому перед подъёмом снимаем контейнеры ЭТОГО проекта; тома и данные не трогаются.
drop_stale() {   # drop_stale <файл композа> <каталог проекта>
  local compose_file="$1" dir="$2"
  docker compose --project-directory "$dir" -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
}

drop_stale "$SEARCH/compose.search.yaml" "$SEARCH"
bash "$SEARCH/search-up.sh" up || exit 1
echo "[50] поиск поднят"
