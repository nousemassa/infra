#!/usr/bin/env bash
# Проба оси наблюдаемости для вендора `agenta`: HTTP API платформы.
#
# **Почему отдельным файлом.** Проба у каждого вендора своя (свой путь здоровья), но ОБЯЗАТЕЛЬСТВО одно:
# файл с функцией `vendor_probe_telemetry` есть у каждого вендора из `vendors.tsv`. Сторож вызывает её по
# имени вендора — одинаково для всех; отсутствие файла — названный отказ.

vendor_probe_telemetry() {
  # Платформа — приёмник ЭТОЙ оси: спаны идут именно сюда, поэтому проверка не пропускается.
  if ! curl -fsS --max-time 8 "${API_URL%/api}/api/health" >/dev/null; then
    echo "[health] FAIL: api ${API_URL%/api}/api/health (ось наблюдаемости: $telemetry)"
    why="${why}api платформы не отвечает, "
    fails=$((fails + 1)); observer_failed=$((observer_failed + 1))
  fi
}
