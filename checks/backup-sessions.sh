#!/usr/bin/env bash
# backup-sessions.sh — снимок файлов-сессий Telegram: в них `auth_key`, ключ доступа к аккаунту.
#
# **Зачем скрипт, а не разовый `cp`.** Две причины, обе живые:
#   1. бот пишет в файл сессии ПОСТОЯННО, поэтому `cp` может поймать полузапись. Снимок делается
#      питоновским `sqlite3.Connection.backup()` — он даёт СОГЛАСОВАННУЮ копию живого файла;
#   2. сделанный один раз руками, бэкап через месяц становится ИЛЛЮЗИЕЙ защиты: файл с тех пор
#      изменится, а снимок будет выглядеть как страховка. Поэтому операция живёт в скрипте с целью.
#
# **Почему снимок лежит ВНЕ репозиториев.** В файле ключ доступа. Внутри рабочего дерева его защищало
# бы только правило `.gitignore`, а правила меняются и дыры в них находятся (правило `logs/` съело бы
# скрипт; `*.egg-info/` держалось лишь корнем). Вне репозитория коммит невозможен в принципе. Каталог
# переопределяется настройкой `SESSION_BACKUP_DIR`.
#
# **Это СНИМОК НА ДАТУ, а не живая реплика.** Он спасает от «файл потерян или испорчен», но НЕ от
# «откатиться на прежний вход»: если бот после снимка переавторизовался, файл может оказаться
# недействительным (на это указывает расхождение `auth_key` между снимками).
#
# Использование:
#   bash infra/checks/backup-sessions.sh        # снимок + проверка
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"

DEST_ROOT="${SESSION_BACKUP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/agent/sessions-backup}"
DEST="$DEST_ROOT/$(date +%Y-%m-%d)"

mkdir -p "$DEST"
chmod 700 "$DEST_ROOT" "$DEST"

python3 - "$DEST" "$WORKSPACE" <<'PY'
import datetime
import hashlib
import pathlib
import sqlite3
import sys

dest, workspace = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

README = """# Снимки файлов-сессий Telegram

**Что здесь.** Согласованные копии `realty/.sessions/bridge.session` и `news/.sessions/news.session`.
В них `auth_key` — ключ доступа к аккаунтам ботов.

**Почему каталог здесь, а не в репозитории.** В файле ключ. Внутри рабочего дерева его защищало бы
только правило `.gitignore`, а правила меняются; вне репозитория коммит невозможен в принципе.

**Свежесть — здесь и сейчас.** Это СНИМОК НА ДАТУ, а не живая реплика: обновляется запуском
`make sessions-backup`. Снимок месячной давности почти наверняка недействителен.

**Как восстановить.** Остановить бота → положить файл на место (`realty/.sessions/bridge.session` или
`news/.sessions/news.session`) → `chmod 600` → поднять бота → убедиться, что `/health` отвечает
`telegram: true` (у новостей ещё `channel: true`).

**Чего снимок НЕ делает.** Не откатывает на прежний вход: если бот после снимка переавторизовался,
восстановленный файл может оказаться недействительным. Он спасает от «файл потерян или испорчен».

**Ключа в манифесте нет намеренно** — манифест не должен дублировать секрет.
"""

targets = [("realty", workspace / "realty" / ".sessions" / "bridge.session"),
           ("news", workspace / "news" / ".sessions" / "news.session")]

manifest = [
    f"Снимок файлов-сессий: {datetime.datetime.now():%Y-%m-%d %H:%M:%S}",
    f"Источник: {workspace}",
    "",
    "❗ В снимках лежит auth_key. Здесь его НЕТ намеренно: манифест не дублирует секрет.",
    "",
]
problems: list[str] = []

for name, live_path in targets:
    if not live_path.exists():
        problems.append(f"{name}: нет файла сессии {live_path}")
        continue
    live = sqlite3.connect(f"file:{live_path}?mode=ro", uri=True)
    live_key = live.execute("select auth_key from sessions limit 1").fetchone()
    snapshot = dest / f"{name}.session"
    copy = sqlite3.connect(snapshot)
    with copy:
        live.backup(copy)                     # согласованный снимок ЖИВОГО файла (не `cp`)
    copy.close()
    live.close()
    snapshot.chmod(0o600)

    check = sqlite3.connect(f"file:{snapshot}?mode=ro", uri=True)
    integrity = check.execute("pragma integrity_check").fetchone()[0]
    rows = check.execute("select count(*) from sessions").fetchone()[0]
    copy_key = check.execute("select auth_key from sessions limit 1").fetchone()
    check.close()

    if integrity != "ok":
        problems.append(f"{name}: снимок не цел — integrity_check вернул {integrity!r}")
    if live_key != copy_key:
        problems.append(f"{name}: auth_key снимка НЕ совпал с живым файлом — снимок не тот")
    digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
    manifest.append(f"{name}.session  {snapshot.stat().st_size} байт  строк sessions: {rows}  sha256 {digest}")
    print(f"  {name:<7} снимок {snapshot.stat().st_size} байт, строк sessions {rows}, целостность {integrity}, "
          f"auth_key {'совпал ✓' if live_key == copy_key else 'НЕ совпал ✗'}")

(dest / "MANIFEST.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")
(dest / "README.md").write_text(README, encoding="utf-8")

if problems:
    print("[sessions-backup] НАРУШЕНО: " + str(len(problems)), file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    raise SystemExit(1)
print(f"  каталог снимка: {dest} (права 700, файлы 600)")
PY
