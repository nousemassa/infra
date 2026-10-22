#!/usr/bin/env bash
# Общий помощник сторожей: служба живёт КОНТЕЙНЕРОМ или юнитом.
#
# **Зачем один файл на всех.** Копия этой логики в каждом стороже даёт ложный алерт: сторож ГРАФА с
# шаблоном сторожа MCP сообщает «MCP-листенер недоступен», и владелец идёт смотреть не ту службу.
# Форма «что считать живым» должна быть одна.
#
# **Контейнер ищем по МЕТКАМ compose, а не по имени.** Имя проекта и суффикс `-1` — деталь
# развёртывания: поиск `realty-graph` не находит `…-graph-1`, и сторож продолжает проверять выключенный
# юнит (ещё один ложный алерт).
#
# **Оба режима обязательны.** В режиме юнита сторож проверяет юнит; в режиме контейнера — контейнер и
# лечит его `docker restart`. Переход между режимами и откат не должны требовать правок сторожа.
#
# Подключение:  source "$ROOT/infra/lib/service_guard.sh"   (сам подключает `lib/vendor.sh`:
#               режим вендора — один вход, и таблица возможностей одна на всех)
# Перед вызовом задать: GUARD_SERVICE (сервис в compose), GUARD_PROJECT (проект compose), GUARD_UNIT (юнит).
# Необязательно: GUARD_CONTAINER (имя контейнера, если метки не годятся).

#: Таблица вендоров и возможности — из одного места (`lib/vendor.sh`).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vendor.sh"

#: Имя контейнера службы (пустая строка — контейнера нет, значит режим юнита).
guard_container() {
  if [[ -n "${GUARD_CONTAINER:-}" ]]; then printf '%s' "$GUARD_CONTAINER"; return 0; fi
  docker ps -a \
    --filter "label=com.docker.compose.service=${GUARD_SERVICE}" \
    --filter "label=com.docker.compose.project=${GUARD_PROJECT}" \
    --format '{{.Names}}' 2>/dev/null | head -1
}

guard_in_container() {
  [[ -n "$(guard_container)" ]]
}

#: Состояние: running / exited / … (пусто — контейнера нет или docker недоступен).
guard_state() {
  local name; name="$(guard_container)"
  [[ -z "$name" ]] && return 0
  docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true
}

#: Здоровье контейнера. `none` — healthcheck не объявлен, и это НЕ повод считать службу больной.
guard_health() {
  local name; name="$(guard_container)"
  [[ -z "$name" ]] && return 0
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true
}

#: Кого проверяем — для текста алерта («контейнер X» или «юнит Y»).
guard_where() {
  if guard_in_container; then printf 'контейнер %s' "$(guard_container)"; else printf 'юнит %s' "$GUARD_UNIT"; fi
}

#: Лечение. Возвращает 1, если лечить нечего (служба и так живая) — иначе печатает, что сделал.
guard_heal() {
  local state health
  if guard_in_container; then
    state="$(guard_state)"; health="$(guard_health)"
    [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]] && return 1
    docker restart "$(guard_container)" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
      sleep 2
      curl -fsS --max-time 3 "${GUARD_URL:-}" >/dev/null 2>&1 && break
    done
    echo "контейнер $(guard_container) был не running/не healthy (state=$state health=$health) — выполнен docker restart"
    return 0
  fi
  [[ "$(systemctl --user is-failed "$GUARD_UNIT" 2>/dev/null)" == "failed" ]] || return 1
  systemctl --user reset-failed "$GUARD_UNIT" 2>/dev/null || true
  systemctl --user start "$GUARD_UNIT" 2>/dev/null || true
  for _ in $(seq 1 10); do
    sleep 2
    curl -fsS --max-time 3 "${GUARD_URL:-}" >/dev/null 2>&1 && break
  done
  echo "юнит $GUARD_UNIT был в failed — выполнен reset-failed + start"
}

# --- ВЕНДОР ПЛАТФОРМЫ ------------------------------------------------------------------------------
#
# **Зачем в общем помощнике.** Вендор выбирается ОДНОЙ настройкой (`PLATFORM_VENDOR` в корневом `.env`),
# и от него зависит, ЧТО существует в системе: у вендора без возможности `runtime` продуктовый контур
# погашен осознанно. Вендоры равноправны, различие — в таблице возможностей (`infra/vendors.tsv`), поэтому
# проверка идёт по ВОЗМОЖНОСТИ, а не по имени.

#: Режим платформы: вендор из таблицы; пусто ⇒ значение таблицы по умолчанию.
guard_vendor() {
  local vendor
  vendor="$(sed -n 's/^PLATFORM_VENDOR=//p' "$WORKSPACE/.env" 2>/dev/null | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  if [[ -n "$vendor" ]]; then printf '%s' "$vendor"; return 0; fi
  vendor_capability_default
}

#: Пропуск по режиму для ПРОДУКТОВЫХ сторожей. 0 — проверять нечего (причина НАЗВАНА), 1 — проверять надо.
#:
#: ❗ Звать ДО счётчика фейлов и ДО `guard_heal`. Иначе происходит вот что: контейнер погашен, но
#: `docker ps -a` его находит, `guard_state != running` даёт фейл, на втором тике уходит ЛОЖНЫЙ алерт
#: владельцу, а `guard_heal` делает `docker restart` — и ВОСКРЕШАЕТ то, что переключатель только что
#: погасил (съедая память, ради которой гасили). Проверено по коду: `guard_heal` рестартит безусловно.
#:
#: Молчаливого пропуска не бывает: строка печатается всегда — «молчание = ничего не произошло».
guard_skip_if_other_vendor() {
  local what="${1:-служба}" vendor
  vendor="$(guard_vendor)"
  [[ "$(vendor_capability "$vendor" runtime)" == "yes" ]] && return 1
  echo "[guard] $what не проверяется: у вендора $vendor нет возможности 'runtime' — контур остановлен осознанно"
  return 0
}
