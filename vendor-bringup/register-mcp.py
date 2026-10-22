#!/usr/bin/env python3
"""Регистрация MCP-сервера моста в шлюзе платформы Agenta (E5).

**Зачем скрипт, а не ручная настройка.** Подключение — это запись в шлюзе платформы
(адрес нашего сервера плюс список разрешённых инструментов). Сделанное руками, оно
не воспроизводится: после переустановки стенда про него никто не вспомнит. Скрипт
идемпотентен — повторный запуск обновляет ту же запись, а не плодит дубли.

**Почему адрес такой.** Платформа обращается к инструментам **из контейнера**, поэтому
адрес — `host.docker.internal:<порт>`: наш MCP слушает отдельным сервером (основной API
моста остаётся на 127.0.0.1 и контейнерам недоступен). Это же подтверждается allowlist
платформы: в её окружении разрешён только `host.docker.internal`.

**Проверка — не «мы отправили запрос», а `probe`:** платформа сама дёргает наш сервер и
отвечает, видит ли инструменты. Только это и считается доказательством подключения.

Запуск:
    .venv/bin/python infra/vendor-bringup/register-mcp.py
    .venv/bin/python infra/vendor-bringup/register-mcp.py --dry-run
    .venv/bin/python infra/vendor-bringup/register-mcp.py --delete
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "realty"))

SLUG = "realty-mcp"
NAME = "Realty MCP (мост)"
TOOLS = ["get_available_slots", "search_listings", "get_object_details"]


def load_env(path: pathlib.Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                out[key.strip()] = value.strip().strip('"').strip("'")
    return out


def call(url: str, *, key: str, method: str = "GET", body: dict | None = None) -> tuple[int, dict]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"ApiKey {key}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read().decode()
            return response.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as error:
        raw = error.read().decode()
        try:
            return error.code, json.loads(raw)
        except Exception:  # noqa: BLE001
            return error.code, {"detail": raw[:300]}


def main() -> int:
    parser = argparse.ArgumentParser(description="Зарегистрировать MCP-сервер моста в шлюзе платформы")
    parser.add_argument("--base", help="адрес API платформы (по умолчанию из .env)")
    parser.add_argument("--public-url", help="адрес нашего MCP так, как его видит платформа")
    parser.add_argument("--dry-run", action="store_true", help="показать план, ничего не менять")
    parser.add_argument("--delete", action="store_true", help="удалить запись из шлюза")
    args = parser.parse_args()

    env = load_env(ROOT / ".env")
    base = (args.base or env.get("PLATFORM_API_URL_HOST") or "http://127.0.0.1:8680/api").rstrip("/")
    key = env.get("PLATFORM_API_KEY", "")
    port = env.get("MCP_PORT", "8087")
    public_url = args.public_url or f"http://host.docker.internal:{port}/mcp/"

    if not key:
        print("[mcp-reg] нет PLATFORM_API_KEY в .env", file=sys.stderr)
        return 2

    endpoints_url = f"{base}/gateways/mcps/endpoints/"

    # Шаг 0: есть ли вообще права. Создание требует EDIT_MCP_ENDPOINTS, и наш ключ —
    # проектный; если он не подходит, узнать об этом надо здесь, а не после отправки.
    status, payload = call(endpoints_url, key=key)
    if status == 403:
        print("[mcp-reg] FAIL: у ключа нет прав на управление MCP-эндпоинтами (403).", file=sys.stderr)
        print("[mcp-reg] Нужен ключ с EDIT_MCP_ENDPOINTS — это доступ владельца, обойти нельзя.", file=sys.stderr)
        return 1
    if status != 200:
        print(f"[mcp-reg] FAIL: список эндпоинтов недоступен (HTTP {status}): {payload}", file=sys.stderr)
        return 1

    existing = {item.get("slug"): item for item in payload.get("endpoints", [])}
    current = existing.get(SLUG)
    print(f"[mcp-reg] в шлюзе эндпоинтов: {len(existing)}; наш: {'есть' if current else 'нет'}")

    if args.delete:
        if not current:
            print("[mcp-reg] удалять нечего")
            return 0
        if args.dry_run:
            print(f"[mcp-reg] dry-run: удалил бы {SLUG} ({current.get('id')})")
            return 0
        status, body = call(f"{endpoints_url}{current['id']}", key=key, method="DELETE")
        print(f"[mcp-reg] удаление: HTTP {status}")
        return 0 if status < 300 else 1

    body = {
        "endpoint": {
            "name": NAME,
            "slug": SLUG,
            "description": "Read-only инструменты проекта: объекты, слоты, карточка объекта",
            "auth_mode": "none",
            "data": {
                # Слэш на конце обязателен: без него смонтированное приложение отвечает 307,
                # а POST с телом на редирект может уехать без тела.
                "route": {"base_url": public_url},
                # В шлюзе видно, что мы отдаём ровно три инструмента, — это и есть
                # декларация поверхности, которую видит агент.
                "tools": {"allowlist": TOOLS},
                "settings": {},
            },
        }
    }

    if args.dry_run:
        print("[mcp-reg] dry-run, было бы отправлено:")
        print(json.dumps(body, ensure_ascii=False, indent=2))
        return 0

    if current:
        # При обновлении id обязан быть и в пути, и в теле: платформа сверяет их и
        # отвечает «Path endpoint_id does not match body id», если тело без id.
        body["endpoint"]["id"] = current["id"]
        status, created = call(f"{endpoints_url}{current['id']}", key=key, method="PUT", body=body)
        action = "обновлён"
    else:
        status, created = call(endpoints_url, key=key, method="POST", body=body)
        action = "создан"

    if status >= 300:
        print(f"[mcp-reg] FAIL: эндпоинт не {action} (HTTP {status}): {created}", file=sys.stderr)
        return 1
    print(f"[mcp-reg] эндпоинт {action}: slug={SLUG}, url={public_url}")

    # Проверка не по нашему ответу, а по ответу платформы: она сама дёрнет наш сервер.
    # У probe своя форма запроса: только `url`. Отправлять туда тело создания эндпоинта
    # нельзя — платформа ответит 422, и это будет ошибкой клиента, а не сервера.
    status, probe = call(
        f"{base}/gateways/mcps/endpoints/probe", key=key, method="POST", body={"url": public_url}
    )
    if status == 200:
        print("[mcp-reg] probe: HTTP 200 — платформа видит сервер")
        print(f"[mcp-reg] ответ probe: {json.dumps(probe, ensure_ascii=False)[:400]}")
    else:
        print(f"[mcp-reg] ВНИМАНИЕ: probe вернул HTTP {status}: {json.dumps(probe, ensure_ascii=False)[:300]}")
        print("[mcp-reg] если платформа не видит сервер, проверьте: MCP-слушатель поднят,")
        print("[mcp-reg] адрес доступен из контейнера, host.docker.internal в allowlist платформы")

    print()
    print("[mcp-reg] Дальше: объявить эндпоинт в ревизии агента —")
    print(f"[mcp-reg]   mcps: [{{connection: {{type: gateway, namespace: custom, slug: {SLUG}}}}}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
