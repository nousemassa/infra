#!/usr/bin/env bash
# Предпосылки подъёма: инструменты, версия compose, GPU, место, каталоги. Ничего не меняет.
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
problems=0

need() {   # need <команда> <что это даёт>
  command -v "$1" >/dev/null 2>&1 && { echo "  ✓ $1"; return 0; }
  echo "  ✗ нет '$1' — $2" >&2; problems=$((problems+1)); return 1
}

echo "предпосылки:"
need docker "без него не поднять ни одну службу"
need git "клон вендора по пину"
need python3 "окружение и регистрация объектов"
if docker compose version >/dev/null 2>&1; then
  v="$(docker compose version --short 2>/dev/null | tr -d 'v')"
  echo "  ✓ docker compose $v"
  # 2.29 нужен для `deploy.resources.reservations.devices` (gpus: появился только в 2.30)
  [[ "$(printf '%s\n2.29\n' "$v" | sort -V | head -1)" == "2.29" ]] || { echo "  ✗ compose $v старее 2.29 — GPU-резервирование не поймётся" >&2; problems=$((problems+1)); }
else
  echo "  ✗ нет плагина 'docker compose' (v2)" >&2; problems=$((problems+1))
fi
docker info >/dev/null 2>&1 && echo "  ✓ демон docker отвечает" || { echo "  ✗ демон docker не отвечает" >&2; problems=$((problems+1)); }
command -v nvidia-smi >/dev/null 2>&1 && echo "  ✓ nvidia-smi" || echo "  · nvidia-smi нет — модели поднимутся только на CPU или будут пропущены"
free_gib=$(df -Pk "$WORKSPACE" | awk 'NR==2{printf "%d", $4/1024/1024}')
echo "  · свободно на диске: ${free_gib} ГиБ (вендор ~4 ГиБ образов + модели)"
mem_gib=$(awk '/MemAvailable/{printf "%d", $2/1024/1024}' /proc/meminfo)
echo "  · доступно памяти: ${mem_gib} ГиБ (профиль nano вендора ≈3,4 ГиБ, плюс службы)"
echo "  · каталог воркспейса: $WORKSPACE"

if [[ "$problems" != "0" ]]; then
  echo "[00] ОСТАНОВ: предпосылок не хватает: $problems" >&2
  exit 1
fi
echo "[00] предпосылки на месте"
