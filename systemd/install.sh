#!/usr/bin/env bash
# Раскладка юнитов рабочей обвязки в пользовательский менеджер systemd — идемпотентно.
#
# Источник истины — ЭТА папка: в `~/.config/systemd/user/` попадают ОТРЕНДЕРЕННЫЕ копии (в юнитах вместо
# путей стоят подстановки, см. ниже), поэтому правка пути делается здесь, а не в чужом каталоге.
#
#   bash systemd/install.sh                    # разложить, daemon-reload, включить таймеры
#   bash systemd/install.sh --no-enable        # только разложить (без enable)
#   bash systemd/install.sh --check-only       # ТОЛЬКО проверка подстановок и путей, ничего не пишет
#   bash systemd/install.sh --workspace /путь  # воркспейс явно
#
# Подстановки в юнитах (нерешённая подстановка — отказ с её именем, а не пустой путь в systemd):
#   __WORKSPACE__   каталог воркспейса (там `.env` и каталоги продуктов)
#   __MODELS_SRC__  каталог с исходниками llama.cpp (хостовые службы моделей)
#   __DB_DUMPS__    каталог наборов дампов баз
#   __SNAPSHOT__    файл снимка состояния хоста для проверки перезагрузки
#
# Откат: вернуть прежние файлы из копий `*.bak-<таймстемп>`, затем
#   systemctl --user daemon-reload && systemctl --user restart <служба>
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

WORKSPACE=""
MODE="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-enable) MODE="no-enable" ;;
    --check-only) MODE="check" ;;
    --workspace) WORKSPACE="${2:?--workspace требует путь}"; shift ;;
    *) echo "[install] неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
  shift
done

#: Воркспейс по умолчанию — каталог выше репозитория обвязки: так выглядит обычная раскладка, где
#: обвязка лежит внутри воркспейса. Везде, где это не так, путь задаётся `--workspace` или
#: `AGENT_WORKSPACE`.
WORKSPACE="${WORKSPACE:-${AGENT_WORKSPACE:-$(cd "$SRC/../.." && pwd)}}"
MODELS_SRC="${MODELS_SRC:-}"
DB_DUMPS="${DB_DUMP_DIR:-}"
SNAPSHOT="${REBOOT_SNAPSHOT:-}"

#: Значения подстановок. Пустая обязательная подстановка — отказ: пустой `ExecStart` в systemd выглядит
#: как «служба не запускается», а причина не названа.
declare -A SUBST=(
  [__WORKSPACE__]="$WORKSPACE"
  [__MODELS_SRC__]="$MODELS_SRC"
  [__DB_DUMPS__]="$DB_DUMPS"
  [__SNAPSHOT__]="$SNAPSHOT"
)

#: `__SNAPSHOT__` и `__DB_DUMPS__` нужны не всем юнитам, поэтому проверяются только там, где встречаются.
render() {
  local file="$1" text name value
  text="$(cat "$file")"
  for name in "${!SUBST[@]}"; do
    [[ "$text" == *"$name"* ]] || continue
    value="${SUBST[$name]}"
    if [[ -z "$value" ]]; then
      echo "[install] ОТКАЗ: в $(basename "$file") есть $name, а значение не задано." >&2
      echo "          Задайте $(placeholder_env "$name") и повторите." >&2
      exit 2
    fi
    text="${text//$name/$value}"
  done
  printf '%s\n' "$text"
}

placeholder_env() {
  case "$1" in
    __WORKSPACE__) echo "AGENT_WORKSPACE (или --workspace)" ;;
    __MODELS_SRC__) echo "MODELS_SRC" ;;
    __DB_DUMPS__) echo "DB_DUMP_DIR" ;;
    __SNAPSHOT__) echo "REBOOT_SNAPSHOT" ;;
  esac
}

#: **Проверка «пути в юнитах совпадают с фактом» — ДО раскладки.** Перенос папки обвязки делает
#: `ExecStart` мёртвым, а systemd сообщает об этом только тем, что таймеры перестают срабатывать — молча.
#: Поэтому отказ называет юнит и путь. Проверяются ИСПОЛНЯЕМЫЕ пути (`.sh`/`.py`), `.env` воркспейса и
#: каталоги `WorkingDirectory`; логи и файлы моделей могут отсутствовать и не проверяются.
#: ❗ Пути берутся из ЗНАЧЕНИЙ директив, а не регуляркой по всему тексту юнита: иначе фрагменты путей из
#: комментариев красили бы зелёное дерево.
check_paths() {
  local file rendered unit path bad=0
  for file in "$SRC"/*.service; do
    unit="$(basename "$file")"
    rendered="$(render "$file")"
    while IFS= read -r path; do
      [[ -e "$path" ]] && continue
      echo "[install] ОТКАЗ: $unit ссылается на $path — файла нет" >&2
      bad=1
    done < <(sed -n 's/^ExecStart=[-@+!:]*//p' <<<"$rendered" | tr ' ' '\n' | grep -E '^/[^ ]+\.(sh|py)$' || true)
    while IFS= read -r path; do
      [[ -d "$path" ]] && continue
      echo "[install] ОТКАЗ: $unit задаёт WorkingDirectory=$path — каталога нет" >&2
      bad=1
    done < <(sed -n 's/^WorkingDirectory=//p' <<<"$rendered")
    while IFS= read -r path; do
      [[ -f "$path/.env" ]] && continue
      echo "[install] ОТКАЗ: $unit задаёт AGENT_WORKSPACE=$path, а воркспейса (.env) там нет" >&2
      bad=1
    done < <(sed -n 's/^Environment=AGENT_WORKSPACE=//p' <<<"$rendered")
  done
  if [[ "$bad" -ne 0 ]]; then
    echo "[install] Так выглядит неверный воркспейс или перенос папки обвязки. Симлинки и список включения НЕ тронуты." >&2
    exit 1
  fi
}

