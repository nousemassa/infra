#!/usr/bin/env bash
# Проба оси наблюдаемости для вендора `openlit`: стек и приём OTLP.
#
# **Почему отдельным файлом.** Проба у каждого вендора своя (свой путь проверки), но
# ОБЯЗАТЕЛЬСТВО одно: файл с функцией `vendor_probe_telemetry` есть у каждого вендора из `vendors.tsv`.
# Сторож вызывает её по имени вендора — одинаково для всех; отсутствие файла — названный отказ.

vendor_probe_telemetry() {
  # Признак живости — НЕ маршрут `/health` (в образе OpenLIT 2.1.0 его НЕТ: 404), а сам приём OTLP:
  # `POST /v1/traces` обязан ответить чем-то, кроме 404. Адрес читается С ПЕРЕОПРЕДЕЛЕНИЕМ: так
  # негативную пробу снимают, не гася стек.
  local receiver code container state health
  receiver="${TELEMETRY_OTLP_ENDPOINT:-$(sed -n 's/^TELEMETRY_OTLP_ENDPOINT=//p' "$WORKSPACE/.env" | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')}"
  # СТЕК: контейнеры живы и здоровы по СВОЕМУ healthcheck. Приёмник может отвечать, пока ClickHouse уже
  # умирает (запись пойдёт «в никуда»), поэтому одного приёмника мало.
  for container in openlit clickhouse; do
    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo none)"
    if [[ "$state" != "running" || ( "$health" != "healthy" && "$health" != "none" ) ]]; then
      echo "[health] FAIL: стек наблюдаемости — $container state=$state health=$health"
      why="${why}$container $state/$health, "
      fails=$((fails + 1)); observer_failed=$((observer_failed + 1))
    else
      echo "[health] стек наблюдаемости: $container running/$health"
    fi
  done
  receiver="${receiver:-http://127.0.0.1:4318/v1/traces}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
        -H 'Content-Type: application/x-protobuf' --data-binary '' "$receiver" 2>/dev/null || true)"
  if [[ "$code" == "404" || "$code" == "000" || -z "$code" ]]; then
    echo "[health] FAIL: приём наблюдаемости не отвечает ($receiver → код ${code:-нет})"
    why="${why}приём $receiver не отвечает, "
    fails=$((fails + 1)); observer_failed=$((observer_failed + 1))
  else
    echo "[health] приём наблюдаемости проверен: $receiver → код $code"
  fi
}
