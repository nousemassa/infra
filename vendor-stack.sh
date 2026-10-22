#!/usr/bin/env bash
# ЕДИНСТВЕННЫЙ владелец операции над стеком ВЕНДОРА: `up` · `down` · `status`.
#
# **Вендоры равноправны.** Скрипт параметризован вендором: его имя, каталог клона и оверлей берутся из
# одного места — `infra/vendors.tsv` и `vendor-compose/<вендор>.yml`. Нет «основного» и «второго»:
# у каждого вендора та же операция, тот же интерфейс и те же проверки.
#
# **Зачем один вход.** Операция многошаговая (префлайт → образ → подъём → готовность → замер), и делать
# её по памяти нельзя: пропущенный префлайт стоит падения посреди `up`, а пропущенный замер — тихого
# съедания памяти хоста.
#
# **Чего скрипт НЕ делает.** Он НЕ трогает `PLATFORM_VENDOR` и НЕ гасит другой стек — выбор вендора
# остаётся осознанным действием владельца, а не побочным эффектом подъёма стека.
#
# Запуск: `bash infra/vendor-stack.sh up|down|status [--no-pull]`
#         `VENDOR=openlit bash infra/vendor-stack.sh status`
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="$ROOT/infra"
source "$INFRA/lib/vendor.sh"

#: Вендор операции: явный `VENDOR=…` главнее оси из `.env`, ось — главнее значения таблицы.
VENDOR="${VENDOR:-$(sel="$(sed -n 's/^PLATFORM_VENDOR=//p' "$ROOT/.env" 2>/dev/null | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"; printf '%s' "${sel:-$(vendor_capability_default)}")}"
vendor_known "$VENDOR" || { echo "[stack] ОСТАНОВ: вендор $VENDOR неизвестен (известные: $(vendors_all))" >&2; exit 2; }

#: Каталог клона вендора: рядом с воркспейсом, имя — вендора (это ЕГО дерево, не наше).
VENDOR_DIR="${VENDOR_DIR:-$ROOT/vendor/$VENDOR}"
BASE_FILE="vendor/$VENDOR/docker-compose.yml"
OVERRIDE_FILE="infra/vendor-compose/$VENDOR.yml"
#: Стек вендора поднимаем МЫ только там, где у нас есть оверлей запуска. Иначе стек этого вендора
#: поднимается его собственным способом (в нашем случае — сценарием воркспейса), и операция неприменима.
#: Правило одинаково для всех вендоров: есть `vendor-compose/<вендор>.yml` — умеем, нет — называем причину.
if [[ ! -f "$ROOT/$OVERRIDE_FILE" ]]; then
  echo "[stack:$VENDOR] ОСТАНОВ: стек этого вендора поднимается не обвязкой — нет оверлея запуска" >&2
  echo "                  ($ROOT/$OVERRIDE_FILE). Для вендора, стек которого управляется нами, нужен этот файл." >&2
  exit 2
fi

#: ❗ Готовность — ДВА настоящих признака, оба ЗАМЕРЕНЫ на образе 2.1.0, а не взяты из документации:
#:   (1) штатный healthcheck самого вендора (`docker inspect .State.Health.Status` — он бьёт корень UI);
#:   (2) приём OTLP жив: `POST /v1/traces` отвечает (пустое тело даёт 200). Маршрута `/health` в этом
#:       образе НЕТ: `/health`, `/healthz`, `/api/health` отдают 404 — поэтому ждать `/health` нельзя.
RECEIVER_URL="http://127.0.0.1:4318/v1/traces"
UI_URL="http://127.0.0.1:3300"
#: Порты, которые НАШ оверрайд публикует на хост. Проверяются в префлайте: 3000 занят `mcp-searxng`,
#: поэтому UI публикуется на 3300; занятость любого порта из списка — названный отказ до подъёма.
HOST_PORTS=(3300 4318)
#: Порог префлайта по памяти. Считается от ИЗМЕРЕННОГО (MemAvailable), а не от суммы `mem_limit`:
#: сумма лимитов у нас заведомо больше свободной памяти и правилом быть не может.
MIN_FREE_MIB=2048

#: ❗ Политика перезапуска, ОБЪЯВЛЕННАЯ в оверлее вендора (`restart: unless-stopped`).
#: Живёт константой, потому что `docker update --restart=` НЕ меняет compose `config-hash`: после
#: остановки с политикой `no` (погашенный стек не должен подняться ребутом) `compose up -d`
#: политику НЕ возвращает, и стек молча остаётся непереживающим ребут при зелёном `status`.
#: Поэтому политику ставит `up`, а `status` сверяет её с этой константой — расхождение видно.
STACK_POLICY="unless-stopped"

#: Контейнеры стека этого вендора. У `openlit` их два (UI и ClickHouse), у других вендоров состав свой —
#: поэтому перечень задаётся данными вендора, а не литералами скрипта.
#: Главный контейнер стека (его healthcheck и есть готовность) — по вендору, не литералом.
stack_primary() {
  case "$VENDOR" in
    openlit) printf '%s' openlit ;;
    *) printf '%s' "$VENDOR" ;;
  esac
}

