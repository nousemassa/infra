#!/usr/bin/env bash
# Раскладка воркспейса: связи между репозиториями и ОКРУЖЕНИЕ каждого проекта из образцов.
# Ничего не перезаписывает без нужды: существующие .env сохраняются (там секреты и правки).
set -uo pipefail
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
WORKSPACE="${WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

PROJECTS=(realty news models search)         #: проекты с композами; `infra` и `agent-core` своих .env не имеют
echo "воркспейс: $WORKSPACE"

# 1) общая основа: образец лежит в infra (единственная копия знания о ключах общей основы)
base_example="$WORKSPACE/infra/templates/workspace/.env.example"
[[ -f "$base_example" ]] || { echo "[10] ОСТАНОВ: нет $base_example" >&2; exit 1; }
if [[ -f "$WORKSPACE/.env" ]]; then
  echo "  · общая основа уже есть: $WORKSPACE/.env (не трогаю)"
elif [[ "$CHECK" == "1" ]]; then
  echo "  · нет общей основы: $WORKSPACE/.env — создам из infra/templates/workspace/.env.example"
else
  cp "$base_example" "$WORKSPACE/.env"
  echo "  ✓ создана общая основа из образца: $WORKSPACE/.env (заполните секреты!)"
fi

# 2) реестр репозиториев: имя каталога проектов — часть контракта обвязки
if [[ ! -f "$WORKSPACE/repos.tsv" && "$CHECK" == "0" ]]; then
  cat > "$WORKSPACE/repos.tsv" <<'TSV'
# РЕПОЗИТОРИИ ВОРКСПЕЙСА: папка <табуляция> имя репозитория <табуляция> ветка <табуляция> url.
realty	realty	main	
news	news	main	
agent-core	agent-core	main	
models	models	main	
search	search	main	
infra	infra	main	
TSV
  echo "  ✓ создан реестр $WORKSPACE/repos.tsv"
fi

# 3) окружение проектов: из образца, с подсказкой, чего не хватает
for product in "${PROJECTS[@]}"; do
  dir="$WORKSPACE/$product"
  [[ -d "$dir" ]] || { echo "  · каталога $product нет — пропускаю" ; continue; }
  example="$dir/.env.example"
  [[ -f "$example" ]] || { echo "  ✗ у $product нет .env.example — агент не знает, что заполнять" >&2; continue; }
  if [[ -f "$dir/.env" ]]; then
    echo "  · $product/.env есть (не трогаю)"
  elif [[ "$CHECK" == "1" ]]; then
    echo "  · нет $product/.env — создам из образца"
  else
    cp "$example" "$dir/.env"
    echo "  ✓ $product/.env создан из образца"
  fi
done

# 4) каталоги, которые ждут службы (сессии и логи): создаём пустыми, содержимое — забота владельца
for product in realty news; do
  [[ -d "$WORKSPACE/$product" ]] || continue
  [[ "$CHECK" == "0" ]] && mkdir -p "$WORKSPACE/$product/.sessions" "$WORKSPACE/$product/logs"
done
echo "  · каталоги .sessions/ и logs/ у продуктов на месте"


#: Секреты, которые можно сгенерировать на месте: без них стенд не поднимется, а придумывать их
#: руками агент не должен. Пустое значение или CHANGE_ME заменяются, заполненное — НЕ трогается.

#: ❗ Том базы мог остаться от предыдущего запуска (имена томов заданы ЯВНО, поэтому совпадают).
#: Пароль в нём записан при первой инициализации: сгенерировать новый значит получить
#: `password authentication failed` на первом же накате. Такой том — состояние, а не пустое место.
volume_exists() { docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }
refuse_if_volume() {   # refuse_if_volume <том> <ключ пароля> <файл>
  local vol="$1" key="$2" file="$3" cur
  volume_exists "$vol" || return 0
  cur="$(sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1 | tr -d '\"' | tr -d '[:space:]')"
  [[ -n "$cur" && "$cur" != "CHANGE_ME" ]] && return 0     # секрет уже совпадает с томом
  echo "  ✗ том '$vol' уже существует, а $key в $(basename "$(dirname "$file")")/.env пуст или CHANGE_ME" >&2
  echo "     пароль записан в томе при его создании: задайте ТОТ ЖЕ пароль (или удалите том осознанно)" >&2
  VOLUME_CONFLICT=1
}

