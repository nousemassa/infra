#!/usr/bin/env python3
"""Три агента-роли на платформе: исследователь, автор, проверяющий (`E20`).

**Зачем они нужны.** Требование владельца: агенты, использующие LangGraph, должны быть **явно видны в
Agenta вместе с пайплайнами взаимодействия**. Трейс выпуска ссылается на ревизии ролей (проверено
пробой: ссылки детей ложатся в `spans."references"`), а ссылка без объекта была бы надписью — поэтому
роли должны существовать как объекты платформы.

**Почему копией нашего агента, а не с нуля.** Приложение-агент описывается структурой `data`
(`uri`, `url`, `schemas`, `parameters`): сочинять её руками значит разойтись с тем, что понимает
платформа. Поэтому инструмент берёт `data` существующей ревизии `news-hunter` и меняет **только
назначение роли** — `parameters.agent.instructions`.

**Чего эти объекты НЕ делают.** Платформа их не исполняет: роли исполняет наш граф (решение `0018`).
Инструкция объекта — это **назначение роли** (кто она и чего от неё ждут), а рабочие тексты шагов живут
в коде (`news/news_agent/news_team/prompts.py`). Так сделано намеренно: дублировать рабочий промпт в
платформу значит завести вторую его редакцию, которая неизбежно разойдётся с первой.

Запуск (из корня репозитория; создание обратимо — объекты архивируются):

    PYTHONPATH=realty:news .venv/bin/python infra/vendor-bringup/agent-roles-setup.py --dry-run
    PYTHONPATH=realty:news .venv/bin/python infra/vendor-bringup/agent-roles-setup.py --write-env
"""
from __future__ import annotations

import argparse
import copy
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "realty"))

# Ревизия-образец: наш боевой агент новостей. Из неё берём структуру приложения целиком,
# чтобы не сочинять её руками (см. докстроку).
DEFAULT_TEMPLATE_REVISION = "01a11aba-bf1a-7201-ab93-54bb340d03c3"

# Роль → (slug агента, человеческое имя). slug ASCII: он уходит в интерфейс и в адреса.
ROLES = {
    "researcher": ("news-researcher", "Новости: исследователь"),
    "author": ("news-author", "Новости: автор"),
    "verifier": ("news-verifier", "Новости: проверяющий"),
}

# Строки .env, которые прочитает обвязка спанов (`news/news_agent/news_team/tracing.py`).
ENV_KEYS = {
    "researcher": ("OTEL_ROLE_RESEARCHER_ID", "OTEL_ROLE_RESEARCHER_REVISION"),
    "author": ("OTEL_ROLE_AUTHOR_ID", "OTEL_ROLE_AUTHOR_REVISION"),
    "verifier": ("OTEL_ROLE_VERIFIER_ID", "OTEL_ROLE_VERIFIER_REVISION"),
}


