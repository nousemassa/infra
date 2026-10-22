#!/usr/bin/env bash
# Модели и GPU: образы собираются из исходников ВНЕ репозитория, поэтому шаг честно пропускается,
# если их нет, — и говорит, чего именно не хватает.
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODELS="$WORKSPACE/models"
[[ -d "$MODELS" ]] || { echo "[40] каталога models нет — пропускаю"; exit 0; }

need_src() { [[ -n "${!1:-}" && -d "${!1}" ]]; }
echo "модели:"
if ! need_src LLAMA_SRC; then
  echo "  · LLAMA_SRC не задан — образ эмбеддингов собрать нечем: задайте каталог llama.cpp"
fi
if ! need_src SOLVER_SRC; then
  echo "  · SOLVER_SRC не задан — образ решателя собрать нечем: задайте каталог решателя"
fi

if ! need_src LLAMA_SRC || ! need_src SOLVER_SRC; then
  if [[ "$CHECK" == "1" ]]; then echo "[40] проверка: исходников нет — шаг будет пропущен"; exit 0; fi
  echo "  · ПРОПУСК: сервисы моделей не поднимаются без исходников (это внешняя зависимость, не git)"
  echo "[40] модели пропущены (названная причина выше)"
  exit 0
fi
[[ "$CHECK" == "1" ]] && { echo "[40] проверка: исходники есть, можно собирать"; exit 0; }


#: ❗ Сеть платформы могла быть ПЕРЕСОЗДАНА (стек вендора сносят и поднимают заново). У остановленных
#: контейнеров проекта остаётся ссылка на удалённую сеть, и обычный `up` падает «network … not found».
#: Поэтому перед подъёмом снимаем контейнеры ЭТОГО проекта; тома и данные не трогаются.
drop_stale() {   # drop_stale <файл композа> <каталог проекта>
  local compose_file="$1" dir="$2"
  docker compose --project-directory "$dir" -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
}

drop_stale "$MODELS/compose.models.yaml" "$MODELS"
bash "$MODELS/embed-image.sh" || exit 1
bash "$MODELS/solver-image.sh" || exit 1
bash "$MODELS/gpu-up.sh" up || exit 1
echo "[40] модели подняты"
