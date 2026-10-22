# Патч `web` (десктопный UI Agenta): полное меню в сайдбаре

> **✅ ВКЛЮЧЁН (2026-10-01, вечер-6) — рабочий статус проекта.**
> Смонтирован в сервис `web` (оверрайд + генератор). **Почему включён:** штатный переключатель
> Settings → Preferences → Feature Flags → **«Developer Mode»** в нашем окружении **полное меню не даёт**
> (наблюдение пользователя: «переключение не даёт никакого эффекта, пунктов меню нет»), а с патчем меню
> полное — подтверждено скриншотом. Поэтому дефолт-патч оставлен до конца проекта.
> **Открытый вопрос (не выяснен):** почему переключатель не действует при штатном коде — кандидаты:
> (а) запись оверрайда теряется (сеттер `navSimplifiedOverrideAtom` молча выходит, если `activeUserIdAtom`
> пуст — `classicMode.ts:123-127`); (б) разные origin (`localhost` vs `127.0.0.1` — у них разные
> `localStorage` и cookie); (в) в их браузере `advancedNavHidden` остаётся `true` по когорте. Диагностика —
> одна строка в F12: `({url:location.href, nav:Object.fromEntries(Object.entries(localStorage).filter(([k])=>k.includes('nav-simplified'))), cookies:document.cookie})`.
> Снятие/возврат: см. «Как применено» / «Откат» ниже.

## Что чинится

В свежих сборках Agenta есть **«упрощённый режим»**: аккаунты, созданные после
**2026-08-01**, по умолчанию получают урезанную навигацию — в сайдбаре нет
**Prompts**, **Evaluation** (Test sets / Evaluators / Evaluation runs / Annotation Queues)
и **Observability**. Разделы живут и открываются прямыми URL, но из меню недоступны.

Механика (исходники `web/packages/agenta-shared/src/state/classicMode.ts`):

```ts
const SIMPLIFIED_SIGNUP_CUTOFF = Date.parse("2026-08-01T00:00:00Z")
const isSimplifiedCohort = (user) => Date.parse(user.created_at) >= SIMPLIFIED_SIGNUP_CUTOFF
export const advancedNavHiddenAtom = atom((get) => get(navSimplifiedOverrideAtom) ?? get(navSimplifiedDefaultAtom))
```

`advancedNavHidden = true` гасит пункты в `web/oss/src/components/Sidebar/hooks/useSidebarConfig/index.tsx`
(`isHidden: hideAdvancedNav` у Prompts, группы Evaluation и Observability).

Тот же флаг гонит браузер на `/m` (мобильный UI) — поэтому одна правка закрывает оба симптома.

## Что делает патч

Одна константа в собранном чанке десктопного приложения отодвинута в будущее:

```
/app/oss/.next/static/chunks/pages/_app-2f56bfdec0de251c.js
-  Date.parse("2026-08-01T00:00:00Z")
+  Date.parse("2099-01-01T00:00:00Z")
```

Следствие: ни один аккаунт не попадает в «упрощённую когорту» (если пользователь сам не
выбрал упрощённый режим переключателем) ⇒ `advancedNavHidden = false` ⇒ **полное меню**.

Правильный пользовательский путь — тот же результат без патча: **Settings → Preferences →
Feature Flags → «Developer Mode»** (описание: *Show Evaluation, Prompt Management, and Tracing in
the navigation*). Он пишет `agenta:onboarding:<user-id>:nav-simplified-override = false` в
localStorage конкретного браузера. Патч делает это поведением **по умолчанию для всех**
браузеров и устройств (аккаунты, созданные до этой даты, попадают в когорту автоматически).

## Как применено (шаг D17)

Файл-патч лежит рядом (`_app-2f56bfdec0de251c.js`), а монтирование объявлено у нас —
`patches/compose.patches.yml` (секция `web`), которое лончер подаёт вендорному `run.sh` ключом
`--compose-file`. Источник монтирования — **`patches/applied/`**: туда файл кладёт
`infra/vendor-bringup/apply-vendor-patches.sh` (цель `make vendor-patches`), предварительно проверив, что бандл в
образе — ТОТ САМЫЙ (см. «Хрупкость»). Раньше оверрайд генерировался ВНУТРЬ клона вендора
(`vendor/…/docker-compose.gh.mem.local.yml`) и свежий клон терял проводку молча — теперь её нет в клоне.

```yaml
    volumes:
      - "../../../../../patches/applied/agenta-web/_app-2f56bfdec0de251c.js:/app/oss/.next/static/chunks/pages/_app-2f56bfdec0de251c.js:ro"
```

Пересоздать только UI (остальной стек не трогается) — скрипт сам соберёт `applied/`:

```bash
cd "$WORKSPACE"   # каталог воркспейса: тот, в котором лежит infra/
bash infra/vendor-bringup/agenta-web.sh up
```

## Проверка

```bash
# браузеру отдаётся уже патченная константа
curl -s http://127.0.0.1:8680/_next/static/chunks/pages/_app-2f56bfdec0de251c.js \
  | grep -o 'Date.parse("20[0-9-]*T00:00:00Z")'          # ожидаем 2099-01-01T00:00:00Z
# внутри контейнера файл — это точный read-only моунт
docker exec agenta-oss-gh-web-1 mount | grep _app-
```

Браузер держит чанк в immutable-кэше под тем же URL, поэтому после патча нужен **жёсткий
перезагруз** (Ctrl+Shift+R) — обычный F5 может отдать старый JS.

## Откат

Убрать строку `volumes` из `patches/compose.patches.yml` (секция `web`) и строку патча из
`patches/patches.tsv`, затем `bash infra/vendor-bringup/agenta-web.sh up`.
Оригинал восстанавливать не нужно: моунт лишь «перекрывает» файл образа, сам образ не менялся —
после снятия моунта контейнер снова отдаёт штатный чанк.

## Хрупкость (важно)

Имя чанка содержит хеш сборки (`_app-2f56bfdec0de251c.js`). Образы у нас помечены `latest`
без пиннинга по digest, поэтому **после обновления образа `agenta-web` путь моунта перестанет
существовать** (или станет «мёртвым»). Признак: пункты меню снова пропали. Тогда: найти новый
чанк с константой
(`docker exec agenta-oss-gh-web-1 grep -rl "2026-08-01T00:00:00" /app/oss/.next/static/chunks/pages`),
повторить патч и обновить путь моунта в `patches/compose.patches.yml` и в `patches/patches.tsv`
(там же — новый `sha256` базы). ❗ `make vendor-patches-check` ловит это САМ и отказывает громко:
«бандл вендора пересобран, наш патч устарел». Прод-путь — не патч, а переключатель
Developer Mode у пользователя (или пиннинг образа + пересборка фронта).