def load_env(path: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                out[key.strip()] = value.strip()
    return out


def role_instruction(role_key: str) -> dict[str, str]:
    """Назначение роли в том виде, который принимает платформа: `{"agents_md": "…"}`.

    **Форма взята у платформы, а не угадана.** Первая попытка отправить строку вернула 422 с точным
    текстом: `instructions must be an object with an agents_md string` — то есть инструкция агента это
    AGENTS.md-документ. Берём структуру образца (`{"agents_md": …}`) и подставляем назначение роли из
    её данных (`roles.py`), а не рабочий промпт шага: рабочего промпта здесь быть не должно (вторая
    редакция разошлась бы с кодом, см. докстроку модуля).
    """
    from news_agent.news_team.roles import role

    definition = role(role_key)
    tools = ", ".join(f"`{name}`" for name in definition.tools) or "нет"
    text = (
        f"# Роль команды новостей: {definition.title}\n\n"
        f"Ты — {definition.title} в команде новостного контура агентства недвижимости.\n\n"
        f"## Цель\n{definition.goal}\n\n"
        f"## Ожидаемый результат шага\n{definition.expected}\n\n"
        f"## Инструменты роли\n{tools}\n\n"
        "## Кто тебя исполняет\nРоль исполняет наш граф (LangGraph): этот объект фиксирует назначение "
        "роли и её ревизию, а рабочие тексты шагов живут в коде.\n"
    )
    return {"agents_md": text}


def main() -> int:
    parser = argparse.ArgumentParser(description="Создать три агента-роли на платформе (E20)")
    parser.add_argument("--template-revision", default=DEFAULT_TEMPLATE_REVISION,
                        help="ревизия-образец (по умолчанию — наш агент новостей)")
    parser.add_argument("--dry-run", action="store_true", help="показать, что будет создано, и выйти")
    parser.add_argument("--write-env", action="store_true",
                        help="дописать id агентов и ревизий в .env (иначе только напечатать)")
    args = parser.parse_args()

    import httpx

    env = load_env(ROOT / ".env")
    base = (env.get("PLATFORM_API_URL_HOST") or "http://127.0.0.1:8680/api").rstrip("/")
    key = env.get("PLATFORM_API_KEY") or ""
    if not key:
        print("нет PLATFORM_API_KEY в .env — создавать нечем", file=sys.stderr)
        return 2
    headers = {"Authorization": f"ApiKey {key}", "Content-Type": "application/json"}

    with httpx.Client(timeout=60.0) as client:
        found = client.post(f"{base}/applications/revisions/retrieve", headers=headers,
                            json={"application_revision_ref": {"id": args.template_revision}})
        if found.status_code != 200:
            print(f"не прочитал образец: {found.status_code} {found.text[:200]}", file=sys.stderr)
            return 1
        template = found.json()["application_revision"]
        data = copy.deepcopy(template["data"])
        print(f"образец: агент {template.get('application_slug')}, ревизия {args.template_revision}")
        print(f"ключи data: {', '.join(sorted(data))}")
        print(f"agent.llm: {json.dumps((data.get('parameters') or {}).get('agent', {}).get('llm', {}), ensure_ascii=False)}")

        created: dict[str, tuple[str, str]] = {}
        for role_key, (slug, name) in ROLES.items():
            payload = {
                "workflow": {
                    "slug": slug,
                    "name": name,
                    "description": f"Роль команды новостного контура: {role_key} (назначение; исполняет граф E19)",
                    "data": copy.deepcopy(data),
                }
            }
            payload["workflow"]["data"]["parameters"]["agent"]["instructions"] = role_instruction(role_key)
            if args.dry_run:
                print(f"[dry-run] создам {slug} ({name}), инструкция: "
                      f"{role_instruction(role_key)['agents_md'].splitlines()[1][:70]}…")
                continue
            response = client.post(f"{base}/simple/workflows/", headers=headers, json=payload)
            if response.status_code not in (200, 201):
                print(f"[{slug}] не создан: {response.status_code} {response.text[:300]}", file=sys.stderr)
                continue
            body = response.json()
            workflow = body.get("workflow") or {}
            agent_id = workflow.get("id") or ""
            # **Ревизию читаем отдельным запросом.** В ответе создания её id не приходит (проверено:
            # ключ пуст), а ссылаться детям нужно именно на ревизию. Платформа при создании агента
            # заводит v0-заглушку и v1 с `is_agent: true` — берём последнюю.
            revision_id, flags = "", {}
            fetched = client.post(f"{base}/applications/revisions/retrieve", headers=headers,
                                  json={"application_ref": {"slug": slug}})
            if fetched.status_code == 200:
                revision = fetched.json().get("application_revision") or {}
                revision_id = revision.get("application_revision_id") or revision.get("id") or ""
                flags = revision.get("flags") or {}
            created[role_key] = (agent_id, revision_id)
            print(f"[{slug}] создан: агент {agent_id}, ревизия {revision_id}, "
                  f"is_agent={flags.get('is_agent')}")

    if args.dry_run or not created:
        return 0

    lines = []
    for role_key, (agent_id, revision_id) in created.items():
        id_key, rev_key = ENV_KEYS[role_key]
        lines.append(f"{id_key}={agent_id}")
        lines.append(f"{rev_key}={revision_id}")
    print("\nстроки для .env:")
    for line in lines:
        print(f"  {line}")

    if args.write_env:
        env_path = ROOT / ".env"
        text = env_path.read_text(encoding="utf-8")
        text = (text.rstrip("\n") + "\n\n"
                "# Агенты-роли команды новостей (E20): по их ревизиям трейсы детей ссылаются на роли.\n"
                "# Созданы infra/vendor-bringup/agent-roles-setup.py; архивируются через /simple/workflows/{id}/archive.\n")
        text += "\n".join(lines) + "\n"
        env_path.write_text(text, encoding="utf-8")
        print(f"дописано в {env_path} ({len(lines)} строк)")

    # Проверка фактом, а не намерением: объекты обязаны быть в базе.
    print("\nпроверка (SQL): SELECT slug FROM workflow_artifacts ORDER BY slug;")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
