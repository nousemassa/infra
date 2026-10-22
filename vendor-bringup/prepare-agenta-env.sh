#!/usr/bin/env bash
# Готовит hosting/docker-compose/oss/.env.oss.gh: секреты + nano-профиль (аудит R11).
#
# Идемпотентно и БЕЗ дублей: все существующие вхождения управляемых переменных (включая
# закомментированные и ранее дописанные) удаляются, значения сохраняются (первые не-placeholder),
# затем переменные добавляются ОДНИМ каноническим блоком.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   #: корень воркспейса
OSS="$ROOT/vendor/agenta/hosting/docker-compose/oss"
EX="$OSS/env.oss.gh.example"
ENV_FILE="$OSS/.env.oss.gh"

[[ -f "$EX" ]] || { echo "нет $EX — сначала infra/vendor-bringup/vendor-agenta.sh"; exit 1; }
[[ -f "$ENV_FILE" ]] || { cp "$EX" "$ENV_FILE"; echo "[env] создан из примера: $ENV_FILE"; }

python3 - "$ENV_FILE" <<'PY'
import base64, os, re, secrets, sys

path = sys.argv[1]
raw = open(path, encoding="utf-8").read().splitlines()

MARK = "# --- managed by prepare-agenta-env.sh ---"

SECRETS = {
    "AGENTA_AUTH_KEY": lambda: secrets.token_urlsafe(32),
    "AGENTA_SERVICES_INTERNAL_KEY": lambda: secrets.token_urlsafe(32),
    "AGENTA_CRYPT_KEY": lambda: base64.b64encode(os.urandom(32)).decode(),
    "AGENTA_RUNNER_TOKEN": lambda: secrets.token_urlsafe(32),
    "AGENTA_STORE_ACCESS_KEY": lambda: secrets.token_urlsafe(32),
    "AGENTA_STORE_SECRET_KEY": lambda: secrets.token_urlsafe(32),
    "AGENTA_STORE_SIGNING_KEY": lambda: base64.b64encode(os.urandom(32)).decode(),
}

SETTINGS = {
    # ВАЖНО: версионных образов для v0.121.5 в GHCR нет (api: ≤0.64.0, остальные — latest).
    # `latest` совпадает с закреплённым исходником (main == тег v0.121.5 байт-в-байт).
    "AGENTA_HOST": "http://api:8000",   # SDK: хост для verify-запросов (без него — cloud.agenta.ai)
    "AGENTA_API_URL": "http://api:8000/api",
    "AGENTA_SERVICES_URL": "http://services:8080/services",   # invoke-путь API→services→runner (внутри сети)   # runner/dispatch: внутренний адрес (localhost внутри контейнера = сам контейнер)
    "AGENTA_WEB_IMAGE_TAG": "latest",
    "AGENTA_API_IMAGE_TAG": "latest",
    "AGENTA_SERVICES_IMAGE_TAG": "latest",
    "AGENTA_RUNNER_IMAGE_TAG": "latest",
    "AGENTA_WEB_MOBILE_IMAGE_TAG": "latest",
    # БД: имена/роль фиксированы api/oss/databases/postgres/init-db-oss.sql
    #: ❗ Значения ниже фиксированы ВЕНДОРОМ (его `init-db-oss.sql` создаёт эти роль и пароль) и относятся
    #: только к стеку платформы. Наши базы живут отдельно и пароли берут из своего `.env`.
    "POSTGRES_USER": "username",
    "POSTGRES_PASSWORD": "password",
    # хостовые порты: 5432 (хостовый PG), 80 (хост-процесс), 8080 (searxng) заняты
    "POSTGRES_PORT": "55432",
    "TRAEFIK_PORT": "8680",
    "TRAEFIK_UI_PORT": "8681",
    "POSTGRES_URI_CORE": "postgresql+asyncpg://username:password@postgres:5432/agenta_oss_core",
    "POSTGRES_URI_SUPERTOKENS": "postgresql://username:password@postgres:5432/agenta_oss_supertokens",
    "POSTGRES_URI_TRACING": "postgresql+asyncpg://username:password@postgres:5432/agenta_oss_tracing",
    # nano-профиль: один тёплый слот, короткий TTL, без keepalive, малый параллелизм
    "AGENTA_RUNNER_SESSION_POOL_MAX": "1",
    "AGENTA_RUNNER_SESSION_TTL_MS": "300000",
    "AGENTA_RUNNER_SESSION_KEEPALIVE": "false",
    "AGENTA_RUNNER_CONCURRENCY_LIMIT": "4",
    "AGENTA_SESSIONS_LIVE_STREAM_MAXLEN": "5000",
    # безопасность: закрыть egress/приватные цели, PII-редакция, без телеметрии
    "AGENTA_LLM_GATEWAY_ENABLED": "true",
    "AGENTA_GATEWAYS_INSECURE_EGRESS_ALLOWED": "false",
    "AGENTA_GATEWAYS_INSECURE_HTTP_ALLOWED": "true",   # single-tenant local: Разрешает выдачу gateway-креденшелов по http; в проде — HTTPS или осознанно оставить true только на доверенном контуре
    # Узкая лазейка вместо глобального флага (она и рекомендована платформой): охрана egress
    # (`core/gateways/egress.py::validate_egress_url_format`) отвергает `http`-адрес при СОХРАНЕНИИ,
    # если хост не в этом списке, — а наши эндпоинты внутренние и ходят по http. Список ДОПОЛНЯЕТСЯ:
    # `host.docker.internal` нужен второму эндпоинту (`realty-mcp`), `mcp-searxng` — нашему
    # поиску после `E32`. Забудь одно из значений — сломается тот эндпоинт, а выглядеть это будет как
    # «сервер лежит»: ошибка приходит от платформы, не от нас.
    "AGENTA_MCP_GATEWAY_HOST_ALLOWLIST": "host.docker.internal,mcp-searxng",
    "AGENTA_INSECURE_EGRESS_ALLOWED": "false",
    "AGENTA_REDACTION_MODE": "known",
    "AGENTA_REDACTED_PREFIXES": "+7,8",
    "POSTHOG_API_KEY": "",
}