stack_containers() {
  case "$VENDOR" in
    openlit) printf '%s\n' clickhouse openlit ;;
    *) printf '%s\n' "$VENDOR" ;;
  esac
}

say() { echo "[stack:$VENDOR] $*"; }
stop_with() { echo "[stack:$VENDOR] ОСТАНОВ: $*" >&2; exit 2; }

#: Один вход к compose: порядок `-f` НЕСУЩИЙ (каталог проекта берётся от первого файла — от него зависят
#: относительные bind'ы `./assets/*` и имена томов). Обратный порядок даст пустой ClickHouse и новый SQLite.
compose() { ( cd "$ROOT" && docker compose -f "$BASE_FILE" -f "$OVERRIDE_FILE" "$@" ); }

#: Жив ли приём OTLP. Ждём НЕ 404: пустое тело даёт 200, а 404 означал бы, что маршрута нет.
receiver_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST \
        -H 'Content-Type: application/x-protobuf' --data-binary '' "$RECEIVER_URL" 2>/dev/null || true)"
  [[ "$code" != "404" && "$code" != "000" && -n "$code" ]]
}

free_mib() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }
swap_used_mib() { awk '/^SwapTotal:/ {t=$2} /^SwapFree:/ {f=$2} END {printf "%d", (t-f)/1024}' /proc/meminfo; }

preflight() {
  [[ -d "$VENDOR_DIR/.git" ]] || stop_with "нет клона вендора ($VENDOR_DIR) — положите его клон по этому пути"
  [[ -f "$ROOT/$OVERRIDE_FILE" ]] || stop_with "нет нашего конфига запуска ($OVERRIDE_FILE)"

  # Разбор и слияние. ❗ Наш оверрайд не проверяет НИ ОДИН гейт `make ci` (реестр композов его не знает),
  # поэтому единственное место, где он проверяется, — здесь. Без этого шага ошибка вида `mem_swap_limit`
  # всплыла бы только на `up`.
  compose config -q || stop_with "конфигурация не разбирается (см. вывод выше)"

  # ❗ Проверка портов пропускается, если стек УЖЕ поднят: тогда порты держат его же контейнеры, и «порт
  # занят» было бы ложным отказом на повторном `up` (переключатель вызывает нас идемпотентно).
  local stack_up=no
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$VENDOR" && stack_up=yes
  if [[ "$stack_up" == "no" ]]; then
    for port in "${HOST_PORTS[@]}"; do
      if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":$port\$"; then
        stop_with "порт $port занят — переназначьте в $OVERRIDE_FILE (кто держит: ss -lntp | grep :$port)"
      fi
    done
  else
    say "стек уже поднят — проверку портов пропускаю (их держат его же контейнеры)"
  fi

  local free; free="$(free_mib)"
  [[ "$free" =~ ^[0-9]+$ ]] || stop_with "не смог прочитать MemAvailable"
  (( free >= MIN_FREE_MIB )) || stop_with "свободно ${free} МиБ < порога ${MIN_FREE_MIB} МиБ — стек не поднимаю (STOP-LOSS по памяти)"
  say "префлайт ok: порты ${HOST_PORTS[*]} свободны, свободно ${free} МиБ, своп занят $(swap_used_mib) МиБ"
}

