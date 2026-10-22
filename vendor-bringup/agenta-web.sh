#!/usr/bin/env bash
# Веб-интерфейс Agenta (`web`) поверх уже поднятого стека.
#
#   bash infra/vendor-bringup/agenta-web.sh up               # поднять UI (только web, без web-mobile)
#   bash infra/vendor-bringup/agenta-web.sh up --with-mobile # + мобильный UI на /m (ещё ~250–450 МБ)
#   bash infra/vendor-bringup/agenta-web.sh pull             # спулить образ web (~0.5 ГБ)
#   bash infra/vendor-bringup/agenta-web.sh down             # остановить UI (освободить ~0.4 ГБ)
#   bash infra/vendor-bringup/agenta-web.sh status           # состояние + проверка адреса
#   bash infra/vendor-bringup/agenta-web.sh logs             # логи контейнера web
#
# Почему именно так:
#   * используем вендорный `run.sh --recreate <svc>` — он собирает ПОЛНЫЙ набор `-f`
#     (включая наш `infra/patches/compose.patches.yml`: лимиты RAM, телеметрия, монтирования патчей)
#     и выходит ДО сплошного `down`, поэтому остальной стек (api/services/runner/каналы) не перезапускается;
#   * `--no-pull` обязателен: образы в .env.oss.gh помечены `latest`, и без флага запуск
#     молча подтянет новые версии в живой стек;
#   * `web-mobile` профиля НЕ имеет (стартует всегда, порт `/m`) — его держим в 0 копий.
#
# ❗ Шаг D17: оверрайд стека больше НЕ генерируется в клон вендора — он наш (`infra/patches/compose.patches.yml`)
# и подключается ключом `--compose-file`; монтирования патчей берутся из `infra/patches/applied/`
# (собирает `infra/vendor-bringup/apply-vendor-patches.sh`, вызываем перед `up`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   #: корень воркспейса
AG="$ROOT/vendor/agenta"
OSS_DIR="$AG/hosting/docker-compose/oss"
COMPOSE_OVERRIDE="$ROOT/infra/patches/compose.patches.yml"
WEB_URL="http://127.0.0.1:8680/"
ACTION="${1:-status}"
WITH_MOBILE=0
for arg in "$@"; do [[ "$arg" == "--with-mobile" ]] && WITH_MOBILE=1; done

[[ -d "$AG" ]] || { echo "нет vendor/agenta — сначала: bash infra/vendor-bringup/vendor-agenta.sh"; exit 1; }
[[ -f "$COMPOSE_OVERRIDE" ]] || { echo "нет $COMPOSE_OVERRIDE — наш оверрайд стека (шаг D17)"; exit 1; }
# run.sh рассчитан на запуск из корня клона (относительные пути ./hosting/...),
# а compose-команды удобнее из каталога oss/ — поэтому две обёртки с нужным CWD.
compose() { (cd "$OSS_DIR" && docker compose --env-file .env.oss.gh -f docker-compose.gh.yml -f "$COMPOSE_OVERRIDE" "$@"); }
run_sh() { (cd "$AG" && bash hosting/docker-compose/run.sh "$@"); }

case "$ACTION" in
  pull)
    compose pull web
    ;;
  up)
    if ! docker image inspect ghcr.io/agenta-ai/agenta-web:latest >/dev/null 2>&1; then
      echo "[web] образа нет локально — тяну (--recreate образы НЕ тянет)"
      compose pull web
    fi
    # Патчи: собрать `infra/patches/applied/` — его монтирует оверрайд (шаг D17)
    bash "$ROOT/infra/vendor-bringup/apply-vendor-patches.sh"
    services=(web)
    [[ $WITH_MOBILE -eq 1 ]] && services+=(web-mobile)
    # run.sh принимает --recreate ПОВТОРЯЕМО (--recreate web --recreate web-mobile),
    # а не списком: два имени в одном флаге он отвергает (Unknown parameter).
    recreate_args=()
    for svc in "${services[@]}"; do recreate_args+=(--recreate "$svc"); done
    run_sh --oss --gh --no-pull --compose-file "$COMPOSE_OVERRIDE" "${recreate_args[@]}"
    echo "[web] жду готовности ${WEB_URL}"
    for i in $(seq 1 30); do
      # -L: UI отдаёт 308 с "/" на "/w" — это норма, значит фронт жив
      code=$(curl -s -L -o /dev/null -m 10 -w '%{http_code}' "$WEB_URL" || true)
      [[ "$code" == "200" ]] && { echo "[web] UI отвечает 200 (попытка $i)"; break; }
      sleep 3
    done
    [[ "${code:-000}" == "200" ]] || echo "[web] ВНИМАНИЕ: ответ ${code:-000} — смотри: bash infra/vendor-bringup/agenta-web.sh logs"
    compose ps web web-mobile
    ;;
  down)
    compose stop web web-mobile
    echo "[web] остановлено (освободили ~0.4 ГБ); поднять снова: bash infra/vendor-bringup/agenta-web.sh up"
    ;;
  status)
    compose ps web web-mobile 2>/dev/null || true
    code=$(curl -s -L -o /dev/null -m 10 -w '%{http_code}' "$WEB_URL" || true)
    echo "проверка $WEB_URL → HTTP ${code:-000}"
    docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' 2>/dev/null | grep -E 'web' || true
    ;;
  logs)
    compose logs --tail=80 web
    ;;
  *)
    echo "использование: bash infra/vendor-bringup/agenta-web.sh up|down|status|pull|logs [--with-mobile]"; exit 2
    ;;
esac