MANAGED = set(SECRETS) | set(SETTINGS)

# 1) отделяем «наши» блоки и собираем существующие значения (первое не-placeholder вхождение)
kept, existing = [], {}
for line in raw:
    if line.strip() == MARK:
        continue
    stripped = line.strip()
    if stripped.startswith("#"):
        continue  # выкидываем и закомментированные дубли управляемых переменных
    if "=" not in stripped:
        kept.append(line)
        continue
    key, value = stripped.split("=", 1)
    key, value = key.strip(), value.strip()
    if key in MANAGED:
        if key in SECRETS and value not in ("", "replace-me") and key not in existing:
            existing[key] = value
        continue  # удаляем все вхождения — добавим канонически ниже
    kept.append(line)

# 2) дописываем ОДИН канонический блок
block = ["", MARK]
for key, gen in SECRETS.items():
    block.append(f"{key}={existing.get(key) or gen()}")
for key, value in SETTINGS.items():
    block.append(f"{key}={value}")

open(path, "w", encoding="utf-8").write("\n".join(kept + block) + "\n")
print(f"[env] канонизировано: секретов={len(SECRETS)} (сохранено прежних={len(existing)}), настроек={len(SETTINGS)}")
PY

chmod 600 "$ENV_FILE"
echo "[env] проверка уникальности управляемых переменных:"
dupes=$(grep -cE '^(AGENTA_AUTH_KEY|AGENTA_SERVICES_INTERNAL_KEY|AGENTA_CRYPT_KEY|AGENTA_RUNNER_TOKEN|POSTGRES_PORT|TRAEFIK_PORT)=' "$ENV_FILE" | head -1)
for v in AGENTA_AUTH_KEY AGENTA_SERVICES_INTERNAL_KEY AGENTA_CRYPT_KEY AGENTA_RUNNER_TOKEN AGENTA_STORE_SIGNING_KEY POSTGRES_PORT TRAEFIK_PORT TRAEFIK_UI_PORT; do
  n=$(grep -c "^$v=" "$ENV_FILE")
  printf '  %-32s %s\n' "$v" "$n вхожд."
  [[ "$n" == "1" ]] || { echo "[env] ОШИБКА: $v встречается $n раз"; exit 3; }
done
echo "[env] ok: $ENV_FILE (600)"