show_usage() {
  say "контейнеры:"
  for name in $(stack_containers); do
    local state policy
    # `tr -d '\n'`: `docker inspect` на отсутствующем контейнере печатает пустую строку, и подстановка
    # приносила перевод строки — вывод разваливался на два ряда.
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null | tr -d '\n' || true)"
    policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null | tr -d '\n' || true)"
    printf '  %-11s состояние=%-10s политика=%s\n' "$name" "${state:-нет}" "${policy:-—}"
    #: Работающий контейнер с политикой не из объявленной — «зелёный status, который соврёт на ребуте».
    if [[ "$state" == "running" && -n "$policy" && "$policy" != "$STACK_POLICY" ]]; then
      say "  ВНИМАНИЕ: $name работает с политикой '$policy', объявлена '$STACK_POLICY' — не переживёт ребут"
    fi
  done
  say "публикации:"
  # ❗ Без `^  `: docker НЕ печатает ведущие пробелы из `--format`, хотя они в шаблоне есть — первая
  # редакция грепа с якорем не находила НИЧЕГО и показывала «(нет)» при опубликованных портах.
  docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null | grep -E "^($(stack_containers | paste -sd'|'))" | sed 's/^/  /' || say "  (нет)"
  if receiver_ok; then say "приём OTLP: жив ($RECEIVER_URL)"
  else say "приём OTLP: НЕ отвечает ($RECEIVER_URL)"; fi
  if curl -fsS -m 5 -o /dev/null "$UI_URL" 2>/dev/null; then say "UI: $UI_URL отвечает"; else say "UI: $UI_URL не отвечает"; fi
  say "память: свободно $(free_mib) МиБ, своп занят $(swap_used_mib) МиБ"
  say "потребление стека:"
  docker stats --no-stream --format '{{.Name}}  {{.MemUsage}}  {{.MemPerc}}' 2>/dev/null \
    | grep -E "^($(stack_containers | paste -sd'|'))" | sed 's/^/  /' || say "  (стек не запущен)"
  #: ❗ Размеры ТОМОВ печатаем здесь: телеметрия не бэкапится, и единственная её проверка — вот эти два
  #: числа при каждом `status`.
  say "тома (docker system df -v):"
  docker system df -v 2>/dev/null \
    | awk -v p="${VENDOR}_" 'index($1, p) == 1 && $1 ~ /-data$/ {printf "  %-26s %s\n", $1, $3}' \
    || true
}

action_up() {
  preflight
  if [[ "${1:-}" != "--no-pull" ]]; then
    say "тяну образы (закреплённые в $OVERRIDE_FILE)…"
    compose pull --quiet || say "ВНИМАНИЕ: pull не удался — продолжаю, образ мог быть локально"
  fi
  say "поднимаю…"
  compose up -d || stop_with "up не удался (см. docker compose logs)"
  #: Политику ставим ЯВНО, сразу после `up`: см. комментарий у `STACK_POLICY`. Без этой строки
  #: `make stack-up` после любого `lower_stack` оставляет `no`, и «стек переживает ребут»
  #: становится ложью, которую не видит ни один сторож.
  local name
  for name in $(stack_containers); do
    if docker inspect "$name" >/dev/null 2>&1; then
      docker update --restart="$STACK_POLICY" "$name" >/dev/null 2>&1 \
        && say "политика $name → $STACK_POLICY" \
        || say "ВНИМАНИЕ: не удалось поставить политику $name=$STACK_POLICY"
    fi
  done
  # Готовность: ClickHouse инициализируется долго (`start_period: 100s`), потом воркер менеджера ждёт его.
  local waited=0 limit=300
  while (( waited < limit )); do
    local health; health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(stack_primary)" 2>/dev/null || echo none)"
    if [[ "$health" == "healthy" ]] && receiver_ok; then
      say "готов через ${waited} с: контейнер healthy, приём OTLP отвечает"
      show_usage
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  show_usage
  stop_with "приёмник не ответил за ${limit} с — смотрите: docker logs $(stack_primary)"
}

action_down() {
  # `stop`, а не `down`: пересоздание сети и томов не нужно, а `stop -t 60` даёт ClickHouse время свернуть
  # merge (по умолчанию SIGKILL через 10 с). Политика `unless-stopped` в нашем конфиге означает, что
  # остановленный стек НЕ поднимется после перезагрузки — это и требуется.
  for name in $(stack_containers); do
    if docker inspect "$name" >/dev/null 2>&1; then
      say "останавливаю $name (stop -t 60)…"
      docker stop -t 60 "$name" >/dev/null
    fi
  done
  show_usage
}

case "${1:-}" in
  up)   shift || true; action_up "${1:-}" ;;
  down) action_down ;;
  status) show_usage ;;
  *)    stop_with "использование: $0 up [--no-pull] | down | status" ;;
esac
