#!/usr/bin/env bash
# УЧЕНИЕ ВОССТАНОВЛЕНИЯ: дамп не бэкап, пока его не восстановили.
#
# **Зачем.** Расписание дампа закрывает половину задачи: дамп может быть неполным, испорченным или
# несовместимым — и узнаётся это ровно в момент отката, когда узнавать поздно. Поэтому есть отдельный
# шаг, который разбирает последний набор обратно и СВЕРЯЕТ ФАКТ: точные счётчики строк каждой таблицы
# против манифеста, снятого в момент дампа.
#
# **Почему одноразовая база, а не боевая.** Восстановление «поверх» — это уничтожение данных под видом
# проверки. Порядок тот же, что у тестов SQL, — «своя база» (`bridge_test`):
# база `<база>_restore_check` создаётся, наполняется, сверяется и удаляется. Боевые базы шаг не трогает.
#
# **Почему сверяем `count(*)`, а не `pg_stat_user_tables`.** `n_live_tup` — ОЦЕНКА, её обновляет
# автоочистка; на ней проверка соврала бы в обе стороны.
#
#   bash infra/db/db-restore-drill.sh                       # последний набор (по LATEST.txt)
#   bash infra/db/db-restore-drill.sh <manifest.json>       # конкретный набор
set -euo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
source "$INFRA/lib/db-targets.sh"

DEST="${DUMP_DIR:-${DB_DUMP_DIR:-}}"
: "${DEST:?не задан DUMP_DIR — каталог с наборами дампов (тот же, что у db-dump.sh)}"
MANIFEST="${1:-}"
if [[ -z "$MANIFEST" ]]; then
  LATEST="$DEST/LATEST.txt"
  [[ -f "$LATEST" ]] || { echo "[drill] ОШИБКА: нет $LATEST — наборов нет" >&2; exit 1; }
  MANIFEST="$DEST/$(cat "$LATEST")"
fi
[[ -f "$MANIFEST" ]] || { echo "[drill] ОШИБКА: нет манифеста $MANIFEST" >&2; exit 1; }

COUNT_SQL="select relname || '|' || (xpath('/row/cnt/text()', query_to_xml(
  format('select count(*) as cnt from %I.%I', schemaname, relname), false, true, '')))[1]::text
  from pg_stat_user_tables order by relname;"

problems=0
#: ❗ Разделитель — `\x1f`, а не табуляция: `read` схлопывает ПОДРЯД идущие IFS-пробельные
#: разделители, и пустое поле сдвигало остальные (сообщение называло не ту базу).
while IFS=$'\x1f' read -r role container db user password; do
  [[ -n "$container" && -n "$db" ]] || { echo "[drill] ОШИБКА: база '$role' не найдена в .env/контейнерах" >&2; exit 1; }
  file="$(python3 - "$MANIFEST" "$role" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for item in data["databases"]:
    if item["role"] == sys.argv[2]:
        print(item["file"]); break
else:
    print("")
PY
)"
  if [[ -z "$file" || ! -f "$file" ]]; then
    echo "[drill] ОШИБКА: в наборе нет файла для '$role' — набор неполный" >&2
    problems=$((problems + 1)); continue
  fi

  # ❗ ПОЛОЖИТЕЛЬНАЯ ИДЕНТИФИКАЦИЯ СЕРВЕРА. Учение создаёт и роняет проверочную базу тем же
  # пользователем — если оно попадёт не на тот сервер, оно ЗАНОВО ЗАНЕСЁТ наши данные в чужой стек
  # (так и случилось бы после переезда базы `bridge`, пока карта целей искала проект вендора).
  server_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || true)"
  if [[ "$server_project" == "agenta-oss-gh" ]]; then
    echo "[drill] ОШИБКА: цель '$role' — контейнер ВЕНДОРСКОГО стека ($container). Наши базы там больше не живут;" >&2
    echo "[drill]         учение занесло бы их обратно. Проверьте карту в infra/lib/db-targets.sh и стек данных." >&2
    problems=$((problems + 1)); continue
  fi
  echo "[drill] $role → сервер проекта '${server_project:-?}' ($container), база $db"

  check="${db}_restore_check"
  # Пересоздаём одноразовую базу: остатки прошлого прогона не должны «засчитать» проверку.
  PGPASSWORD="$password" docker exec -e PGPASSWORD "$container" \
    psql -U "$user" -d postgres -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $check" \
    -c "CREATE DATABASE $check" >/dev/null

  restore_log="$(mktemp)"
  if ! PGPASSWORD="$password" docker exec -i -e PGPASSWORD "$container" \
        pg_restore -U "$user" -d "$check" --no-owner --no-privileges < "$file" >"$restore_log" 2>&1; then
    echo "[drill] ПРОВАЛ $role: pg_restore вернул ошибку — $file невосстановим:"
    head -3 "$restore_log" | sed 's/^/    /'
    problems=$((problems + 1))
    PGPASSWORD="$password" docker exec -e PGPASSWORD "$container" psql -U "$user" -d postgres -q -c "DROP DATABASE IF EXISTS $check" >/dev/null || true
    rm -f "$restore_log"; continue
  fi
  rm -f "$restore_log"

  expected="$(python3 - "$MANIFEST" "$role" <<'PY' | LC_ALL=C sort
import json, sys
data = json.load(open(sys.argv[1]))
for item in data["databases"]:
    if item["role"] == sys.argv[2]:
        for name, count in sorted(item["tables"].items()):
            print(f"{name}|{count}")
        break
PY
)"
  actual="$(PGPASSWORD="$password" docker exec -e PGPASSWORD "$container" \
            psql -U "$user" -d "$check" -tA -c "$COUNT_SQL" | LC_ALL=C sort)"

  if [[ "$expected" == "$actual" ]]; then
    echo "[drill] $role: восстановлено и сверено — таблиц $(printf '%s\n' "$expected" | grep -c '|'), строк $(printf '%s\n' "$expected" | awk -F'|' '{s+=$2} END {print s}')"
  else
    echo "[drill] ПРОВАЛ $role: счётчики строк разошлись (манифест против восстановленной базы):"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -8 | sed 's/^/    /'
    problems=$((problems + 1))
  fi
  PGPASSWORD="$password" docker exec -e PGPASSWORD "$container" \
    psql -U "$user" -d postgres -q -c "DROP DATABASE IF EXISTS $check" >/dev/null
done < <(db_targets "$WORKSPACE")

if (( problems > 0 )); then
  echo "[drill] НАРУШЕНО: $problems — набор $MANIFEST восстановить нельзя целиком" >&2
  exit 1
fi
echo "[drill] учение пройдено: все базы набора восстановлены и совпали с манифестом"
