#!/usr/bin/env bash
# Обвязка: юниты и таймеры сторожей. До записи проверяются пути (install.sh --check-only).
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export AGENT_WORKSPACE="$WORKSPACE"
export MODELS_SRC="${MODELS_SRC:-${LLAMA_SRC:-$WORKSPACE/models-src}}"
export DB_DUMP_DIR="${DB_DUMP_DIR:-$WORKSPACE/dumps}"
export REBOOT_SNAPSHOT="${REBOOT_SNAPSHOT:-$WORKSPACE/dumps/reboot-snapshot.json}"
mkdir -p "$DB_DUMP_DIR" 2>/dev/null || true

if [[ ! -f "$WORKSPACE/.env" ]]; then
  [[ "$CHECK" == "1" ]] && { echo "[70] проверка: воркспейс (.env) создаст шаг 10 — раскладка юнитов отложена"; exit 0; }
  echo "[70] ОСТАНОВ: нет $WORKSPACE/.env — сначала шаг 10" >&2; exit 1
fi

echo "проверка путей юнитов:"
bash "$WORKSPACE/infra/systemd/install.sh" --check-only || exit 1
if [[ "$CHECK" == "1" ]]; then echo "[70] проверка пройдена (раскладка не тронута)"; exit 0; fi
bash "$WORKSPACE/infra/systemd/install.sh" || exit 1
echo "[70] обвязка разложена: юниты и таймеры включены"
