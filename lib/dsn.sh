#!/usr/bin/env bash
# Хостовые DSN для процессов, запускаемых НЕ в контейнере.
#
# **Зачем отдельным файлом.** `.env` хранит адреса ВНУТРИ docker-сети (`postgres:5432`,
# `pgvector:5432`), а хостовый процесс таких имён не разрешает. Перекрытие на опубликованные порты
# (55432 и 55433) копией в каждом скрипте запуска даёт один и тот же дефект: у бота новостей молча не
# работает база знаний, у процесса графа не поднимается чекпойнтер. Механизм для нескольких
# потребителей держим в одном месте: копия разойдётся, а ошибка при этом будет тихой — процесс
# поднимется и просто скажет, что «механизм не поднят».
#
# Подключение:  source "$ROOT/infra/lib/dsn.sh"

#: Креды и имя базы — из файлов окружения, хост и порт — опубликованные на 127.0.0.1.
#: Файлы читаются ПО ПОРЯДКУ: побеждает последний, где ключ определён. У продукта своя база
#: (`realty/.env` → `/realty`, `news/.env` → `/news`), поэтому лончер передаёт оба файла.
dsn() {
  python3 - "$@" <<'DSN_PY'
import os, sys, urllib.parse as u

raw = {}
for path in sys.argv[1:] or [".env"]:
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    raw[key.strip()] = value.strip().strip('"').strip("'")
    except FileNotFoundError:
        continue

url = raw.get("DB_URL") or raw.get("BRIDGE_DB_URL")
if not url:
    raise SystemExit("[dsn] нет DB_URL ни в одном из файлов окружения — база продукта не задана")
p = u.urlsplit(url)
cred = p.netloc.rsplit("@", 1)[0] + "@" if "@" in p.netloc else ""
db = p.path.lstrip("/") or "realty"
#: ❗ Порт — по имени хоста ИЗ DSN, а не литералом: «единый источник» не должен врать первым.
#: Неизвестный хост — ОТКАЗ с причиной: тихое «5432» уже давало молчаливый отказ подключения.
PORTS = {"realty-db": 55435, "news-db": 55436, "pgvector": 55433, "reminders-db": 55434}
port = os.environ.get("BRIDGE_DB_PORT_HOST") or PORTS.get(p.hostname or "")
if port is None:
    raise SystemExit(f"[dsn] хост базы {p.hostname!r} из DB_URL неизвестен: "
                     f"опубликованные порты знаю для {sorted(PORTS)} (BRIDGE_DB_PORT_HOST — переопределение)")
print(f"postgresql+asyncpg://{cred}127.0.0.1:{port}/{db}")
DSN_PY
}

vector_dsn() {
  python3 - <<'DSN_PY'
import urllib.parse as u
raw = {}
for line in open(".env"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        raw[k.strip()] = v.strip().strip('"').strip("'")
url = raw.get("VECTOR_DB_URL", "")
if not url:
    raise SystemExit("[dsn] нет VECTOR_DB_URL в файлах окружения — адрес векторной базы задаётся ЯВНО")
p = u.urlsplit(url)
cred = p.netloc.rsplit("@", 1)[0] + "@" if "@" in p.netloc else ""
db = p.path.lstrip("/") or "vectors"
print(f"postgresql+asyncpg://{cred}127.0.0.1:55433/{db}")
DSN_PY
}

# Чекпойнт-база графа: своя база, а значит свой опубликованный порт. Имя хоста в `.env`
# контейнерное (`reminders-db`), с хоста нужен порт — карта ниже переводит одно в другое; иначе адрес
# попадёт в процесс как есть и не разрешится.
reminders_dsn() {
  python3 - <<'DSN_PY'
import os
import urllib.parse as u

raw = {}
for line in open(".env"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        raw[k.strip()] = v.strip().strip('"').strip("'")

# Опубликованные на 127.0.0.1 порты наших контейнеров.
PORTS = {"pgvector": 55433, "reminders-db": 55434}
p = u.urlsplit(raw.get("REMINDERS_CHECKPOINT_DSN", ""))
if not p.netloc:
    raise SystemExit("[reminders] REMINDERS_CHECKPOINT_DSN не задан в .env — поднимать нечего")
creds = p.netloc.rsplit("@", 1)[0] + "@" if "@" in p.netloc else ""
db = p.path.lstrip("/") or "reminders"
port = os.environ.get("GRAPH_CHECKPOINT_PORT_HOST") or PORTS.get(p.hostname or "", 5432)
print(f"postgresql://{creds}127.0.0.1:{port}/{db}")
DSN_PY
}
