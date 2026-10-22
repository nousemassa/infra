#!/usr/bin/env bash
# Дамп ЧЕТЫРЁХ баз продукта: `realty`, `news`, `vectors`, `graph`.
#
# **Зачем.** Состояние продуктов живёт в четырёх базах PostgreSQL, и потеря каждой имеет свою цену.
# Хуже всего с `graph`: чекпойнты LangGraph —
# это потоки напоминаний, **ждущие ответа человека**; корпус `vectors` при потере переливкой воссоберётся,
# а ждущие потоки — нет.
#
# **Почему дамп снимается ИЗ КОНТЕЙНЕРА.** Хостового клиента PostgreSQL у нас нет, и заводить его ради
# дампа незачем: `pg_dump` есть внутри контейнеров баз. Пароль идёт переменной
# через `docker exec -e PGPASSWORD` (без `=значение`) — так он не попадает в аргументы команды.
#
# **Почему `LATEST.txt` переписывается ТОЛЬКО при полном успехе.** Частичный набор (одна база не снялась)
# не должен выглядеть как «последний»: иначе учение восстановления «пройдёт» по неполным данным, а
# настоящий откат окажется молча неполным. Ошибка здесь громкая и с названием базы.
#
#   bash infra/db/db-dump.sh                     # снять набор, обновить LATEST.txt, почистить старое
#   DUMP_KEEP=3 bash infra/db/db-dump.sh  # сколько наборов хранить (по умолчанию 14)
set -euo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
source "$INFRA/lib/db-targets.sh"

DEST="${DUMP_DIR:-${DB_DUMP_DIR:-}}"
: "${DEST:?не задан DUMP_DIR — каталог для дампов (вне репозитория, например /var/backups/product-dumps)}"
KEEP="${DUMP_KEEP:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
MANIFEST="$DEST/manifest-$STAMP.json"

# Точные счётчики строк по каждой таблице: `pg_stat_user_tables.n_live_tup` — ОЦЕНКА (её обновляет
# автоочистка), а сверять восстановление надо по факту. Приём со `query_to_xml` даёт `count(*)` без
# перечисления таблиц в коде: список таблиц не зашиваем, иначе новый DDL останется без сверки.
COUNT_SQL="select relname || '|' || (xpath('/row/cnt/text()', query_to_xml(
  format('select count(*) as cnt from %I.%I', schemaname, relname), false, true, '')))[1]::text
  from pg_stat_user_tables order by relname;"

mkdir -p "$DEST"
chmod 700 "$DEST"

sql_value() {   # $1 контейнер, $2 база, $3 пользователь, $4 пароль, $5 запрос
  PGPASSWORD="$4" docker exec -e PGPASSWORD "$1" psql -U "$3" -d "$2" -tA -c "$5"
}

entries=""
sizes_note=""
#: ❗ Разделитель — `\x1f`, а не табуляция: `read` схлопывает ПОДРЯД идущие IFS-пробельные
#: разделители, и пустое поле сдвигало остальные (сообщение называло не ту базу).
while IFS=$'\x1f' read -r role container db user password; do
  if [[ -z "$container" || -z "$db" ]]; then
    echo "[dump] ОШИБКА: база '$role' не найдена (нет контейнера или пуст адрес в .env)" >&2
    exit 1
  fi
  file="$DEST/$role-$STAMP.dump"
  echo "[dump] снимаю $role ($db) из контейнера ${container:0:12}…"
  # Пустой файл при сбое не оставляем: частичный дамп хуже отсутствующего — он выглядит как данные.
  if ! PGPASSWORD="$password" docker exec -e PGPASSWORD "$container" \
        pg_dump -U "$user" -d "$db" -Fc > "$file"; then
    rm -f "$file"
    echo "[dump] ОШИБКА: не удалось снять базу '$role' ($db)" >&2
    exit 1
  fi
  if [[ ! -s "$file" ]]; then
    rm -f "$file"
    echo "[dump] ОШИБКА: дамп базы '$role' пуст — считаю сбой, а не успех" >&2
    exit 1
  fi
  chmod 600 "$file"
  size="$(wc -c < "$file")"
  tables="$(sql_value "$container" "$db" "$user" "$password" "$COUNT_SQL")"
  # ❗ Пустая база даёт НЕНУЛЕВОЙ архив: проверка «файл не пуст» её пропускает, манифест получает 0
  # таблиц, `LATEST.txt` перезаписывается — и «дамп снят» становится ложью, на которой потом «проходит»
  # учение восстановления. Отказываем явно.
  if [[ "$(printf '%s\n' "$tables" | grep -c '|' || true)" == "0" ]]; then
    rm -f "$file"
    echo "[dump] ОШИБКА: в базе '$role' ($db) НОЛЬ таблиц — это не дамп данных, а пустая база (не та база? не тот сервер?)" >&2
    exit 1
  fi
  sizes_note="$sizes_note  $role: $((size / 1024)) КиБ, таблиц $(printf '%s\n' "$tables" | grep -c '|' || true)"$'\n'
  entries="$entries$role	$container	$db	$user	$file	$size	$(printf '%s' "$tables" | tr '\n' ';')"$'\n'
done < <(db_targets "$WORKSPACE")

# Манифест: набор становится САМООПИСУЮЩИМ — что снято, когда, размер и счётчики строк на момент дампа.
# По нему учение восстановления сверяет факт, не трогая источник: если дамп испорчен, счётчики разойдутся.
python3 - "$MANIFEST" "$STAMP" <<PY
import json, sys, pathlib
manifest, stamp = sys.argv[1], sys.argv[2]
items = []
for line in """$entries""".strip().splitlines():
    if not line.strip():
        continue
    role, container, db, user, file, size, tables = line.split("\t")
    items.append({
        "role": role, "container": container, "database": db, "user": user, "file": file,
        "bytes": int(size),
        "tables": {name: int(count) for name, count in
                   (pair.split("|") for pair in tables.split(";") if "|" in pair)},
    })
pathlib.Path(manifest).write_text(
    json.dumps({"stamp": stamp, "databases": items}, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[dump] манифест: {manifest} ({len(items)} баз)")
PY
chmod 600 "$MANIFEST"

# Порядок важен: сначала все три файла и манифест, и только потом указатель на «последний набор».
printf '%s\n' "manifest-$STAMP.json" > "$DEST/LATEST.txt"

# Ротация: держим KEEP последних наборов, остальное снимаем вместе с манифестами.
stamps_count="$(find "$DEST" -maxdepth 1 -name 'manifest-*.json' | sed 's/.*manifest-//; s/\.json$//' | sort -r | wc -l)"
if (( stamps_count > KEEP )); then
  find "$DEST" -maxdepth 1 -name 'manifest-*.json' | sed 's/.*manifest-//; s/\.json$//' | sort -r \
    | tail -n +$((KEEP + 1)) | while read -r old; do
        rm -f "$DEST"/*-"$old".dump "$DEST/manifest-$old.json"
        echo "[dump] убрал старый набор $old"
      done
fi

echo "[dump] готово, набор $STAMP:"
printf '%s' "$sizes_note"
