#!/usr/bin/env python3
"""Владелец операции «промпт агента: репозиторий → платформа».

**Зачем отдельный владелец.** Тексты агентов (их `agents_md`) жили ТОЛЬКО на платформе: в репозитории
лежали копии (`realty/onboarding/*.md`), но ничто не связывало копию с ВЫКАЧЕННОЙ ревизией, а выкат был
разовым действием руками. Пока так — промпт расходится с репозиторием молча, и именно это случилось с
агентом новостей: его `agents_md` предписывал «3–5 пунктов, до 12 строк», тогда как `parse_news_blocks`
ждёт строки `NEWS|{json}` — агент отвечал прозой, парсер её отбрасывал. Здесь ОДНО место, которое текст
репозитория (1) СВЕРЯЕТ с выкаченной ревизией и (2) ВЫКАтывает в новую, называя прежнюю — для отката.

    python3 infra/vendor-bringup/agent-prompts.py check                     # сверка: файл ⇄ выкаченная ревизия
    python3 infra/vendor-bringup/agent-prompts.py deploy news               # выкатить файл новой ревизией
    python3 infra/vendor-bringup/agent-prompts.py deploy news --write-env   # + записать новый id в env-файл

**Почему не в `ci`.** Нужен живой стек и ключ платформы — как у `drift`/`health`; в `make ci` цель не
входит. **Откат:** ревизии неизменяемы, поэтому откат = вернуть прежнее значение ключа ревизии; прежний
id печатается при выкате.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

#: Корни. Воркспейс — НАСТРОЙКА (`AGENT_WORKSPACE`, её задают юниты), а не расположение файла:
#: иначе переезд `infra/` в свой репозиторий увёл бы поиск `.env` и промптов молча.
ROOT = pathlib.Path(os.environ.get("AGENT_WORKSPACE") or pathlib.Path(__file__).resolve().parents[2])
#: Манифест лежит рядом со скриптом: он часть обвязки, а не воркспейса.
MANIFEST = pathlib.Path(__file__).resolve().parent / "agent-prompts.tsv"
#: Адрес платформы С ХОСТА: в `.env` лежит внутрисетевой `http://api:8000/api`, он с хоста не резолвится.
DEFAULT_API = "http://127.0.0.1:8680/api"


def rows() -> list[tuple[str, str, str, str]]:
    """Строки манифеста: (агент, файл промпта, env-файл, ключ ревизии). Комментарии и пустые — мимо."""
    if not MANIFEST.is_file():
        raise SystemExit(f"[prompts] ОСТАНОВ: нет манифеста {MANIFEST}")
    parsed = []
    for number, line in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = [cell.strip() for cell in line.split("\t")]
        if len(cells) < 4 or not all(cells[:4]):
            raise SystemExit(f"[prompts] ОСТАНОВ: {MANIFEST.name}:{number}: нужно 4 колонки — {line!r}")
        parsed.append((cells[0], cells[1], cells[2], cells[3]))
    if not parsed:
        raise SystemExit(f"[prompts] ОСТАНОВ: манифест {MANIFEST.name} пуст — сверять нечего")
    return parsed


def row_for(agent: str) -> tuple[str, str, str, str]:
    for candidate in rows():
        if candidate[0] == agent:
            return candidate
    known = ", ".join(row[0] for row in rows())
    raise SystemExit(f"[prompts] ОСТАНОВ: неизвестный агент «{agent}»; в манифесте: {known}")


def env_value(path: pathlib.Path, key: str) -> str:
    """Значение ключа из env-файла. Файла нет или ключа нет — ОТКАЗ с именем (а не пустая строка)."""
    if not path.is_file():
        raise SystemExit(f"[prompts] ОСТАНОВ: нет файла {path.relative_to(ROOT)} (там id ревизии)")
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    raise SystemExit(f"[prompts] ОСТАНОВ: в {path.relative_to(ROOT)} нет ключа {key}")


def api_base() -> str:
    return os.environ.get("PLATFORM_API_URL_HOST") or DEFAULT_API


def api_key() -> str:
    key = os.environ.get("PLATFORM_API_KEY")
    if key:
        return key
    try:
        return env_value(ROOT / ".env", "PLATFORM_API_KEY")
    except SystemExit:
        raise SystemExit("[prompts] ОСТАНОВ: нет ключа PLATFORM_API_KEY (ни в окружении, ни в .env)") from None


def request(method: str, url: str, payload: dict | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"ApiKey {api_key()}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as answer:
            return json.loads(answer.read().decode() or "{}")
    except urllib.error.HTTPError as failure:
        detail = failure.read().decode()[:400]
        raise SystemExit(f"[prompts] ОТКАЗ платформы: {method} {url} → {failure.code}: {detail}") from None
    except urllib.error.URLError as failure:
        raise SystemExit(f"[prompts] ОТКАЗ сети: {method} {url} → {failure.reason}") from None


def revision(revision_id: str) -> dict:
    answer = request("GET", f"{api_base()}/workflows/revisions/{revision_id}")
    found = answer.get("workflow_revision") or answer
    if not found.get("id"):
        raise SystemExit(f"[prompts] ОТКАЗ: в ответе нет ревизии (запрошена {revision_id})")
    return found


def instructions(revision_record: dict) -> dict:
    """`parameters.agent.instructions` — ОБЪЕКТ (`{"agents_md": …}`), не строка."""
    found = (((revision_record.get("data") or {}).get("parameters") or {}).get("agent") or {}).get("instructions")
    if not isinstance(found, dict) or "agents_md" not in found:
        raise SystemExit("[prompts] ОТКАЗ: в ревизии нет parameters.agent.instructions.agents_md")
    return found


def first_difference(left: str, right: str) -> str:
    """Номер первой несовпавшей строки и её текст — чтобы расхождение разбиралось, а не «не совпало»."""
    left_lines, right_lines = left.splitlines(), right.splitlines()
    for number, (mine, theirs) in enumerate(zip(left_lines, right_lines), 1):
        if mine != theirs:
            return f"строка {number}:\n      репо:  {mine[:100]}\n      платформа: {theirs[:100]}"
    differing = max(len(left_lines), len(right_lines))
    return f"строки совпали до {differing + 1}-й (число строк: репо {len(left_lines)}, платформа {len(right_lines)})"


def check() -> int:
    problems = 0
    for agent, prompt_file, env_file, revision_key in rows():
        path = ROOT / prompt_file
        mine = path.read_text(encoding="utf-8").rstrip("\n") if path.is_file() else None
        if mine is None:
            print(f"  {agent:<8} ОТКАЗ: нет файла {prompt_file}", file=sys.stderr)
            problems += 1
            continue
        revision_id = env_value(ROOT / env_file, revision_key)
        record = revision(revision_id)
        theirs = instructions(record)["agents_md"].rstrip("\n")
        if mine == theirs:
            print(f"  {agent:<8} совпадает · {prompt_file} · ревизия {revision_id[:8]} ({record.get('workflow_variant_slug')})")
            continue
        problems += 1
        print(f"  {agent:<8} РАСХОЖДЕНИЕ · {prompt_file} ({len(mine.encode())} Б) ⇄ ревизия "
              f"{revision_id[:8]} ({len(theirs.encode())} Б)\n    {first_difference(mine, theirs)}", file=sys.stderr)
    if problems:
        print(f"\n[prompts] РАСХОЖДЕНИЙ: {problems} — выкатите файл: python3 infra/vendor-bringup/agent-prompts.py deploy <agent>",
              file=sys.stderr)
        return 1
    print(f"[prompts] тексты сходятся: {len(rows())} агентов, файл в репозитории = выкаченная ревизия")
    return 0


def deploy(agent: str, message: str, write_env: bool) -> int:
    _, prompt_file, env_file, revision_key = row_for(agent)
    path = ROOT / prompt_file
    if not path.is_file():
        raise SystemExit(f"[prompts] ОСТАНОВ: нет файла {prompt_file}")
    text = path.read_text(encoding="utf-8")
    env_path = ROOT / env_file
    current_id = env_value(env_path, revision_key)
    current = revision(current_id)
    print(f"[prompts] {agent}: {prompt_file} → новая ревизия агента «{current.get('workflow_slug')}»")
    print(f"[prompts] прежняя ревизия (для отката): {current_id}")

    data = json.loads(json.dumps(current.get("data") or {}))       # копия: правим ТОЛЬКО инструкции
    instructions(current)                                          # проверка формы ДО правки
    data["parameters"]["agent"]["instructions"] = {"agents_md": text}
    answer = request("POST", f"{api_base()}/workflows/revisions/commit", {
        "workflow_revision": {
            "workflow_variant_id": current.get("workflow_variant_id"),
            "message": message,
            "data": data,
        },
    })
    created = answer.get("workflow_revision") or answer
    new_id = created.get("id")
    if not new_id:
        raise SystemExit(f"[prompts] ОТКАЗ: платформа не вернула id новой ревизии: {json.dumps(answer)[:300]}")
    print(f"[prompts] новая ревизия: {new_id}")
    print(f"[prompts] откат: {revision_key}={current_id} в {env_file}")
    if write_env:
        lines = env_path.read_text(encoding="utf-8").splitlines()
        updated = [f"{revision_key}={new_id}" if line.startswith(f"{revision_key}=") else line for line in lines]
        env_path.write_text("\n".join(updated) + "\n", encoding="utf-8")
        print(f"[prompts] записано в {env_file}: {revision_key}={new_id}")
        print("[prompts] НЕ забудьте: значение применится при ПЕРЕсоздании контейнера")
    else:
        print(f"[prompts] впишите в {env_file}: {revision_key}={new_id} (или повторите с --write-env)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Промпты агентов: репозиторий ⇄ платформа")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="сверить файлы репозитория с выкаченными ревизиями")
    deploy_parser = sub.add_parser("deploy", help="выкатить файл репозитория новой ревизией")
    deploy_parser.add_argument("agent")
    deploy_parser.add_argument("--message", default="", help="сообщение ревизии (по умолчанию — из имени агента)")
    deploy_parser.add_argument("--write-env", action="store_true", help="записать новый id в env-файл")
    args = parser.parse_args()

    if args.command == "check":
        return check()
    message = args.message or f"{args.agent}: текст из репозитория (agent-prompts.tsv)"
    return deploy(args.agent, message, args.write_env)


if __name__ == "__main__":
    sys.exit(main())
