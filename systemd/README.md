# Юниты обвязки (systemd --user)

Источник истины для супервизии хостовых процессов. В `~/.config/systemd/user/` лежат ОТРЕНДЕРЕННЫЕ копии
этих файлов (в юнитах вместо путей стоят подстановки), поэтому правка пути делается здесь, а не в чужом
каталоге. Правки версионируются вместе с обвязкой.

## Что здесь

| Юнит | Роль |
|---|---|
| `bridge.service` | мост: `ExecStart=/bin/bash …/realty/bridge-up.sh run` (uvicorn на `127.0.0.1:8085`), лог `realty/logs/bridge.log`, `Restart=always`, `RestartSec=5`, лимитер `StartLimitBurst=5`/60 с |
| `bridge-news.service` | бот новостей: отдельный процесс, `uvicorn` на `127.0.0.1:8086`, свой токен и лог, `Restart=always`, лимитер как у моста |
| `bridge-mcp.service` | MCP-листенер: отдельный процесс, порт `8087`, лог `realty/logs/mcp.log` |
| `bridge-reminders.service` | напоминания о визитах (LangGraph): отдельный процесс, порт `8089`, свой чекпойнтер и лог |
| `bridge-*-health.{service,timer}` | сторожа: раз в 5 минут (`bridge-health` — мост; `bridge-data-health` — стек данных; `bridge-news/mcp/reminders/embed/solver/search-health` — службы проектов), раз в сутки `bridge-prompts` — тексты агентов против выкаченных ревизий |
| `bridge-drift.{service,timer}` | дрейф конфигурации: работающий контейнер против объявленного окружения |
| `bridge-dump.{service,timer}` | ночной дамп баз продукта и ротация наборов |
| `bridge-*-logtrim.{service,timer}` | обрезка файла лога по потолку размера; **не включаются** `install.sh`: в контейнерах логи крутит docker (`json-file` с ротацией), файл пишет только хостовый юнит |
| `llama-server.service` | ASR-сервер llama.cpp на `127.0.0.1:8081` (порт отдан другим проектам) |
| `llama-embed.service` | сервер эмбеддингов llama.cpp на `127.0.0.1:8082` |

Имя `bridge-*` — шаблон всех сторожей; часть из них караулит службы ДРУГИХ проектов (`-search` →
`search`, `-embed`/`-solver` → `models`). Режим службы («контейнер или юнит») определяет
`infra/lib/service_guard.sh`, поэтому перенос службы в контейнер не требует правок сторожа.

## Установка

```bash
bash infra/systemd/install.sh              # разложить, daemon-reload, enable --now
bash infra/systemd/install.sh --no-enable  # только разложить
bash infra/systemd/install.sh --check-only # сверить подстановки и пути, ничего не писать
```

Прежний файл юнита сохраняется рядом как `<имя>.bak-<таймстемп>` — этим откатываемся.

## Проверка «процесс = диск»

```bash
systemctl --user show bridge -p ActiveState,SubState,Type,Restart,RestartUSec,StartLimitBurst,ExecMainStartTimestamp
loginctl show-user alex -p Linger        # должно быть Linger=yes, иначе user-менеджер умрёт без логина
systemctl --user list-timers --no-pager | grep bridge
diff <(systemctl --user cat bridge | grep -v '^# ') infra/systemd/bridge.service
```

## Откат

```bash
cp ~/.config/systemd/user/bridge.service.bak-<таймстемп> infra/systemd/bridge.service
bash infra/systemd/install.sh
```

## Живучёсть старта

После перезагрузки хоста Postgres и контейнер `api` платформы поднимаются позже моста. Зависимости ждёт
сам мост (`realty/realty_agent/bridge_main.py`, ожидание — `agent_core.startup.wait_ready`): бюджет 45 с
на каждую с backoff, поэтому короткая недоступность
зависимости не даёт `Application startup failed` (uvicorn exit 3) и серии перезапусков.

## Где живут ключи лимитера

`StartLimitIntervalSec` и `StartLimitBurst` принадлежат секции **`[Unit]`**. В `[Service]` systemd их
игнорирует и пишет в журнал `Unknown key … ignoring` — то есть ограничение молча не действует.
Проверяется `systemctl show` (`StartLimitIntervalUSec=1min`, `StartLimitBurst=5`); предупреждения в журнале
при этом нет.

Лимитер `StartLimitBurst=5`/60 с **намеренно сохранён**: одна попытка старта длиннее 60 с, поэтому внешняя
гонка его не набирает, а настоящий краш-луп (мёртвая БД) по-прежнему упирается в предохранитель.
Дополнительно сторож раз в 5 минут снимает состояние `failed` и поднимает мост.
