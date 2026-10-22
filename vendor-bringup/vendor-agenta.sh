#!/usr/bin/env bash
# Клонирует Agenta на закреплённый релиз v0.121.5 (== main на 2026-09-28).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   #: корень воркспейса
DEST="$ROOT/vendor/agenta"
REF="v0.121.5"          # pinned: 99f85e3aff6f949f62adfe99f358993d80fb3aaf
SHA="99f85e3aff6f949f62adfe99f358993d80fb3aaf"

if [[ -d "$DEST/.git" ]]; then
  echo "[vendor] уже есть: $DEST — проверяю ревизию"
else
  mkdir -p "$(dirname "$DEST")"
  echo "[vendor] клонирую Agenta @ $REF"
  git clone --depth 1 --branch "$REF" https://github.com/Agenta-AI/agenta.git "$DEST"
fi

cd "$DEST"
CUR="$(git rev-parse HEAD)"
echo "[vendor] текущий HEAD: $CUR"
if [[ "$CUR" != "$SHA" ]]; then
  echo "[vendor] ВНИМАНИЕ: HEAD != ожидаемый $SHA (тег мог переехать) — зафиксируйте вручную"
  exit 2
fi
echo "[vendor] ok: $REF ($SHA)"
echo
echo "Дальше (D17) — два шага:"
echo "  1) bash infra/vendor-bringup/apply-vendor-patches.sh      # наложить наши патчи → patches/applied/"
echo "  2) bash infra/vendor-bringup/run-agenta-lowram.sh nano    # поднять стек (подаст наш patches/compose.patches.yml)"
