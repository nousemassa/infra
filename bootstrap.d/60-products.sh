#!/usr/bin/env bash
# Продукты: у каждого свой композ и СВОЯ база внутри него. Сеть уже создана стеком платформы (шаг 20).
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
failed=0
for product in realty news; do
  dir="$WORKSPACE/$product"
  [[ -d "$dir" ]] || { echo "  · каталога $product нет — пропускаю"; continue; }
  if [[ ! -f "$dir/.env" ]]; then
    [[ "$CHECK" == "1" ]] && { echo "  · $product: .env создаст шаг 10 — подъём пропущен"; continue; }
    echo "  ✗ нет $product/.env — сначала шаг 10" >&2; failed=1; continue
  fi
  if [[ "$CHECK" == "1" ]]; then
    echo "  · $product: окружение на месте"
    continue
  fi

#: ❗ Сеть платформы могла быть ПЕРЕСОЗДАНА (стек вендора сносят и поднимают заново). У остановленных
#: контейнеров проекта остаётся ссылка на удалённую сеть, и обычный `up` падает «network … not found».
#: Поэтому перед подъёмом снимаем контейнеры ЭТОГО проекта; тома и данные не трогаются.
drop_stale() {   # drop_stale <файл композа> <каталог проекта>
  local compose_file="$1" dir="$2"
  docker compose --project-directory "$dir" -f "$compose_file" down --remove-orphans >/dev/null 2>&1 || true
}

  echo "  · снимаю возможные устаревшие контейнеры $product (тома сохраняются)"
  drop_stale "$dir/compose.$product.yaml" "$dir"
  echo "  · поднимаю $product"
  bash "$dir/${product}-up.sh" up || { echo "  ✗ $product не поднялся" >&2; failed=1; }
done
[[ "$failed" == "0" ]] || { echo "[60] ОСТАНОВ: часть продуктов не поднялась" >&2; exit 1; }
echo "[60] продукты подняты"
