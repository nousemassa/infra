#!/usr/bin/env bash
# ОКНО ДОЛГОВ: пауза сторожей на время правок + гарантированное возвращение их обратно.
#
# **Зачем отдельный скрипт.** Сторожа стоят на systemd-таймерах каждые 5 минут и УМЕЮТ ЛЕЧИТЬ
# (`guard_heal` делает `docker restart`) и АЛЕРТИТЬ. Поэтому:
#   * правка подключённой библиотеки (`infra/lib/alert.sh`) при живом таймере может совпасть с моментом
#     `source` — тогда `alert_send` не определён, и НАСТОЯЩИЙ алерт теряется ТИХО (только в journald);
#   * проба «останови контейнер и посмотри, что сторож сделает» лечится самим сторожем и врёт;
#   * пауза без предела означает контур БЕЗ НАБЛЮДЕНИЯ: падение моста в эти минуты заметит только владелец.
# Поэтому окно открывается явно, имеет предел и закрывается ЛЮБЫМ исходом (`trap … EXIT`).
#
#   bash infra/checks/debt-window.sh start    # погасить все таймеры, записать время открытия
#   bash infra/checks/debt-window.sh status   # открыто ли окно и сколько уже идёт
#   bash infra/checks/debt-window.sh finish   # обнулить счётчики, make health, make ci, вернуть таймеры
#
# ❗ Правило окна: правки, `bash -n`, пробы — внутри; `make health` и `make ci` — в конце; таймеры
# возвращаются ТОЛЬКО на выходе (в том числе при отказе).
set -uo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$INFRA/.." && pwd)"
STAMP="${TMPDIR:-/tmp}/agenta-debt-window-opened"
LIMIT_MIN="${DEBT_WINDOW_LIMIT_MIN:-30}"

#: ❗ Шаблон — `bridge-*`: так названы ВСЕ таймеры обвязки. Матчер на другом префиксе паузил бы
#: НИ ОДНОГО таймера и печатал «0 из 0» — ложная зелень.
TIMER_GLOB='bridge-*'
units() { systemctl --user list-units --type=timer --all --no-legend "$TIMER_GLOB" 2>/dev/null | awk '{print $1}'; }

#: Отсеиваем ФАНТОМЫ (`LoadState=not-found`: юнит снят, состояние осталось). `list-units --all`
#: показывает их как `failed`, и без фильтра `start` по такому имени заводит мусор заново.
timers() {
  local u
  for u in $(units); do
    [[ "$(systemctl --user show -p LoadState --value "$u" 2>/dev/null)" == "loaded" ]] && printf '%s\n' "$u"
  done
}

timers_active() {
  local u n=0
  for u in $(timers); do [[ "$(systemctl --user is-active "$u" 2>/dev/null)" == "active" ]] && n=$((n + 1)); done
  printf '%s' "$n"
}

timers_stop_all() { local u; for u in $(timers); do systemctl --user stop "$u" 2>/dev/null; done; }
timers_start_all() {
  #: Возвращаем РОВНО живые юниты (`LoadState=loaded`), а не всё, что `list-units --all` показал:
  #: фантом после переименования не должен «стартовать» снова.
  local u
  for u in $(timers); do systemctl --user start "$u" 2>/dev/null; done
}

zero_counters() {
  #: ❗ Счётчики фейлов переживают паузу (`Persistent=true` даёт догоняющий тик), и остаточная «1» плюс
  #: новый фейл дадут ложный алерт владельцу сразу после возврата таймеров.
  local f
  for f in "${TMPDIR:-/tmp}"/agent-health*-fails "${TMPDIR:-/tmp}"/agent-health*-state; do
    [[ -e "$f" ]] && : > "$f"
  done
  echo "[window] счётчики сторожей обнулены"
}

case "${1:-status}" in
  start)
    if [[ -e "$STAMP" ]]; then
      echo "[window] ОКНО УЖЕ ОТКРЫТО с $(date -Is -r "$STAMP") — сначала finish"; exit 2
    fi
    date -Is > "$STAMP"
    timers_stop_all
    active="$(timers_active)"
    echo "[window] таймеров активно после паузы: $active из $(timers | wc -l)"
    #: ❗ Пауза, которая не пауза, хуже её отсутствия: дальше идут правки сторожей и негативные пробы,
    #: и живой таймер (с `guard_heal` и алертом) превратит их в ложный алерт владельцу. Отказ громкий.
    if [[ "$active" != "0" ]]; then
      echo "[window] ОТКАЗ: после паузы активно $active таймеров — правки сторожей запрещены. Проверьте шаблон ($TIMER_GLOB)" >&2
      exit 2
    fi
    echo "[window] предел окна: $LIMIT_MIN мин. Закрыть: bash infra/checks/debt-window.sh finish"
    ;;
  status)
    if [[ -e "$STAMP" ]]; then
      local_secs=$(( $(date +%s) - $(date +%s -r "$STAMP") ))
      printf '[window] ОТКРЫТО %s мин назад; таймеров активно: %s из %s\n' \
        "$((local_secs / 60))" "$(timers_active)" "$(timers | wc -l)"
      (( local_secs > LIMIT_MIN * 60 )) && echo "[window] ВНИМАНИЕ: окно дольше предела — контур без наблюдения" >&2
      exit 0
    fi
    printf '[window] закрыто; таймеров активно: %s из %s\n' "$(timers_active)" "$(timers | wc -l)"
    ;;
  finish)
    #: Всё, что должно произойти при ЛЮБОМ исходе: счётчики, сторожа, таймеры.
    trap 'timers_start_all; echo "[window] таймеры возвращены: $(timers_active) из $(timers | wc -l)"' EXIT
    zero_counters
    echo "[window] сторожа целиком:"
    #: ❗ Код возврата читаем у `make`, а не у подстановки: `set -uo pipefail` здесь БЕЗ `-e`, поэтому
    #: красный `make health`/`make ci` иначе выглядел бы успехом окна (в этом проекте уже был случай,
    #: когда `rc` брали у `tail`, а не у скрипта).
    rc=0
    health_out="$( cd "$WORKSPACE" && make health 2>&1 )" || rc=1
    printf '%s\n' "$health_out" | grep -E '^\[|все сторожа|FAIL'
    echo "[window] гейт:"
    ( cd "$WORKSPACE" && make ci 2>&1 | tail -3 ) || rc=1
    rm -f "$STAMP"
    if (( rc != 0 )); then echo "[window] ВНИМАНИЕ: health или ci красные (rc=$rc) — окно закрыто, но контур не зелёный" >&2; fi
    exit "$rc"
    ;;
  *) echo "использование: $0 start|status|finish" >&2; exit 2 ;;
esac
