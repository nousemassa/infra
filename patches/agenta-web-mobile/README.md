# Патч `web-mobile` (мобильный UI на `/m`): согласование «полного меню»

> **✅ ВКЛЮЧЁН (2026-10-01, вечер-6) — рабочий статус проекта.**
> Смонтирован в сервис `web-mobile` (оверрайд + генератор) вместе с `patches/agenta-web` (там подробное
> обоснование: штатный Developer Mode у нас полное меню не даёт). Задача этого патча — не дать мобильному
> приложению публиковать cookie `agenta-classic-mode=0`, которая уводит браузер из десктопа.
> Снятие/возврат: см. «Как применено» / «Откат» ниже.

Тот же сдвиг, что в `patches/agenta-web/README.md` (см. там подробный разбор механики), но для
мобильного приложения. Нужен **не ради его сайдбара** — рельса `/m` жёстко ограничена
(Home · Agents · Automations · Skills · Sessions), и экранов Prompts / Evaluation / Observability в
мобильном приложении нет: `mobileRouteFor` в `agenta-shared/src/utils/mobileGate/index.ts`
намеренно возвращает `null` для `/prompts`, `/testsets`, `/evaluators`, `/evaluations`,
`/annotations`, `/variants` — «классический» гейт оставляет такие страницы на десктопе.

Патч нужен затем, что **оба** приложения публикуют cookie `agenta-classic-mode` из одной и той же
логики когорты: мобильное, посчитав `advancedNavHidden = true`, публикует `"0"` — и десктопный гейт
начинает уводить браузер из `/w` в `/m` на всех страницах, которые `/m` умеет показывать.
После сдвига константы в обоих приложениях preference не публикуется (`null` ⇒ «clear cookie»),
и десктоп с полным меню больше не перебивается.

## Что изменено

Мобильное приложение собрано Turbopack, имена чанков плоские. Одна и та же константа лежит в трёх
файлах — патчатся все три (два клиентских + один SSR, чтобы значения не расходились):

```
/app/mobile/.next/static/chunks/2y7q1do3_9dr7.js
/app/mobile/.next/static/chunks/2kynjz4a8nzi1.js
/app/mobile/.next/server/chunks/ssr/_0dcler-._.js
-  Date.parse("2026-08-01T00:00:00Z")
+  Date.parse("2099-01-01T00:00:00Z")
```

## Как применено (шаг D17)

Копии лежат рядом, а монтирования объявлены у нас — `patches/compose.patches.yml` (секция
`web-mobile`), которое лончер подаёт вендорному `run.sh` ключом `--compose-file`. Источник — каталог
**`patches/applied/`**, куда файлы кладёт `infra/vendor-bringup/apply-vendor-patches.sh` (цель `make vendor-patches`)
после проверки, что бандлы в образе — ТЕ САМЫЕ. Пересоздать оба UI:

```bash
cd "$WORKSPACE"   # каталог воркспейса: тот, в котором лежит infra/
bash infra/vendor-bringup/agenta-web.sh up --with-mobile
```

## Проверка

```bash
curl -s http://127.0.0.1:8680/m/_next/static/chunks/2y7q1do3_9dr7.js | grep -o 'Date.parse("20[0-9-]*T00:00:00Z")'
curl -s http://127.0.0.1:8680/m/_next/static/chunks/2kynjz4a8nzi1.js | grep -o 'Date.parse("20[0-9-]*T00:00:00Z")'
# ожидаем 2099-01-01T00:00:00Z в обоих
```

Обычный F5 может отдать закэшированный чанк — нужен жёсткий перезагруз (Ctrl+Shift+R).

## Откат и хрупкость

Откат — убрать `volumes` из `patches/compose.patches.yml` (секция `web-mobile`) и строки патчей из
`patches/patches.tsv`, затем `bash infra/vendor-bringup/agenta-web.sh up --with-mobile` (образ не менялся, после
снятия моунтов вернётся штатный код). Хрупкость — как у `patches/agenta-web`: имена чанков принадлежат
конкретной сборке образа, после обновления образа моунты «протухнут», и `make vendor-patches-check`
скажет об этом ГРОМКО (искать заново:
`docker exec agenta-oss-gh-web-mobile-1 grep -rl "2026-08-01T00:00:00" /app/mobile/.next`).