check_paths

if [[ "$MODE" == "check" ]]; then
  echo "[install] подстановки и пути сходятся: $(ls "$SRC"/*.service | wc -l) служб, $(ls "$SRC"/*.timer | wc -l) таймеров ✓"
  exit 0
fi

mkdir -p "$DEST"

#: Раскладка — РЕНДЕР, а не симлинк: в юнитах есть подстановки, и симлинк тянул бы в systemd литералы
#: `__WORKSPACE__`. Прежний файл сохраняется копией: молчаливая перезапись чужих правок неотличима от
#: «так и было».
for file in "$SRC"/*.service "$SRC"/*.timer; do
  name="$(basename "$file")"
  if [[ -e "$DEST/$name" && ! -L "$DEST/$name" ]]; then
    cp -f "$DEST/$name" "$DEST/$name.bak-$(date +%Y%m%d%H%M%S)"
    echo "[install] прежний $name сохранён как $name.bak-*"
  fi
  render "$file" > "$DEST/$name"
  rm -f "$DEST/$name.tmp"
  echo "[install] $DEST/$name обновлён"
done

systemctl --user daemon-reload

#: Юнит, чьи файлы сняты (переименование службы, удаление юнита), остаётся в памяти менеджера как
#: `not-found failed` и показывается как сломанный сторож. `daemon-reload` снимает файл, но не остаточное
#: состояние; его снимает `reset-failed` — и только у юнитов, которых больше нет на диске. Живой `failed`
#: (файл на месте) не трогаем: это настоящий отказ, и сторож обязан его показать.
clear_ghost_units() {
  local unit state ghosts=()
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    state="$(systemctl --user show -p LoadState --value "$unit" 2>/dev/null)"
    [[ "$state" == "not-found" ]] && ghosts+=("$unit")
  done < <(systemctl --user list-units --all --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
  if (( ${#ghosts[@]} == 0 )); then
    echo "[install] фантомов снятых юнитов нет"
    return 0
  fi
  systemctl --user reset-failed "${ghosts[@]}" >/dev/null 2>&1 || true
  echo "[install] снято остаточное состояние снятых юнитов: ${#ghosts[@]} (${ghosts[*]})"
}
clear_ghost_units

#: Проверка конечного состояния: живой `failed` — отказ установки, а не строка в журнале. Иначе
#: «разложил и включил» выглядит успехом при мёртвом стороже.
check_no_failed_units() {
  local left
  left="$(systemctl --user list-units --all --state=failed --no-legend --plain 2>/dev/null | wc -l || true)"
  if [[ "$left" == "0" ]]; then echo "[install] юнитов в failed: 0 ✓"; return 0; fi
  echo "[install] ОТКАЗ: $left юнитов в состоянии failed — разберитесь поимённо:" >&2
  systemctl --user list-units --state=failed >&2
  return 1
}

if [[ "$MODE" != "no-enable" ]]; then
  #: Список включения перечислен ЯВНО, поэтому новый таймер надо добавлять сюда: иначе скрипт разложит
  #: его и не включит. Служб в списке нет — они поднимаются контейнерами (`restart: unless-stopped`),
  #: а хостовая служба рядом с контейнером дала бы двух владельцев порта. Сторожевые таймеры остаются:
  #: таймер — расписание, порт он не держит, а его скрипт понимает оба режима (`lib/service_guard.sh`).
  systemctl --user enable --now bridge-health.timer \
    bridge-news-health.timer \
    bridge-mcp-health.timer \
    bridge-reminders-health.timer \
    bridge-embed-health.timer \
    bridge-solver-health.timer \
    bridge-search-health.timer \
    bridge-drift.timer \
    bridge-dump.timer \
    bridge-prompts.timer
  echo "[install] юниты включены:"
  systemctl --user list-timers --no-pager | grep -E "bridge|NEXT|timers listed" || true
fi

check_no_failed_units
