#!/usr/bin/env bash
# Цели дампа: какие базы мы сохраняем и как до них дотянуться.
#
# **Почему один файл на два скрипта.** Дамп (`infra/db/db-dump.sh`) и учение восстановления
# (`infra/db/db-restore-drill.sh`) обязаны смотреть на ОДИН список баз: разойдись они — учение будет
# проверять не то, что мы сохраняем, и «восстановление прошло» станет правдой о другом наборе.
# Тот же приём, что `infra/lib/service_guard.sh` для сторожей и `infra/lib/dsn.sh` для адресов баз.
#
# **Почему адреса берутся из `.env`, а не из имени контейнера.** Имя проекта и суффикс `-1` — деталь
# развёртывания: поиск по имени даёт ложный алерт. Контейнер ищется по МЕТКАМ compose,
# а роль базы задаётся её URL из `.env` — единственным источником, который знает и хост, и пароль.
#
# **❗ Кто владеет базой — часть карты, а не догадка.** У каждой роли назван СВОЙ проект compose.
# Фолбэк «не нашли у себя ⇒ ищи в проекте вендора» делает худшее из возможного: учение
# восстановления создаёт и роняет проверочную базу ВНУТРИ postgres вендора, то есть заново заносит
# наши данные в стек вендора.
#
# Подключение:  source "$ROOT/infra/lib/db-targets.sh"
# Затем:        while IFS=$'\x1f' read -r role container db user password; do … done < <(db_targets)
#
# ⚠️ **Запускать ИЗ BASH.** Библиотека опирается на `BASH_SOURCE` (чтобы найти корень репозитория от
# собственного пути), поэтому из `zsh` она молча возвращает пустоту: команда «проходит», вывода нет,
# данные не меняются — и выглядит это как «ничего не нашлось», а не как ошибка: тот же вызов из bash
# даёт три базы, из zsh — ни одной строки.
set -uo pipefail

#: Роль → ПРОЕКТ compose → СЛУЖБА compose → переменная `.env` с адресом.
#: ❗ У каждого продукта СВОЙ экземпляр postgres в его композе, поэтому роль называет и проект, и службу,
#: и папку, где искать адрес. Общие базы (`vectors`, `reminders`) живут в корневом `.env`.
DB_ROLES="realty:realty:realty-db:DB_URL:realty \
news:news:news-db:DB_URL:news \
vectors:realty:pgvector:VECTOR_DB_URL: \
reminders:realty:reminders-db:REMINDERS_CHECKPOINT_DSN:"

#: Разделитель полей. ❗ НЕ табуляция: `read` с `IFS=$'\t'` СХЛОПЫВАЕТ подряд идущие разделители
#: (табуляция — IFS-пробельный символ), и пустое поле сдвигает все следующие: сообщение называет не ту
#: базу, а пользователя — паролем. `\x1f` (unit separator) не схлопывается.
DB_SEP=$'\x1f'

db_targets() {
  local root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local role project service variable url
  for entry in $DB_ROLES; do
    role="${entry%%:*}"; entry="${entry#*:}"
    project="${entry%%:*}"; entry="${entry#*:}"
    service="${entry%%:*}"; entry="${entry#*:}"
    variable="${entry%%:*}"; folder="${entry#*:}"
    #: Адрес продукта — в ЕГО `.env`; корневой — запасной источник для общих баз.
    url=""
    for candidate in ${folder:+"$root/$folder/.env"} "$root/.env"; do
      [[ -f "$candidate" ]] || continue
      url="$(sed -n "s/^${variable}=//p" "$candidate" | head -1 | tr -d '"'"'"'')"
      #: Прежнее имя ключа принимаем на переходный период: `DB_URL` — новое.
      [[ -z "$url" && "$variable" == "DB_URL" ]] && \
        url="$(sed -n "s/^BRIDGE_DB_URL=//p" "$candidate" | head -1 | tr -d '"'"'"'')"
      [[ -n "$url" ]] && break
    done
    if [[ -z "$url" ]]; then
      # Пустая цель: скрипт обязан назвать это словами, а не молча пропустить базу.
      printf '%s%s%s%s%s%s%s%s%s\n' "$role" "$DB_SEP" "" "$DB_SEP" "" \
        "$DB_SEP" "" "$DB_SEP" ""
      continue
    fi
    # Разбор URL — питоном: ручной разбор «//user:pass@host:port/db» уже ломается на паролях со спецсимволами.
    local parsed
    parsed="$(python3 - "$url" <<'PY'
import sys, urllib.parse
parts = urllib.parse.urlparse(sys.argv[1])
print("\x1f".join([
    urllib.parse.unquote(parts.username or ""),
    urllib.parse.unquote(parts.password or ""),
    (parts.hostname or ""),
    (parts.path or "").lstrip("/"),
]))
PY
)"
    local container
    # Только работающий контейнер СВОЕГО проекта: `docker ps` = running, метки — проект и служба.
    container="$(docker ps -q \
      --filter "label=com.docker.compose.project=${project}" \
      --filter "label=com.docker.compose.service=${service}" | head -1)"
    local user password _host db
    IFS=$'\x1f' read -r user password _host db <<<"$parsed"
    printf '%s%s%s%s%s%s%s%s%s\n' "$role" "$DB_SEP" "$container" "$DB_SEP" "$db" \
      "$DB_SEP" "$user" "$DB_SEP" "$password"
  done
}
