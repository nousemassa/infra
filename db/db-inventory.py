#!/usr/bin/env python3
"""РЕВИЗИЯ тестового мусора в базе `bridge` — только чтение.

**Зачем скрипт, а не одноразовый отчёт.** Такую ревизию делают дважды: до чистки (чтобы решить, что
убирать) и после (чтобы увидеть, что осталось). Одноразовый текст пришлось бы повторять руками и по
памяти; здесь правило классификации записано кодом — и видно, ПОЧЕМУ строка отнесена к тестовым.

**❗ Главное, ради чего правило вообще вынесено в код.** `raw_block` — НЕ маркер теста, а продуктовое
поле: в боевом пути туда пишется id объекта (`raw_block=booking.listing_id`).
Поэтому «удалить `WHERE raw_block='CHECK'`» убрало бы две строки из шести тестовых. Классификация тут
строится на **двух свидетельствах**: роль чата из `.env` и признание УЧЁТКИ тестовой, если ею помечена
хотя бы одна бронь с `raw_block='CHECK'`. Второе — замыкание по данным: не нужно вписывать в код чужие
идентификаторы (и не нужно, чтобы они попали в публикуемый снапшот).

**Чего скрипт не делает.** Не удаляет и не изменяет — ни строки. Не печатает персональные данные:
имена и телефоны только «есть/нет», идентификаторы чатов — последние четыре знака (ревизия не должна
сама создавать утечку). Выход всегда 0: это отчёт, а не гейт.

    python3 infra/db/db-inventory.py
"""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys

#: Воркспейс: настройка (`AGENT_WORKSPACE`, её задают юниты) или вывод от файла — см. `infra/lib/workspace.sh`.
INFRA = pathlib.Path(__file__).resolve().parents[1]
ROOT = pathlib.Path(os.environ.get("AGENT_WORKSPACE") or INFRA.parent).resolve()


def targets() -> dict[str, dict[str, str]]:
    """Роль → контейнер/база/пользователь/пароль: карта берётся из ОДНОГО места.

    Тот же `infra/lib/db-targets.sh`, что у дампа и учения восстановления: своя копия «как дотянуться
    до базы» разошлась бы с ними и однажды показала бы ревизию не по той базе.
    """
    listed = subprocess.run(
        ["bash", "-c", f'source "{INFRA}/lib/db-targets.sh"; db_targets "{ROOT}"'],
        capture_output=True, text=True, check=True,
    ).stdout
    result: dict[str, dict[str, str]] = {}
    for line in listed.strip().splitlines():
        role, container, database, user, password = line.split("\x1f")
        if container and database:
            result[role] = {"container": container, "database": database, "user": user, "password": password}
    return result


def query(target: dict[str, str], sql: str) -> list[list[str]]:
    """SELECT через psql внутри контейнера: хостового клиента PostgreSQL у нас нет."""
    done = subprocess.run(
        ["docker", "exec", "-i", "-e", "PGPASSWORD", target["container"],
         "psql", "-U", target["user"], "-d", target["database"], "-tA", "-F", "|", "-c", sql],
        input="", capture_output=True, text=True, env={"PGPASSWORD": target["password"], "PATH": "/usr/bin:/bin"},
        check=False,
    )
    if done.returncode != 0:
        print(f"[inventory] база ответила ошибкой: {done.stderr.strip()[:200]}", file=sys.stderr)
        return []
    return [row.split("|") for row in done.stdout.strip().splitlines() if row.strip()]


def env_roles() -> dict[str, set[str]]:
    """Роли чатов из `.env` — первое свидетельство «это наша тестовая учётка»."""
    env = dict(re.findall(r"^([A-Z_]+)=(.*)$", (ROOT / ".env").read_text(encoding="utf-8"), re.MULTILINE))
    roles: dict[str, set[str]] = {}
    for key in ("TELEGRAM_OWNER_CHAT_ID", "TELEGRAM_MANAGER_CHAT_ID", "TELEGRAM_NEWS_TEST_CHANNEL_ID"):
        value = env.get(key, "").strip().strip('"').strip("'")
        if value:
            roles.setdefault(value, set()).add(key.replace("TELEGRAM_", "").replace("_CHAT_ID", "").replace("_ID", ""))
    return roles


def tail(chat: str) -> str:
    return f"…{chat[-4:]}" if len(chat) > 4 else "…"


