#!/usr/bin/env bash
# Итог: что живо и что осталось не поднятым. Отчёт — фактами, без «наверное».
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
echo "контейнеры:"
docker ps --format '  {{.Names}}\t{{.Status}}' 2>/dev/null | sort | head -40
echo
echo "адреса:"
for p in 8680 8082 8083 8085 8086 8087 8089; do
  printf '  %-6s ' "$p"
  if curl -fsS -m 3 "http://127.0.0.1:$p/health" >/dev/null 2>&1 || \
     curl -fsS -m 3 "http://127.0.0.1:$p/api/health" >/dev/null 2>&1; then echo ok; else echo "—"; fi
done
echo
[[ "$CHECK" == "1" ]] && { echo "[90] отчёт (проверка)"; exit 0; }
echo "сторожа:"
make -s -C "$WORKSPACE/infra" health 2>&1 | tail -8
echo "[90] отчёт собран"
