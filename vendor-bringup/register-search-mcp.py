#!/usr/bin/env python3
"""Направить шлюз платформы на НАШ поиск (`E22`): эндпоинт `searxng` → своя обёртка.

**Зачем отдельный инструмент.** Поиск для агентов платформы подключается не кодом, а записью в
шлюзе: агенты (`realtor-bot`, `news-hunter` и три роли) ссылаются на MCP-эндпоинт по `slug`, и
именно шлюз решает, куда звонить. Пока в записи стоял ЧУЖОЙ инстанс (`host.docker.internal:3000`,
стек другого проекта), наши решения `E32` («поиск свой») и `E23` («всё в контейнерах») на
платформенном пути не действовали вовсе: там продолжал отвечать чужой контейнер.

**Почему адрес именно такой.** Вызывающий — платформа, а она живёт в контейнерах, поэтому адрес
зависит от того, где живёт поиск:
* наш поиск теперь **в той же docker-сети** (`realty/compose.realty.yaml`) ⇒ правильный адрес — **имя
  сервиса** `http://mcp-searxng:3000/mcp` (проверено: из контейнера платформы отвечает);
* `localhost` в контейнере не даёт ничего, а `host.docker.internal:3001` не работает, потому что наш
  сервис опубликован только на loopback (проверено: код `000`) — то есть подстановка «по аналогии»
  здесь ломает путь молча.

**Проверка — ответом платформы, а не нашим.** После записи инструмент зовёт `probe`: платформа сама
дёргает адрес и отдаёт список инструментов. Наш собственный `curl` доказал бы только то, что
контейнер жив, а не то, что шлюз его видит.

    PYTHONPATH=realty:news .venv/bin/python infra/vendor-bringup/register-search-mcp.py --dry-run
    PYTHONPATH=realty:news .venv/bin/python infra/vendor-bringup/register-search-mcp.py
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]

#: Эндпоинт, на который ссылаются агенты. Имя — от чужого инстанса (историческое), поэтому
#: переименование сломало бы ссылки в ревизиях; меняем адрес, а не имя.
SLUG = "searxng"
#: Имя сервиса в docker-сети нашего compose (там же, где платформа) + внутренний порт обёртки.
DEFAULT_URL = "http://mcp-searxng:3000/mcp"


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
    parser = argparse.ArgumentParser(description="Направить эндпоинт searxng шлюза на нашу обёртку")
    parser.add_argument("--base", help="адрес API платформы (по умолчанию из .env)")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"новый адрес (по умолчанию {DEFAULT_URL})")
    parser.add_argument("--slug", default=SLUG, help=f"эндпоинт в шлюзе (по умолчанию {SLUG})")
    parser.add_argument("--dry-run", action="store_true", help="показать, что было бы отправлено")
    args = parser.parse_args()

    env = load_env(ROOT / ".env")
    key = env.get("PLATFORM_API_KEY", "")
    if not key:
        print("[search-mcp] FAIL: PLATFORM_API_KEY не задан в .env", file=sys.stderr)
        return 1
    # `.env` хранит адрес API ВНУТРИ docker-сети (`http://api:8000/api`) — из хоста он не разрешается.
    # Инструмент запускается с хоста, поэтому берём хостовый адрес (`PLATFORM_API_URL_HOST`, 8680) —
    # тот же приём, что в `infra/vendor-bringup/register-mcp.py` и `news/bridge-up-news.sh`.
    base = (args.base or env.get("PLATFORM_API_URL_HOST") or "http://127.0.0.1:8680/api").rstrip("/")
    endpoints_url = f"{base}/gateways/mcps/endpoints/"

    status, payload = call(endpoints_url, key=key)
    if status == 403:
        print("[search-mcp] FAIL: у ключа нет прав на MCP-эндпоинты (403) — нужен EDIT_MCP_ENDPOINTS",
              file=sys.stderr)
        return 1
    if status != 200:
        print(f"[search-mcp] FAIL: список эндпоинтов недоступен (HTTP {status}): {payload}",
              file=sys.stderr)
        return 1

    current = next((item for item in payload.get("endpoints", []) if item.get("slug") == args.slug), None)
    if current is None:
        print(f"[search-mcp] FAIL: эндпоинта {args.slug!r} в шлюзе нет — сначала заведите его", file=sys.stderr)
        return 1

    data = dict(current.get("data") or {})
    route = dict(data.get("route") or {})
    was = route.get("base_url")
    route["base_url"] = args.url
    data["route"] = route

    body = {
        "endpoint": {
            "id": current["id"],  # id обязателен и в пути, и в теле: иначе «Path endpoint_id does not match body id»
            "name": current.get("name") or args.slug,
            "slug": args.slug,
            "description": current.get("description"),
            "auth_mode": current.get("auth_mode") or "none",
            "data": data,  # tools/settings сохраняем как были: меняем ТОЛЬКО адрес
        }
    }
    print(f"[search-mcp] было: {was}")
    print(f"[search-mcp] станет: {args.url}")

    if args.dry_run:
        print("[search-mcp] dry-run, тело не отправлено:", json.dumps(body, ensure_ascii=False)[:300])
        return 0

    status, updated = call(f"{endpoints_url}{current['id']}", key=key, method="PUT", body=body)
    if status >= 300:
        print(f"[search-mcp] FAIL: эндпоинт не обновлён (HTTP {status}): {updated}", file=sys.stderr)
        return 1
    print(f"[search-mcp] эндпоинт обновлён: slug={args.slug}")

    # Проверка ответом ПЛАТФОРМЫ: она сама дёрнет наш адрес и перечислит инструменты.
    status, probe = call(f"{base}/gateways/mcps/endpoints/probe", key=key, method="POST",
                         body={"url": args.url})
    if status != 200:
        print(f"[search-mcp] ВНИМАНИЕ: probe ответил HTTP {status}: {probe}", file=sys.stderr)
        return 1
    # ⚠️ Платформа отвечает в форме `{count, probe: {reachable, server_name, protocol_version, auth}}`,
    # а НЕ списком инструментов. Первая редакция искала поле `tools`, не находила его и печатала
    # «инструменты: []» — то есть выглядела как «сервер пустой», хотя он отвечал (найдено фактом:
    # в probe нет ключа tools вовсе). Читаем то, что платформа действительно сообщает.
    detail = probe.get("probe") or {}
    reachable = detail.get("reachable")
    server_name = detail.get("server_name") or "?"
    print(f"[search-mcp] probe: HTTP 200, достижим: {reachable}, сервер: {server_name}")
    if reachable is not True:
        print("[search-mcp] ВНИМАНИЕ: платформа НЕ подтвердила достижимость — проверьте адрес и сеть",
              file=sys.stderr)
        return 1
    print("[search-mcp] состав инструментов платформа здесь не сообщает; проверять клиентом продукта "
          "(как и делали: McpToolbox → tools/list)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