def main() -> int:
    found = targets()
    if "realty" not in found or "reminders" not in found:
        print("[inventory] не нашёл базы realty/reminders — проверьте .env и контейнеры", file=sys.stderr)
        return 1
    realty, reminders = found["realty"], found["reminders"]

    print("=== РЕВИЗИЯ БАЗЫ (только чтение) ===")
    print("\n--- счётчики по таблицам схемы `realty` ---")
    # Счётчики одним запросом по системному каталогу: список таблиц НЕ зашиваем в код — новый DDL
    # иначе остался бы вне ревизии.
    for name, value in query(realty, """
        select tablename, (xpath('/row/c/text()', query_to_xml(
          format('select count(*) as c from %I', tablename), false, true, '')))[1]::text
        from pg_tables where schemaname='public' order by tablename
    """):
        print(f"    {name:24} {value:>5}")

    print("\n--- брони: класс и ОСНОВАНИЕ ---")
    roles = env_roles()
    marked_chats = {row[0] for row in query(realty, "select distinct chat_id from bookings where raw_block='CHECK'")}
    rows = query(realty, """
        select b.id, b.chat_id, b.status, to_char(b.created_at,'DD.MM HH24:MI'),
               coalesce(b.raw_block,'—'), b.listing_id,
               case when coalesce(b.client_name,'')='' then '—' else 'есть' end,
               case when coalesce(b.client_phone,'')='' then '—' else 'есть' end
        from bookings b order by b.id
    """)
    test_ids, unknown_ids = [], []
    for ident, chat, status, created, raw_block, listing, name_set, phone_set in rows:
        reasons = []
        if chat in roles:
            reasons.append("роль " + "/".join(sorted(roles[chat])) + " из .env")
        if chat in marked_chats:
            reasons.append("учётка помечала брони raw_block='CHECK'")
        kind = "тестовая" if reasons else "НЕИЗВЕСТНАЯ — нужен владелец"
        (test_ids if reasons else unknown_ids).append(ident)
        print(f"    {ident:>4} {tail(chat)} {status:10} {created} объект {listing or '—':4} "
              f"имя:{name_set} тел:{phone_set} raw_block={raw_block:5} → {kind}"
              + (f" ({'; '.join(reasons)})" if reasons else ""))

    print("\n--- потоки графа (чекпойнты) ---")
    threads = query(reminders, "select thread_id, count(*) from checkpoints group by thread_id order by thread_id")
    for thread, n in threads:
        booking = thread.split(":")[-1]
        mark = "тестовая" if booking in test_ids else ("НЕИЗВЕСТНАЯ" if booking in unknown_ids else "нет такой брони")
        print(f"    {thread:14} чекпойнтов {n:>3} → бронь {mark}")

    print("\n--- очередь `outbox`: по видам и состояниям, и на какие брони ---")
    for kind, status, n, lo, hi in query(realty, """
        select kind, status, count(*), min(id), max(id) from outbox group by kind, status order by 1, 2
    """):
        print(f"    {kind:15} {status:8} {n:>4} (id {lo}–{hi})")
    per_booking = query(realty, """
        select coalesce(payload->>'booking_id','нет'), count(*) from outbox
        where payload->>'booking_id' is not null group by 1 order by 1
    """)
    for booking, n in per_booking:
        mark = "тестовая" if booking in test_ids else ("НЕИЗВЕСТНАЯ" if booking in unknown_ids else "—")
        print(f"    строк на бронь {booking:>4}: {n:>3} ({mark})")

    print("\n--- суточные счётчики `meta_metrics` (дни, куда вошла и тестовая активность) ---")
    for day, n in query(realty, "select day::text, count(*) from meta_metrics group by day order by day"):
        print(f"    {day} строк {n}")
    print("    ОГОВОРКА: счётчики записаны по дням и не знают, тестовая активность их набрала или живая —")
    print("    поэтому удаление строк броней их НЕ перепишет: это история, а не производная от bookings.")

    print("\n--- что НЕ мусор (по умолчанию не трогаем) ---")
    print("    consents          — согласия на обработку ПДн: юридический след")
    print("    listings/listing_jobs/managers/settings — продуктовые данные")
    print("    news_drafts/news_seen/calendar_events_seen — история контура")
    print("    knowledge_chunks/agency_faq (база vectors) — корпус RAG")

    print(f"\nИтог: тестовых броней {len(test_ids)} {test_ids}, неизвестных {len(unknown_ids)} {unknown_ids}")
    print("Удаление — ОТДЕЛЬНЫЙ шаг после решения владельца: этот скрипт ничего не меняет.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
