#!/usr/bin/env bash
# Предполётный гейт схемы: базы продуктов (`realty`, `news`) + векторная база RAG (`vectors`).
#
# Сам DDL живёт ОДНИМ источником — в реестре компонентов наката (`agent_core/db/registry.py`,
# `realty_agent/db/registry.py`, `news_agent/db/registry.py`), поэтому скрипт только ПРОВЕРЯЕТ, что накат
# применился: второй копии SQL быть не должно (иначе «источник правды» разъезжается).
#
# Запуск ДО рестарта моста: `bash db/schema-gate.sh` (только чтение, ничего не меняет).
#
# **Проверяем по базе ВЛАДЕЛЬЦА, а не одну общую.** Базы у продуктов разные и адрес у каждой свой —
# в `.env` своего продукта. Компоненты наката (они же проверки) распределены так:
#   `realty`  → `core`, `runtime`, `realty`   (`realty_agent.db.migrate --components core,runtime,realty,vectors`)
#   `news`    → `core`, `news`                (`news_agent.db.migrate --components core,news`)
#   `vectors` → `vectors`                     (векторный корпус RAG)
# `core` накатывается в ОБЕ базы продукта: это механизм, нужный и мосту, и новостям, а не общая база.
#
# Векторная база проверяется здесь же, а не отдельным скриптом: иначе получилась бы база,
# прикрученная сбоку, поломку в которой видно только по пустой выдаче в бою. Проверки и
# ожидаемое число тоже читаются из модулей владельцев — у гейта и у наката один источник.
set -euo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
#: Адреса баз (роль → контейнер, база, пользователь, пароль) — из `.env` через общий список целей:
#: своя копия «как дотянуться до базы» разошлась бы с дампом и учением восстановления.
source "$INFRA/lib/db-targets.sh"

PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
  if [[ -x "$WORKSPACE/.venv/bin/python" ]]; then PY="$WORKSPACE/.venv/bin/python"; else PY="python3"; fi
fi
export PYTHONPATH="$WORKSPACE/core:$WORKSPACE/realty:$WORKSPACE/news:${PYTHONPATH:-}"
py_const() { "$PY" -c "import $1 as r; print(getattr(r, '$2'))"; }

#: Компонент наката → модуль продукта, который объявляет ЕГО проверку.
declare -A MODULE=(
  [core]=agent_core.db.schema_core
  [runtime]=agent_core.db.schema_runtime
  [realty]=realty_agent.db.schema
  [news]=news_agent.db.schema
)
#: Роль базы → компоненты, которые в ней обязаны быть.
declare -A COMPONENTS=(
  [realty]="core runtime realty"
  [news]="core news"
)

#: Запрос проверки и ожидаемое число берутся у владельца схемы по имени компонента.
check_sql() { py_const "${MODULE[$1]}" SCHEMA_CHECK_SQL; }
check_expected() { py_const "${MODULE[$1]}" SCHEMA_CHECK_EXPECTED; }

VECTOR_SQL="$(py_const agent_core.db.schema VECTOR_SCHEMA_CHECK_SQL)"
VECTOR_EXPECTED="$(py_const agent_core.db.schema VECTOR_SCHEMA_CHECK_EXPECTED)"
VECTOR_HINT="$(py_const agent_core.db.schema VECTOR_SCHEMA_CHECK_HINT)"

#: Схема проверяется по владельцам: у каждого свой запрос и своё ожидаемое число проверок.
#: ❗ Список целей читаем в переменную ДО цикла: `docker exec -i` внутри цикла съел бы stdin потока целей
#: и проверка остановилась бы на первой же базе, оставшись зелёной.
TARGETS="$(db_targets "$WORKSPACE")"
bad=0
failed_roles=""
while IFS=$'\x1f' read -r role container db user password; do
  case "$role" in
    realty|news|vectors) ;;
    *) continue ;;
  esac
  if [[ -z "$container" || -z "$db" ]]; then
    echo "[migrate] FAIL: база '$role' не найдена (нет контейнера или пуст адрес в .env)" >&2
    exit 1
  fi
  q() { PGPASSWORD="$password" docker exec -i -e PGPASSWORD "$container" \
          psql -q -v ON_ERROR_STOP=1 -U "$user" -d "$db" -tAc "$1" </dev/null; }

  if [[ "$role" == "vectors" ]]; then
    got="$(q "$VECTOR_SQL" 2>&1 || true)"
    #: Нечисло — это НЕ «схема неполная», а невыполненный запрос проверки: причину отказа надо назвать
    #: отдельно, иначе поломка самого запроса читалась бы как «база не накатана».
    if [[ ! "$got" =~ ^[0-9]+$ ]]; then
      echo "[migrate] FAIL: проверка векторной схемы не выполнилась ($got)" >&2
      bad=1; failed_roles="$failed_roles vectors"
    elif [[ "$got" != "$VECTOR_EXPECTED" ]]; then
      echo "[migrate] FAIL: векторная схема не применена ($got/$VECTOR_EXPECTED)." >&2
      echo "[migrate] Ожидается: $VECTOR_HINT" >&2
      bad=1; failed_roles="$failed_roles vectors"
    else
      echo "[migrate] vectors ok ($got/$VECTOR_EXPECTED: $VECTOR_HINT)"
    fi
    continue
  fi

  for name in ${COMPONENTS[$role]}; do
    expected="$(check_expected "$name")"
    got="$(q "$(check_sql "$name")" 2>&1 || true)"
    if [[ ! "$got" =~ ^[0-9]+$ ]]; then
      echo "[migrate] FAIL: проверка схемы $name в базе '$role' не выполнилась ($got)" >&2
      bad=1; failed_roles="$failed_roles $role"
    elif [[ "$got" != "$expected" ]]; then
      echo "[migrate] FAIL: схема $name в базе '$role' не применена полностью (проверок $got/$expected)." >&2
      bad=1; failed_roles="$failed_roles $role"
    else
      echo "[migrate] $role schema $name ok ($got/$expected)"
    fi
  done
done <<<"$TARGETS"

#: Лечение называется по ОТКАЗАВШЕЙ базе: у каждой свой накат (`migrate` своего проекта), и совет
#: «прогони накат всего» отправил бы человека править базу, с которой всё в порядке.
if [[ "$bad" -ne 0 ]]; then
  for role in realty news; do
    [[ " $failed_roles " == *" $role "* ]] || continue
    echo "[migrate] Лечение: docker compose -f \"$WORKSPACE/$role/compose.$role.yaml\" run --rm migrate" >&2
  done
  #: Векторная база живёт в стеке `realty`, и её схему накатывает ЕГО `migrate` (`--components vectors`):
  #: отдельного лечения у вектора нет, иначе за одну базу отвечали бы двое.
  [[ " $failed_roles " == *" vectors "* ]] && \
    echo "[migrate] Лечение: docker compose -f \"$WORKSPACE/realty/compose.realty.yaml\" run --rm migrate" >&2
  exit 1
fi

echo "[migrate] итого: базы realty/news/vectors — все компоненты наката на месте"