gen_secret() { python3 -c 'import secrets,sys; print(secrets.token_urlsafe(int(sys.argv[1])))' "${1:-32}"; }

fill_key() {   # fill_key <файл> <ключ> <длина>
  local file="$1" key="$2" len="${3:-32}" cur
  [[ -f "$file" ]] || return 0
  cur="$(sed -n "s/^${key}=//p" "$file" | head -1 | tr -d '\"' | tr -d "[:space:]")"
  [[ -n "$cur" && "$cur" != "CHANGE_ME" ]] && return 0
  local value; value="$(gen_secret "$len")"
  if grep -qE "^${key}=" "$file"; then
    python3 - "$file" "$key" "$value" <<'PY'
import sys, pathlib, re
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); text = p.read_text(encoding="utf-8")
text = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={value}", text, flags=re.M)
p.write_text(text, encoding="utf-8")
PY
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
  echo "    · $key: сгенерирован"
}

fill_dsn_password() {   # fill_dsn_password <файл> <ключ DSN> <переменная пароля> <длина>
  local file="$1" key="$2" passkey="$3" len="${4:-24}" cur pass
  [[ -f "$file" ]] || return 0
  cur="$(sed -n "s/^${key}=//p" "$file" | head -1)"
  pass="$(sed -n "s/^${passkey}=//p" "$file" | head -1 | tr -d '\"' | tr -d '[:space:]')"
  if [[ -z "$pass" || "$pass" == "CHANGE_ME" ]]; then
    pass="$(gen_secret "$len")"
    fill_key "$file" "$passkey" "$len"
  fi
  [[ "$cur" == *CHANGE_ME* ]] || return 0
  python3 - "$file" "$key" "$pass" <<'PY'
import re, sys, pathlib
path, key, password = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); text = p.read_text(encoding="utf-8")
def fix(match):
    line = match.group(0)
    return re.sub(r"(://[^:/@]+:)[^@]*(@)", lambda m: m.group(1) + password + m.group(2), line)
text = re.sub(rf"^{re.escape(key)}=.*$", fix, text, flags=re.M)
p.write_text(text, encoding="utf-8")
PY
  echo "    · $key: пароль подставлен"
}

VOLUME_CONFLICT=0
if [[ "$CHECK" == "0" ]]; then
  refuse_if_volume realty-db-data REALTY_DB_PASSWORD "$WORKSPACE/realty/.env"
  refuse_if_volume news-db-data NEWS_DB_PASSWORD "$WORKSPACE/news/.env"
  refuse_if_volume corpus-data VECTOR_DB_PASSWORD "$WORKSPACE/.env"
  if [[ "$VOLUME_CONFLICT" != "0" ]]; then
    echo "[10] ОСТАНОВ: секреты не совпадают с существующими томами баз (см. выше)" >&2
    exit 1
  fi
  echo "  секреты, которые можно сгенерировать на месте:"
  fill_key "$WORKSPACE/.env" UI_SECRET 24
  fill_key "$WORKSPACE/.env" BRIDGE_API_KEY 32
  fill_key "$WORKSPACE/realty/.env" REALTY_DB_PASSWORD 24
  fill_dsn_password "$WORKSPACE/realty/.env" DB_URL REALTY_DB_PASSWORD 24
  fill_key "$WORKSPACE/news/.env" NEWS_DB_PASSWORD 24
  fill_dsn_password "$WORKSPACE/news/.env" DB_URL NEWS_DB_PASSWORD 24
  fill_key "$WORKSPACE/search/.env" SEARXNG_SECRET 32
  #: Пароль векторной базы один на оба продукта: он же в основе (её читает композ).
  fill_key "$WORKSPACE/.env" VECTOR_DB_PASSWORD 24
  fill_key "$WORKSPACE/realty/.env" VECTOR_DB_PASSWORD 24
  fill_key "$WORKSPACE/realty/.env" GRAPH_DB_PASSWORD 24
fi

echo "[10] раскладка воркспейса готова"
