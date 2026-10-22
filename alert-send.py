#!/usr/bin/env python3
"""Одно сообщение владельцу по MTProto — БЕЗ моста.

**Зачем отдельный отправитель.** Доставка алертов идёт через мост (`POST /api/ops/alert`), а мост умеет
пользоваться Telegram только пока САМ жив. У вендора без возможности `runtime` он погашен осознанно ⇒
алертов не существует вовсе; та же слепота наступает, когда мост УПАЛ у вендора с `runtime` — ровно
тогда, когда сообщение нужнее всего. Этот скрипт даёт канал доставки, не зависящий от моста.

**Почему MTProto, а не Bot API.** `api.telegram.org` с этого хоста не отвечает (HTTPS 000 по IPv4 и IPv6
при живом ICMP). MTProto — измеренно единственный рабочий путь.

**❗ Правило «одна сессия Telegram — один процесс».** Скрипт использует сессию МОСТА
(`realty/.sessions/bridge.session`). Поэтому вызывать его можно ТОЛЬКО когда мост не работает — это
проверяет вызывающий (`infra/lib/alert.sh`), и проверка там названа, а не подразумевается. Два процесса на
одном файле сессии конфликтуют: новый вход рвёт сессию первому.

Запуск (текст — на stdin, чтобы не ломаться на кавычках и переводах строк):

    echo "текст" | SESSIONS_DIR=$ROOT/realty/.sessions \
        AGENT_ENV_FILES="$ROOT/.env:$ROOT/realty/.env" .venv/bin/python infra/alert-send.py

Коды возврата — это и есть вердикт (вызывающий обязан их различать и называть причину):
  0 — отправлено;  2 — пустой текст;  3 — нет бот-токена;  4 — нет чата владельца;
  5 — не подключился (прокси/сеть/авторизация);  6 — подключился, но отправка не удалась.
"""
from __future__ import annotations

import asyncio
import sys

from agent_core.config import Settings
from agent_core.tg.connection import TelegramConnection


def fail(code: int, reason: str) -> int:
    print(f"[alert-send] ОТКАЗ ({code}): {reason}", file=sys.stderr)
    return code


async def send(settings, text: str, owner: str) -> int:
    connection = TelegramConnection(
        settings=settings,
        name="сторож",
        #: Сессия МОСТА: у неё уже есть авторизация бота, и новой авторизации не будет (повторный
        #: `ImportBotAuthorizationRequest` рискует FloodWait — предупреждение в `mtproto.py:143-146`).
        session_name="bridge",
        token=settings.telegram_bot_token,
        #: Бюджет короткий: сторож не должен висеть минутами. Перебор прокси внутри `connect()`.
        start_budget_s=20.0,
    )
    try:
        await connection.connect()
    except Exception as error:  # noqa: BLE001 — причина отказа нужна вызывающему, а не трейс
        return fail(5, f"не подключился ({type(error).__name__}: {error})")
    try:
        entity = int(owner) if str(owner).lstrip("-").isdigit() else owner
        await connection.client.send_message(entity, text[:4000])
        print("[alert-send] отправлено (MTProto, сессия bridge)")
        return 0
    except Exception as error:  # noqa: BLE001 — то же: называем причину
        return fail(6, f"подключился, но отправка не удалась ({type(error).__name__}: {error})")
    finally:
        await connection.stop()


def main() -> int:
    text = sys.stdin.read().strip()
    if not text:
        return fail(2, "пустой текст алерта")
    settings = Settings()
    if not settings.telegram_bot_token:
        return fail(3, "нет TELEGRAM_BOT_TOKEN (сессия моста недоступна)")
    owner = settings.telegram_owner_chat_id
    if not owner:
        return fail(4, "нет TELEGRAM_OWNER_CHAT_ID — некому слать")
    return asyncio.run(send(settings, text, owner))


if __name__ == "__main__":
    raise SystemExit(main())
