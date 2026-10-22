#!/usr/bin/env python3
"""Дрейф работающего контейнера от ОБЪЯВЛЕННОЙ конфигурации.

**Зачем.** `env_file: .env` у наших служб читается **при СОЗДАНИИ** контейнера, а не при каждом
запуске процесса, поэтому после правки `.env` работающий контейнер живёт со старым значением.
Цена расхождения: контейнер `mcp` с неразрешимым адресом эмбеддингов
(`LLAMA_EMBED_URL=http://host.docker.internal:8082/v1`, `ExtraHosts=[]`) отдаёт полнотекстовый
поиск вместо гибридного — замер в том же контейнере: по этому адресу **0 находок**, по верному
`http://embed:8082/v1` — **3**. Заметить это нечем: сторож смотрит здоровье службы (она `healthy`),
а предупреждение в журнале никто не читает.

**Почему «от объявленной», а не «от файла `.env`».** Сравнивать надо с тем, что даёт сам compose
(`docker compose config`): он подставляет значения из `.env`, разворачивает `environment:` и только он
знает, что реально объявлено службе. Сравнение «файл `.env` против контейнера» дало бы расхождения там,
где ключ объявлен и потому законно переопределён.

**Что НЕ проверяется и почему.** Ключи, добавленные самим ОБРАЗОМ (`PATH`, `GPG_KEY`, `PYTHON_*` и
прочие) — их в объявлении нет, и учитывать их значило бы краснеть всегда. Не работающая служба дрейфом
не считается: её нечего сверять, и это печатается отдельной строкой, а не молчанием.

**❗ НЕРАЗБОРНЫЙ КОМПОЗ — ЭТО ПРОБЛЕМА, А НЕ «НЕЧЕГО СВЕРЯТЬ».** Дубль ключей `logging`/`healthcheck`
у службы даёт `docker compose … config` с `exit 15`. Если на ошибке разбора вернуть **пустой** набор
служб, цикл не выполнится ни разу ⇒ «расхождений 0» и **код 0**, то есть **зелёная слепота на файле,
который нельзя поднять**. Поэтому разбор проверяется отдельно, ошибка называется целиком, и
**«объявлено 0 служб» тоже считается расхождением** — молчание о нечитаемом файле опаснее любого
дрейфа: живые контейнеры хранят конфигурацию у себя, и поломка видна только при пересоздании.

**Чего скрипт не делает.** Не пересоздаёт и не лечит: пересоздание прерывает сессию Telegram, и это
решение владельца, а не автоматики. Скрипт только называет службу, ключ и команду.

    python3 infra/checks/check-stack-drift.py
    # код 1 — расхождение, неразборный композ или НОЛЬ прочитанных служб; код 0 — «совпадает»
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

#: Обвязка (`infra/`) и воркспейс. Воркспейс — настройкой (`AGENT_WORKSPACE`, её задают юниты), иначе
#: выводом от файла: `infra/checks/` → `infra/` → воркспейс. Одно место — `infra/lib/workspace.sh`.
INFRA = pathlib.Path(__file__).resolve().parents[1]
ROOT = pathlib.Path(os.environ.get("AGENT_WORKSPACE") or INFRA.parent).resolve()

#: Общий список наших проектов (`имя проекта<TAB>файл композа`). Проект — не «деталь развёртывания»: по его
#: метке контейнер находят сторож, дрейф и проверка перезагрузки. Одна общая константа проекта молча
#: перестала бы находить службы, которые живут в отдельных проектах (`models`, `search`), — поэтому
#: источник один и лежит рядом со сторожами.
PROJECTS_FILE = INFRA / "compose-projects.tsv"

#: Проекты, которые обязаны работать В ЛЮБОМ режиме вендора. Сейчас таких нет: у каждого продукта своя
#: база в его собственном композе, поэтому «стек данных» не существует отдельно, а простой продукта —
#: НАЗВАННЫЙ пропуск (в режиме второго вендора он гасится осознанно).
ALWAYS_ON_PROJECTS: set[str] = set()


def compose_projects() -> list[tuple[str, str]]:
    """(имя проекта, файл композа) из общего списка; пустой результат — «списка нет», это НЕ «всё хорошо»."""
    if not PROJECTS_FILE.exists():
        return []
    pairs: list[tuple[str, str]] = []
    for line in PROJECTS_FILE.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        project, _, compose_file = line.partition("\t")
        if project.strip() and compose_file.strip():
            pairs.append((project.strip(), compose_file.strip()))
    return pairs


class ComposeUnreadable(RuntimeError):
    """Композ не разбирается `docker compose config`: это состояние ПРОБЛЕМЫ, а не «нечего сверять»."""


def declared_environment(compose_file: str) -> dict[str, dict[str, str]]:
    """Служба → объявленное ей окружение, из самого compose (с подстановками).

    ❗ Бросает `ComposeUnreadable`, если файл не разбирается. Возвращать в этом случае пустой словарь
    нельзя: он неотличим от «служб нет», и тогда неподнятый стек проходит зелёным через `make ci`.
    """
    # ❗ Окружение подаётся ЯВНО и в том же порядке, что у лончеров: основа, затем дополнения проекта.
    # Без этого подстановка зависит от каталога файла (compose ищет `.env` рядом с ним), и ключ вроде
    #: `REALTY_DB_PASSWORD` (живёт в `.env` продукта) разошёлся бы с контейнером ⇒ ложный дрейф и алерт.
    env_args = ["--env-file", ".env"]
    project_dir = (ROOT / compose_file).parent
    if (project_dir / ".env").exists():
        env_args += ["--env-file", str(project_dir / ".env")]
    result = subprocess.run(
        ["docker", "compose", *env_args, "-f", compose_file, "config", "--format", "json"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        # Первая непустая строка — это «yaml: unmarshal errors:», самое полезное (номер строки и ключ) идёт
        # СЛЕДУЮЩЕЙ; берём обе, иначе причина выглядит как обрывок.
        lines = [line.strip() for line in (result.stderr or "").splitlines() if line.strip()][:2]
        reason = " ".join(lines) or "причина не названа"
        raise ComposeUnreadable(
            f"{compose_file} НЕ РАЗБИРАЕТСЯ (код {result.returncode}): {reason} — "
            f"пересоздать любую службу из него невозможно, и это НЕ «совпадает»"
        )
    services = json.loads(result.stdout).get("services") or {}
    if not services:
        raise ComposeUnreadable(
            f"{compose_file} разобрался, но объявленных служб в нём — НОЛЬ — "
            f"сверять нечего, и это НЕ «совпадает»"
        )
    return {
        name: {key: "" if value is None else str(value) for key, value in (cfg.get("environment") or {}).items()}
        for name, cfg in services.items()
    }


def container_environment(service: str, project: str) -> dict[str, str] | None:
    """Окружение работающего контейнера службы; None — служба не запущена.

    Контейнер ищем по МЕТКАМ проекта и службы, а не по имени: имя проекта и суффикс `-1` — деталь
    развёртывания (на поиске по имени сторож графа уже один раз дал ложный алерт).
    """
    found = subprocess.run(
        ["docker", "ps", "-q",
         "--filter", f"label=com.docker.compose.project={project}",
         "--filter", f"label=com.docker.compose.service={service}"],
        capture_output=True, text=True, check=False,
    )
    ids = (found.stdout or "").split()
    if not ids:
        return None
    inspected = subprocess.run(["docker", "inspect", ids[0]], capture_output=True, text=True, check=False)
    if inspected.returncode != 0:
        return None
    env = json.loads(inspected.stdout)[0]["Config"]["Env"] or []
    return {key: value for key, _, value in (item.partition("=") for item in env)}


#: ❗ Значение с паролем не должно попадать в ТЕКСТ: расхождения уходят владельцу в Telegram
#: (`health-drift.sh` → `alert_send`), а `BRIDGE_DB_URL` несёт пароль базы. Маскируем userinfo в URL.
_SECRET_IN_URL = re.compile(r"://([^:/@]+):([^@]*)@")


def masked(value: object) -> str:
    """Скрыть пароль в URL. Принимает ЛЮБОЕ значение, включая отсутствующее.

    ❗ `None` здесь — не редкость, а главный случай: ключ объявлен в композе, но в контейнере его НЕТ
    (контейнер создан до правки `environment:`). Сторож обязан НАЗВАТЬ такой ключ, а не падать:
    `masked(None)` без ветки для отсутствующего значения даёт `TypeError: expected string or
    bytes-like object`, и вместо «ключа нет в контейнере» владелец получает трейсбек, а
    `health-drift` — FAIL без причины.
    """
    if value is None:
        return "<нет в контейнере>"
    return _SECRET_IN_URL.sub(r"://\1:***@", str(value))


def drift() -> tuple[list[str], list[str]]:
    """Расхождения по объявленным ключам и список не запущенных служб (их сверять нечем).

    Неразборный композ идёт в расхождения, а НЕ в «не сверялось»: у «не сверялось» код возврата 0.
    """
    problems: list[str] = []
    skipped: list[str] = []
    stopped_projects: list[str] = []
    projects = compose_projects()
    if not projects:
        return [
            (
                f"{PROJECTS_FILE.relative_to(ROOT)} отсутствует или пуст — сверять нечего, и это НЕ "
                f"«совпадает»: проект compose для каждой службы берётся именно оттуда"
            )
        ], []
    for project, compose_file in projects:
        # ❗ Проект, у которого не работает НИ ОДНА служба, иначе печатал бы «совпадают» с rc=0 — то есть
        # целый стек мог не подняться, оставаясь зелёным во всех гейтах. Но объявлять это отказом ВСЕГДА
        # нельзя: у вендора без `runtime` продуктовые службы гасятся ОСОЗНАННО, и сторож дрейфа начал бы
        # слать владельцу алерты об ожидаемом. Поэтому: проект из списка «обязан быть всегда» — отказ,
        # остальные — НАЗВАННЫЙ пропуск в выводе (молчания не бывает, ложного алерта тоже).
        running = subprocess.run(
            ["docker", "ps", "-q", "--filter", f"label=com.docker.compose.project={project}"],
            capture_output=True, text=True, check=False,
        ).stdout.split()
        if not running:
            if project in ALWAYS_ON_PROJECTS:
                problems.append(
                    f"{project}: ни ОДНОЙ работающей службы (композ {compose_file}) — этот стек обязан "
                    f"работать в ЛЮБОМ режиме вендора: поднимите его и повторите"
                )
            else:
                stopped_projects.append(project)
        try:
            declared_services = declared_environment(compose_file)
        except ComposeUnreadable as failure:
            # Сообщение исключения самостоятельное; хвост здесь был бы склейкой двух разных причин.
            problems.append(str(failure))
            continue
        for service, declared in sorted(declared_services.items()):
            actual = container_environment(service, project)
            if actual is None:
                skipped.append(f"{service} ({project})")
                continue
            for key, wanted in sorted(declared.items()):
                present = actual.get(key)
                if present != wanted:
                    problems.append(
                        f"{service}: {key}: объявлено {masked(wanted)!r}, в контейнере {masked(present)!r} — "
                        f"`env_file` читается при СОЗДАНИИ: нужен "
                        f"`docker compose -f {compose_file} up -d {service}` в тихое время"
                    )
    return problems, skipped, stopped_projects


def main() -> int:
    problems, skipped, stopped_projects = drift()
    if problems:
        print(f"[drift] ПРОБЛЕМ: {len(problems)}", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        if skipped:
            print(f"[drift] не сверялись (не запущены): {', '.join(skipped)}", file=sys.stderr)
        return 1
    notes = []
    if stopped_projects:
        notes.append(f"проекты не подняты целиком: {', '.join(stopped_projects)} (в текущем режиме это "
                     f"ожидаемо — их службы гасит переключатель вендора)")
    if skipped:
        notes.append(f"не запущены: {', '.join(skipped)}")
    tail = ("; " + "; ".join(notes)) if notes else ""
    print(f"[drift] работающие контейнеры совпадают с объявленной конфигурацией{tail}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
