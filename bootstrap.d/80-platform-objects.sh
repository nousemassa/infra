#!/usr/bin/env bash
# Объекты ПЛАТФОРМЫ, без которых продукты живут в режиме фолбэка: MCP-подключения и агенты-роли.
# Шаг идемпотентен и НЕ отказ, если ключей нет: тогда он говорит, какие ключи нужны.
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VB="$WORKSPACE/infra/vendor-bringup"
ENV_FILE="$WORKSPACE/.env"
missing=0
for key in PLATFORM_API_URL PLATFORM_API_KEY; do
  grep -qE "^${key}=.+" "$ENV_FILE" 2>/dev/null || { echo "  · нет $key в общей основе"; missing=1; }
done
if [[ "$missing" == "1" ]]; then
  echo "  · ПРОПУСК: регистрация объектов платформы требует PLATFORM_API_URL и PLATFORM_API_KEY"
  echo "[80] объекты платформы пропущены (ключи не заданы)"
  exit 0
fi
[[ "$CHECK" == "1" ]] && { echo "[80] проверка пройдена"; exit 0; }
for script in register-mcp.py register-search-mcp.py agent-roles-setup.py; do
  [[ -f "$VB/$script" ]] || { echo "  · нет $VB/$script"; continue; }
  echo "  · $script"
  python3 "$VB/$script" || echo "  · $script сообщил об отказе — см. вывод выше"
done
echo "[80] объекты платформы обработаны"
