# Патч api-образа Agenta: публичный URL сервисов для браузера, внутренний — для вызовов

**Проблема (наша сборка, v0.121.5).** Платформа использовала ОДИН `AGENTA_SERVICES_URL` в двух ролях:
1. он попадает в **клиентские** payload'ы ревизий (`data.url`, `runnable`/deployment URL) — эти URL читает **браузер**;
2. им же пользуются **серверные** вызовы сервисов (`WorkflowService → services`).

Внутреннее значение (`http://services:8080/services`) браузер не резолвит (`ERR_NAME_NOT_RESOLVED`), а публичное
(`http://<IP>:8680/...`) не подходит из-за CORS: SDK сервисов ставит `allow_origins=["*"]` **вместе с**
`allow_credentials=True`, и браузер в таком случае принимает только **точно совпадающий origin**. Значит браузеру
нужен same-origin `http://localhost:8680/services/...`. Плюс URL **запекается** в ревизию при коммите.
Симптом: чат в UI read-only / «Message wasn't sent», в консоли CORS-ошибки или `ERR_NAME_NOT_RESOLVED`.

**Что делает патч.**
* `env.py`: добавлена `services_public_url` (`AGENTA_SERVICES_PUBLIC_URL`, по умолчанию = `services_url`), и она
  используется **только** при сборке клиентских URL (4 места в `core/workflows/service.py`).
* `core/workflows/service.py`: `_get_service_url()` прогоняет итоговый URL через `_to_internal_service_url()`,
  который переписывает хост на внутренний `AGENTA_SERVICES_URL`, сохраняя путь → серверные вызовы всегда внутренние.

**Как подключено (шаг D17).** Монтирования объявлены у нас — `patches/compose.patches.yml` (секции
`api`, `worker-queues`, `worker-streams`, `cron`), которое лончер подаёт вендорному `run.sh` ключом
`--compose-file`; там же сервисам задан `AGENTA_SERVICES_PUBLIC_URL=http://localhost:8680/services`.
Источник монтирования — **`patches/applied/`**: туда файлы кладёт `infra/vendor-bringup/apply-vendor-patches.sh`
(цель `make vendor-patches`), НАКЛАДЫВАЯ наше на текущий файл вендора трёхсторонним слиянием
(база — коммит вендора из `patches/patches.tsv`), а не подменяя его целиком. Прямой проводки в клоне
вендора больше нет: раньше оверрайд генерировался внутрь `vendor/` (в `.gitignore`) и свежий клон
терял его МОЛЧА.

**Как снять.** Убрать блоки `volumes:` (две строки `patches/applied/agenta-api/…`) и переменную
`AGENTA_SERVICES_PUBLIC_URL` у этих четырёх сервисов в `patches/compose.patches.yml` и строки патчей в
`patches/patches.tsv` — и пересоздать их. Патч нужен, пока upstream не разделит публичный и внутренний
адреса сервисов.

**Проверено (2026-10-01):** канальный путь (Telegram) отвечает после патча — новая сессия `a8678e09`, агент ответил
по нашим объектам; в ревизии `01a0f713` (`data.url`) — `http://localhost:8680/services/agent/v0` (same-origin).
