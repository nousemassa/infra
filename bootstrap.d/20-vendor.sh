#!/usr/bin/env bash
# Стек ПЛАТФОРМЫ: клон по пину → окружение вендора → наши патчи → запуск с нашим оверрайдом.
# Здесь же создаётся ОБЩАЯ СЕТЬ: её объявляет вендорский композ, а продукты подключаются к ней как к внешней.
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VB="$WORKSPACE/infra/vendor-bringup"
PROFILE="${VENDOR_PROFILE:-nano}"      #: nano|normal|comfort — профиль по памяти (см. run-agenta-lowram.sh)

# 1) платформа уже поднята? тогда только проверяем
if curl -fsS -m 3 "http://127.0.0.1:8680/api/health" >/dev/null 2>&1; then
  echo "  · платформа уже отвечает на 127.0.0.1:8680 — подъём не нужен"
  echo "[20] вендор уже работает"
  exit 0
fi

if [[ "$CHECK" == "1" ]]; then
  for f in vendor-agenta.sh prepare-agenta-env.sh apply-vendor-patches.sh run-agenta-lowram.sh; do
    [[ -f "$VB/$f" ]] && echo "  ✓ infra/vendor-bringup/$f" || { echo "  ✗ нет infra/vendor-bringup/$f" >&2; exit 1; }
  done
  [[ -f "$WORKSPACE/infra/patches/compose.patches.yml" ]] && echo "  ✓ infra/patches/compose.patches.yml"
  echo "[20] проверка пройдена (клон и запуск НЕ выполнялись)"
  exit 0
fi

[[ -f "$WORKSPACE/.env" ]] || { echo "[20] ОСТАНОВ: нет общей основы $WORKSPACE/.env — сначала шаг 10" >&2; exit 1; }

# 2) клон по пину (скрипт сам проверяет SHA и отказывает, если тег переехал)
bash "$VB/vendor-agenta.sh" || exit 1
# 3) окружение вендора: секреты + профиль памяти
bash "$VB/prepare-agenta-env.sh" || exit 1
# 4) наши патчи вендора → infra/patches/applied/ (проводка монтирований в compose.patches.yml)
bash "$VB/apply-vendor-patches.sh" || exit 1
# 5) запуск с нашим оверрайдом; сеть создаётся этим же стеком
bash "$VB/run-agenta-lowram.sh" "$PROFILE" || exit 1

# 6) ждём готовности API платформы (она нужна продуктам и регистрации объектов)
for i in $(seq 1 60); do
  if curl -fsS -m 5 "http://127.0.0.1:8680/api/health" >/dev/null 2>&1; then
    echo "  ✓ платформа отвечает (попытка $i)"
    echo "[20] вендор поднят"
    exit 0
  fi
  sleep 5
done
echo "[20] ОСТАНОВ: платформа не ответила за 300 с — смотрите docker logs agenta-oss-gh-api-1" >&2
exit 1
