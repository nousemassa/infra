#!/usr/bin/env bash
# Подъём воркспейса из ОДНИХ ЭТИХ репозиториев: раскладывает каталоги, окружение, вендорский стек,
# модели, поиск, продукты и обвязку — в том порядке, в котором они зависят друг от друга.
#
#   bash infra/bootstrap.sh                 # полный подъём (шаги 00…90)
#   bash infra/bootstrap.sh --check         # ничего не пишет и не поднимает: только проверки
#   bash infra/bootstrap.sh --only 40       # один шаг (можно несколько через запятую: --only 20,40)
#   bash infra/bootstrap.sh --skip 20       # пропустить шаги (например, вендора поднимают отдельно)
#
# **Зачем один вход.** Порядок здесь не косметика: сеть создаёт стек платформы, композы продуктов
# объявляют её внешней, а накат схемы ждёт свою базу. Собранный «по памяти» порядок уже давал отказ на
# пустом хосте («network … not found»), поэтому последовательность живёт в одном месте и проверяется.
#
# **Что нужно снаружи (в git этого не будет никогда):** клон вендора тянется сам по пину; исходники
# `llama.cpp` и решателя, файлы моделей и ключей, GPU/CUDA, доступ к `api.telegram.org` и провайдеру
# LLM, а также файлы-сессии Telegram — их либо переносят, либо входят заново.
set -uo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKSPACE
STEPS_DIR="$WORKSPACE/infra/bootstrap.d"

CHECK=0
ONLY=""
SKIP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --only) ONLY="${2:?--only требует список шагов}"; shift 2 ;;
    --skip) SKIP="${2:?--skip требует список шагов}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[bootstrap] неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

wanted() {   # wanted 20 → 1, если шаг входит в --only (или --only не задан) и не в --skip
  local n="$1"
  [[ -n "$ONLY" && ",$ONLY," != *",$n,"* ]] && return 1
  [[ -n "$SKIP" && ",$SKIP," == *",$n,"* ]] && return 1
  return 0
}

FAILED=0
for step in "$STEPS_DIR"/*.sh; do
  [[ -f "$step" ]] || continue
  n="$(basename "$step")"; n="${n%%-*}"
  wanted "$n" || continue
  echo
  echo "─── [$n] $(basename "$step" .sh) ───"
  args=()
  [[ "$CHECK" == "1" ]] && args+=(--check)
  if ! bash "$step" ${args[@]+"${args[@]}"}; then
    echo "[bootstrap] ОСТАНОВ: шаг $n завершился отказом. Причина названа выше." >&2
    FAILED=1
    break
  fi
done

echo
if [[ "$FAILED" == "0" ]]; then
  echo "[bootstrap] шаги пройдены. Дальше — проверка живого: make -C infra health"
else
  echo "[bootstrap] подъём НЕ завершён — исправьте причину и повторите (шаги идемпотентны)" >&2
  exit 1
fi
