#!/usr/bin/env bash
# Low-RAM запуск стека Agenta (итоги аудита R11).
#
#   PROFILE=nano      — минимум RAM (~3.0–3.4 ГиБ с UI): + web-интерфейс (WITH_WEB=1), без composio, пул 1, TTL 5 мин
#   PROFILE=normal    — рабочий (~3.6–4.0 ГиБ с UI): пул 2–3, TTL 15 мин, warm-путь
#   PROFILE=comfort   — как в плане, но требует ≥8 ГиБ свободных
#
# Использование:  bash infra/vendor-bringup/run-agenta-lowram.sh nano
#
# ❗ Шаг D17: наш оверрайд стека (лимиты RAM, блокировка телеметрии, `command` для `api`) больше НЕ
# генерируется ВНУТРЬ клона вендора. Он лежит у нас — `infra/patches/compose.patches.yml` — и подключается
# штатным ключом вендора `--compose-file`. Туда же переехали монтирования патчей, а их ИСТОЧНИК —
# каталог `infra/patches/applied/`, который собирает `infra/vendor-bringup/apply-vendor-patches.sh` (здесь вызывается до
# `up`). Причина: раньше оверрайд жил в `vendor/` (в `.gitignore`) и свежий клон терял проводку МОЛЧА.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   #: корень воркспейса
AG="$ROOT/vendor/agenta"
PROFILE="${1:-nano}"
COMPOSE_OVERRIDE="$ROOT/infra/patches/compose.patches.yml"

[[ -d "$AG" ]] || { echo "нет vendor/agenta — сначала: bash infra/vendor-bringup/vendor-agenta.sh"; exit 1; }
[[ -f "$COMPOSE_OVERRIDE" ]] || { echo "нет $COMPOSE_OVERRIDE — это наш оверрайд стека (шаг D17)"; exit 1; }

case "$PROFILE" in
  nano)
    export AGENTA_RUNNER_SESSION_POOL_MAX=1
    export AGENTA_RUNNER_SESSION_TTL_MS=300000
    export AGENTA_RUNNER_SESSION_KEEPALIVE=off
    export AGENTA_RUNNER_CONCURRENCY_LIMIT=4
    EXTRA=(--no-web --no-tunnel)
    ;;
  normal)
    export AGENTA_RUNNER_SESSION_POOL_MAX=3
    export AGENTA_RUNNER_SESSION_TTL_MS=900000
    export AGENTA_RUNNER_SESSION_KEEPALIVE=on
    export AGENTA_RUNNER_CONCURRENCY_LIMIT=6
    EXTRA=(--no-tunnel)
    ;;
  comfort)
    export AGENTA_RUNNER_SESSION_POOL_MAX=3
    export AGENTA_RUNNER_SESSION_TTL_MS=900000
    export AGENTA_RUNNER_SESSION_KEEPALIVE=on
    EXTRA=()
    ;;
  *) echo "PROFILE: nano|normal|comfort"; exit 2 ;;
esac

echo "[lowram] PROFILE=$PROFILE (pool=${AGENTA_RUNNER_SESSION_POOL_MAX}, ttl=${AGENTA_RUNNER_SESSION_TTL_MS}); дополнительные флаги: ${EXTRA[*]:-нет}"
echo "[lowram] swap 4 ГиБ обязателен; staged-start: сначала postgres+redis, затем api, затем runner"

# Патчи: собрать `infra/patches/applied/` ДО `up` — иначе docker молча создаст пустой каталог на месте
# bind-источника, и сервис сломается непонятно (а не «патч не применился»).
bash "$ROOT/infra/vendor-bringup/apply-vendor-patches.sh"

cd "$AG"
# --no-pull обязателен: теги образов в .env.oss.gh = latest, без флага запуск
# молча обновил бы живой стек (api/services/runner) на свежие latest.
bash hosting/docker-compose/run.sh --oss --gh --no-pull --compose-file "$COMPOSE_OVERRIDE" "${EXTRA[@]}"

# Веб-интерфейсы поднимаем поверх стека отдельным точечным запуском.
# По умолчанию поднимаем ОБА: мобильный UI (/m) — основной рабочий (в нём чат авторизован),
# десктопный (/w) — для просмотра конфигов/трейсов, доступен через «view=desktop».
#   WITH_WEB=0      — не поднимать UI вообще
#   WITH_MOBILE=0   — только десктопный UI
if [[ "${WITH_WEB:-1}" == "1" ]]; then
  WEB_ARGS=()
  [[ "${WITH_MOBILE:-1}" == "1" ]] && WEB_ARGS+=(--with-mobile)
  echo "[lowram] поднимаю UI Agenta: ${WEB_ARGS[*]:-только desktop}"
  bash "$ROOT/infra/vendor-bringup/agenta-web.sh" up "${WEB_ARGS[@]}" || echo "[lowram] предупреждение: UI не поднялся (стек работает)"
fi

echo
echo "[lowram] Проверка потребления:"
echo "  docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}'"
