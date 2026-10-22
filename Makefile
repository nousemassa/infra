# Рабочая обвязка: юниты, сторожа, дампы, проверки. Свой Makefile — чтобы обвязку можно было
# поставить и проверить БЕЗ воркспейса (как у проектов). Логика живёт в скриптах, цели её не дублируют.
#
# Корни: `$INFRA` — эта папка, `$WORKSPACE` — воркспейс (его задают юниты через `Environment=`).
# Обе переменные берутся из одного места — `lib/workspace.sh`.
.PHONY: sessions-backup ci install check health status schema dump restore-drill secrets drift reboot-before reboot-after stack-up stack-down stack-status vendor-patches vendor-patches-check agent-prompts-check agent-prompts-deploy

# Разложить юниты и включить таймеры. Перед раскладкой `install.sh` СВЕРЯЕТ пути внутри юнитов с фактом
# и отказывает с названной причиной, если они устарели (урок проекта: артефакт обязан совпадать с источником).
install:
	bash systemd/install.sh

# Офлайн-проверка обвязки: пути в юнитах сходятся с фактом, ничего не раскладываем и не включаем.
# Это то, что стоит гонять в CI: перенос папки делает `ExecStart` мёртвым МОЛЧА, а таймеры просто
# перестают срабатывать — заметно только по последствиям.
check:
	bash systemd/install.sh --check-only

# Сторожа — ПРОГОН, а не «статус»: каждый лечит свой контейнер и при двух фейлах подряд отправляет
# алерт владельцу и менеджерам. ❗ Наивный цикл вернул бы код ПОСЛЕДНЕГО скрипта (`health.sh`), и красный
# сторож поиска дал бы зелёный `make` — поэтому код копится, а не выходим раньше времени.
# ❗ `BRIDGE_URL` подменять НЕЛЬЗЯ: у `health.sh` это адрес наблюдаемого моста, у остальных — канал алертов.
health:
	@rc=0; for s in health/*.sh; do printf '\n=== %s ===\n' "$$s"; bash "$$s" || rc=1; done; \
	 if [ $$rc -eq 0 ]; then echo; echo "[health] все сторожа ok"; else echo; echo "[health] ЕСТЬ КРАСНЫЕ — разбор выше"; fi; \
	 exit $$rc

# Наши патчи на клон вендора: раскладка в `patches/applied/` (её монтирует `patches/compose.patches.yml`).
# Цель — ТОЛЬКО вызов владельца операции: проверка «бандлы в образе те самые» живёт в скрипте.
vendor-patches:
	bash vendor-bringup/apply-vendor-patches.sh

vendor-patches-check:
	bash vendor-bringup/apply-vendor-patches.sh --check

# Тексты агентов: репозиторий ⇄ платформа. Сверка — тот же скрипт, что у сторожа `bridge-prompts.timer`;
# выкат — решение владельца (`AGENT=<агент>`, при необходимости `WRITE_ENV=1`).
agent-prompts-check:
	@bash -c 'source lib/workspace.sh && cd "$$WORKSPACE" && python3 "$$INFRA/vendor-bringup/agent-prompts.py" check'

agent-prompts-deploy:
	@bash -c 'source lib/workspace.sh && cd "$$WORKSPACE" && python3 "$$INFRA/vendor-bringup/agent-prompts.py" deploy "$(AGENT)" $(if $(WRITE_ENV),--write-env)'

# Ручной срез состояния: контейнеры и ошибки в логе. Ни гейт, ни таймер его не зовут — он для человека.
status:
	bash status.sh

# Ручной гейт схемы ЖИВОЙ базы (`migrate` в композе только накатывает, а `Db` сверяет ревизию).
schema:
	bash db/schema-gate.sh

dump:
	bash db/db-dump.sh

restore-drill:
	bash db/db-restore-drill.sh

secrets:
	bash checks/scan-secrets.sh

# Дрейф конфигурации контейнеров: `env_file` читается при СОЗДАНИИ контейнера, поэтому после правки
# `.env` работающий контейнер живёт со старым значением — при `healthy` службе и зелёных гейтах.
drift:
	python3 checks/check-stack-drift.py

# DoD этап 2: контейнеры переживают перезагрузку. Два вызова — состояние до и после сравнивается по СНИМКУ.
reboot-before:
	bash checks/reboot-roundtrip.sh --before

reboot-after:
	bash checks/reboot-roundtrip.sh --after

# Цель `ci` проекта: то же, что гоняет воркспейс (`make ci-all`), но без воркспейса —
# после нарезки репозиториев проект проверяется сам. Своего Python-кода нет: проверяется композ.
ci: check

# Снимок файлов-сессий Telegram (в них ключ доступа). Кладётся ВНЕ репозиториев — см. причину в скрипте.
# Это снимок на дату: обновлять перед тем, как он понадобится, а не после.
sessions-backup:
	bash checks/backup-sessions.sh

# --- СТЕК ВЕНДОРА (равноправно для любого вендора из `infra/vendors.tsv`) ---------------------------
# Один владелец операции — `vendor-stack.sh` (префлайт, образ, подъём, готовность, замер). Цели его не
# дублируют: логика живёт в скрипте, иначе разъедется с ним при первой правке.
#
# ❗ Вендор берётся из `PLATFORM_VENDOR` (или из `VENDOR=…` в вызове). Эти цели `PLATFORM_VENDOR` НЕ
# трогают: выбор вендора — осознанное действие владельца, а не побочный эффект подъёма стека.
stack-up:
	bash vendor-stack.sh up

# Погасить стек. `unless-stopped` в нашем конфиге означает: погашенный стек НЕ поднимется после
# перезагрузки — именно это и требуется от «стартует только выбранный».
stack-down:
	bash vendor-stack.sh down

stack-status:
	bash vendor-stack.sh status
