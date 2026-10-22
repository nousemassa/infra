#!/usr/bin/env bash
# Контейнеры ПЕРЕЖИВАЮТ перезагрузку и не проигрывают порт юнитам.
#
# **Зачем два вызова.** «Посмотреть после перезагрузки, всё ли на месте» руками каждый раз означает
# сравнивать по памяти: что именно было запущено, у кого были порты, сколько строк в журналах. Снимок
# делает сравнение доказательством, а не впечатлением — и переживает загрузку, потому что лежит НЕ в /tmp
# (`/tmp` здесь `tmpfs`: снимок там исчез бы ровно тогда, когда нужен).
#
# **Что именно проверяется (четыре отдельных утверждения, а не «зелено»).** Отказ, который эта проверка
# ловит: хост-юнит занимает порт раньше контейнера, и контейнер молча лежит
# (`ExitCode=137`, `OOMKilled=false`, `Error="failed to bind port … address already in use"`). Поэтому:
#   1) каждый наш контейнер поднялся САМ (`restart: unless-stopped`);
#   2) каждый порт снова у контейнера (и ни один enabled-юнит не занял наш порт);
#   3) в журналах НЕ прибавилось строк логина (сессия Telegram переиспользована, повторного `bot`-логина
#      не было) — счётчики строк берутся из снимка;
#   4) сторожа дают `ok`, дрейф окружения отсутствует.
#
# **Что ожидаемо и НЕ является провалом.** Порт 8088 свободен: он не наш, поэтому держателя у него быть
# не должно — если кто-то занял порт, проверка это назовёт.
#
#   bash infra/checks/reboot-roundtrip.sh --before     # снимок ДО (на диск, не в /tmp)
#   bash infra/checks/reboot-roundtrip.sh --after      # проверка ПОСЛЕ, со сравнением и вердиктом
#
# Переменные: REBOOT_SNAPSHOT (путь снимка), REBOOT_WAIT (сколько ждать готовности, с).
set -uo pipefail

#: Корни: `$INFRA` — сама обвязка, `$WORKSPACE` — воркспейс (там `.env` и каталоги проектов).
#: Взяты из ОДНОГО места: путь к воркспейсу — настройка (`AGENT_WORKSPACE`, её задают юниты),
#: а не расположение файла — иначе переезд `infra/` в свой репозиторий сломает скрипт молча.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"
#: Вендоры и их стеки — из одного места: пара «выбранный/другой» не должна быть зашита.
source "$INFRA/lib/vendor.sh"
SNAPSHOT="${REBOOT_SNAPSHOT:?не задан REBOOT_SNAPSHOT — путь снимка на реальном диске (НЕ /tmp: он tmpfs)}"
WAIT_S="${REBOOT_WAIT:-240}"

# Наши службы и их порты: список нужен, чтобы отличать «наш порт» от чужих и чтобы число портов в проверке
# не зависело от того, что ещё живёт на хосте.
#: ❗ 55435 — опубликованный порт базы `bridge` в НАШЕМ стеке данных (`data`).
#: 55432 остаётся в списке: это порт ВЕНДОРСКОГО postgres, и он обязан быть на месте, пока
#: вендорский стек поднят (наши данные там больше не лежат).
OUR_PORTS=(8082 8083 8085 8086 8087 8089 8090 3001 55432 55433 55434 55435)
#: 8090/3001 — поиск и его MCP-обёртка (проект `search`): в списке, потому что порт, вернувшийся не к
#: нам, иначе прошёл бы зелёным.
#: 8088 не наш порт: держателя у него быть не должно.

#: Наши контейнеры перечисляем по МЕТКЕ ПРОЕКТА, а не по подстроке имени: подстрока не совпала бы у служб,
#: живущих в отдельных проектах (`models`, `search`), и проверка перезагрузки МОЛЧА перестала бы видеть
#: эти службы — при зелёном вердикте. Список проектов — общий, один на всех.
PROJECTS_FILE="$INFRA/compose-projects.tsv"

#: Наши контейнеры: без аргумента — только работающие, с `-a` — все. Пустой вывод при непустом списке
#: проектов означает «ничего не нашли», и это видно в снимке (сравнение чисел в вердикте).
our_containers() {
  local extra="${1:-}" project
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    echo "[reboot] ОСТАНОВ: нет $PROJECTS_FILE — перечислить наши контейнеры нечем" >&2
    return 1
  fi
  while IFS=$'\t' read -r project _rest; do
    [[ -z "${project// /}" || "$project" == \#* ]] && continue
    docker ps ${extra:+"$extra"} --filter "label=com.docker.compose.project=$project" --format '{{.Names}}'
  done < "$PROJECTS_FILE" | sort
}

measure() {
  # Печатает снимок измерений в JSON на stdout. Одна и та же функция для «до» и «после» — иначе
  # сравнивались бы разные вещи.
  local containers units logs sessions watchdogs drift vram vendor telemetry vendor_stacks
  # Режим вендора: от него зависит, КАКОЙ стек обязан быть жив после перезагрузки.
  vendor="$(sed -n 's/^PLATFORM_VENDOR=//p' "$WORKSPACE/.env" 2>/dev/null | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  vendor="${vendor:-$(vendor_capability_default)}"
  #: ❗ ОСЕЙ ДВЕ. `PLATFORM_VENDOR` — кто исполняет ход, `TELEMETRY_VENDOR` — чей приёмник принимает
  #: трассы. Стек оси наблюдаемости обязан работать после перезагрузки ровно так же, как стек оси
  #: рантайма: называть его «невыбранным» значило бы требовать погасить приёмник трасс.
  telemetry="$(sed -n 's/^TELEMETRY_VENDOR=//p' "$WORKSPACE/.env" 2>/dev/null | head -1 | tr -d '"'"'"'' | tr -d '[:space:]')"
  telemetry="${telemetry:-$vendor}"
  # Составы стеков считаем по факту, отдельно от нашего реестра проектов: стек вендора в реестр НЕ входит
  # (он не наш compose-проект). Перечень вендоров и имя проекта каждого — из `infra/vendors.tsv`, чтобы
  # «выбранный/другой» не были зашитой парой имён.
  vendor_stacks="$(
    while IFS=$'\t' read -r name _ _ _ _ _ project; do
      [[ "$name" == \#* || -z "$name" ]] && continue
      names=""
      if [[ -n "$project" ]]; then
        names="$(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',')"
      fi
      printf '%s|%s\n' "$name" "$names"
    done < "$VENDORS_FILE"
  )"
  containers="$(for c in $(our_containers -a); do
    state="$(docker inspect "$c" --format '{{.State.Status}}')"
    health="$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    policy="$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}')"
    restarts="$(docker inspect "$c" --format '{{.RestartCount}}')"
    started="$(docker inspect "$c" --format '{{.State.StartedAt}}')"
    printf '%s|%s|%s|%s|%s|%s\n' "$c" "$state" "$health" "$policy" "$restarts" "$started"
  done)"
  units="$(systemctl --user list-unit-files 'bridge-*' --no-pager --no-legend | awk '{print $1"|"$2}')"
  logs="$(for c in $(our_containers); do
    total="$(docker logs "$c" 2>&1 | wc -l)"
    logins="$(docker logs "$c" 2>&1 | grep -icE 'signed in|logged in|login')"
    printf '%s|%s|%s\n' "$c" "$total" "$logins"
  done)"
  #: ❗ Сессии лежат в каталогах СВОИХ проектов (`realty/.sessions`, `news/.sessions`), поэтому жёсткий
  #: путь потерял бы часть сессий из снимка — тихо, при зелёном вердикте.
  #: Поэтому ищем по дереву: любой `<проект>/.sessions/*.session`.
  sessions="$(find "$WORKSPACE" -path '*/.sessions/*.session' -type f 2>/dev/null | sort | while read -r f; do
    printf '%s|%s|%s|%s\n' "${f#$WORKSPACE/}" "$(stat -c %a "$f")" "$(stat -c %U:%G "$f")" "$(stat -c %s "$f")"
  done)"
  # Вердикт берётся по КОДУ ВЫХОДА и первой строке `FAIL`/`ok`, а не по последней строке вывода:
  # последней у сторожей идёт строка алерта («АЛЕРТ доставлен…»), и красный читался бы как здоровый.
  watchdogs="$(#: ❗ Список ПОИМЁННЫЙ: каждый `infra/health/health-*.sh` обязан иметь таймер в списке
  #: включения `install.sh`, иначе новый сторож молча не попадёт в проверку перезагрузки.
  for s in health health-news health-mcp health-reminders health-embed health-solver health-search health-drift health-prompts; do
    if out="$(bash "$INFRA/health/$s.sh" 2>&1)"; then rc=0; else rc=$?; fi
    verdict="$(printf '%s\n' "$out" | grep -m1 -E 'FAIL|^\[.*\] ok$' || true)"
    [[ -z "$verdict" ]] && verdict="$(printf '%s\n' "$out" | tail -1)"
    [[ "$rc" -ne 0 ]] && verdict="КРАСНЫЙ: $verdict"
    printf '%s|%s\n' "$s" "$verdict"
  done)"
  drift="$(python3 "$INFRA/checks/check-stack-drift.py" >/dev/null 2>&1 && echo "чисто" || echo "ЕСТЬ РАСХОЖДЕНИЯ")"
  vram="$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>/dev/null | sort)"
  ports="$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/.*://' | sort -n | uniq | tr '\n' ' ')"
  ports_ours="$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/.*://' | sort -n | uniq \
                | grep -xE "$(printf '%s|' "${OUR_PORTS[@]}" | sed 's/|$//' | tr '|' '\n' | paste -sd'|')" | tr '\n' ' ')"
  holder_8088="$(ss -ltnp 2>/dev/null | awk '/:8088 /{print $6}' | head -1)"

  python3 - "$containers" "$units" "$logs" "$sessions" "$watchdogs" "$drift" "$vram" "$ports_ours" "$holder_8088" "$vendor" "$telemetry" "$vendor_stacks" <<'PY'
import json, sys
containers, units, logs, sessions, watchdogs, drift, vram, ports_ours, holder, vendor, telemetry, vstacks = sys.argv[1:13]

def rows(text, fields):
    out = []
    for line in text.strip().splitlines():
        if not line.strip():
            continue
        parts = line.split("|")
        out.append(dict(zip(fields, parts)))
    return out

print(json.dumps({
    "containers": rows(containers, ("name", "state", "health", "policy", "restarts", "started")),
    "units": rows(units, ("unit", "state")),
    "logs": rows(logs, ("name", "lines", "logins")),
    "sessions": rows(sessions, ("file", "mode", "owner", "bytes")),
    "watchdogs": rows(watchdogs, ("name", "verdict")),
    "drift": drift,
    "vram": [line for line in vram.splitlines() if line.strip()],
    "ports_ours": ports_ours.split(),
    "holder_8088": holder,
    "vendor": vendor,
    "telemetry_vendor": telemetry,
    "vendor_stacks": rows(vstacks, ("vendor", "running")),
}, ensure_ascii=False, indent=2))
PY
}

if [[ "${1:-}" == "--before" ]]; then
  measure > "$SNAPSHOT" || { echo "[reboot] не удалось снять снимок" >&2; exit 1; }
  echo "[reboot] снимок ДО: $SNAPSHOT"
  case "$(findmnt -no FSTYPE --target "$(dirname "$SNAPSHOT")" 2>/dev/null)" in
    tmpfs) echo "[reboot] ВНИМАНИЕ: каталог снимка на tmpfs — снимок НЕ переживёт перезагрузку" >&2; exit 1 ;;
    *) echo "[reboot] каталог снимка на реальном диске ✓" ;;
  esac
  python3 - "$SNAPSHOT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  контейнеров: {len(d['containers'])} (running: {sum(1 for c in d['containers'] if c['state'] == 'running')})")
print(f"  наших портов слушает: {len(d['ports_ours'])};  порт 8088 держит: {d['holder_8088'] or '—'}")
print(f"  сторожей ok: {sum(1 for w in d['watchdogs'] if 'ok' in w['verdict'])}/{len(d['watchdogs'])}; дрейф: {d['drift']}")
PY
  exit 0
fi

if [[ "${1:-}" != "--after" ]]; then
  echo "использование: $0 --before | --after" >&2
  exit 2
fi

[[ -f "$SNAPSHOT" ]] || { echo "[reboot] нет снимка ДО ($SNAPSHOT) — сначала --before" >&2; exit 1; }
#: ❗ Снимок «после» снимается ПОСЛЕ ожидания готовности: пока `measure` стоял выше цикла, вердикт
#: судил контейнер, который ещё поднимался (`health: starting`), и «жди до 240 с» ни на что не влияло.
echo "[reboot] жду готовности контейнеров (до ${WAIT_S} с)…"
deadline=$(( $(date +%s) + WAIT_S ))
while :; do
  # Готовность = «поднят И (здоров ИЛИ без healthcheck)». Ждать «не starting» мало: контейнер, который
  # ещё поднимается (`starting`), уже не `starting`-исключение, но служба за ним недоступна — проверка
  # краснеет, а сторож в этот же момент шлёт владельцу алерт «бот недоступен». Ждать надо готовности,
  # а не отсутствия одного из состояний.
  not_ready="$(python3 - "$SNAPSHOT" <<'PY'
import json, subprocess, sys
# ❗ Ждём готовности только тех, кто РАБОТАЛ до перезагрузки. Одноразовые (`migrate`, `alembic`) имеют
# `restart: "no"` и после ребута НЕ запускаются — это правильно, но ожидание их «готовности» давало
# «не дождался готовности: …-migrate-1» при зелёном вердикте: шум, читающийся как сбой.
before = {c["name"] for c in json.load(open(sys.argv[1]))["containers"] if c["state"] == "running"}
out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True).stdout.split()
running = set(out) & before
health = {}
for name in sorted(running):
    health[name] = subprocess.run(["docker", "inspect", name, "--format",
                                   "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"],
                                  capture_output=True, text=True).stdout.strip()
not_ready = sorted(before - running) + sorted(n for n, h in health.items() if h not in ("healthy", "none"))
print(",".join(not_ready))
PY
)"
  [[ -z "$not_ready" ]] && break
  [[ "$(date +%s)" -ge "$deadline" ]] && { echo "[reboot] не дождался готовности: $not_ready" >&2; break; }
  sleep 5
done
measure > "$SNAPSHOT.after"

# GPU-процессы: наша потеря — ОТКАЗ, изменение чужих — пояснение. Логика вынесена в
# `checks/gpu-verdict.py`, чтобы её можно было доказать без перезагрузки (`--self-test`).
gpu_problems=""; gpu_notes=""
if [[ -f "$SNAPSHOT" && -f "$SNAPSHOT.after" ]]; then
  gpu_out="$(python3 "$INFRA/checks/gpu-verdict.py" "$SNAPSHOT" "$SNAPSHOT.after" 2>/dev/null)"
  gpu_problems="$(printf '%s\n' "$gpu_out" | sed -n 's/^PROBLEM: //p')"
  gpu_notes="$(printf '%s\n' "$gpu_out" | sed -n 's/^NOTE: //p')"
fi

python3 - "$SNAPSHOT" "$SNAPSHOT.after" "$gpu_problems" "$gpu_notes" <<'PY'
import json, sys

before = json.load(open(sys.argv[1]))
after = json.load(open(sys.argv[2]))
#: Два готовых списка от `checks/gpu-verdict.py`: отказы и пояснения (печатаются построчно).
gpu_problems_arg, gpu_notes_arg = sys.argv[3], sys.argv[4]
problems = []
notes = []

# 1) каждый контейнер, который РАБОТАЛ до перезагрузки, поднялся сам.
# ❗ «Был не running — не судим»: в режиме другого вендора продуктовый контур погашен ОСОЗНАННО, и без
# этой оговорки вердикт был бы красным по НЕВЕРНОЙ причине (тот же изъян латентно касался и `migrate`,
# который выходит штатно). Судим только тех, кого до перезагрузки видели живыми.
for was in before["containers"]:
    if was["state"] != "running":
        continue
    now = next((c for c in after["containers"] if c["name"] == was["name"]), None)
    if now is None:
        problems.append(f"контейнер {was['name']} ИСЧЕЗ (был {was['state']})")
    elif now["state"] != "running":
        problems.append(f"контейнер {now['name']} не поднялся: {now['state']} (политика {now['policy']})")
    elif now["health"] not in ("healthy", "none"):
        problems.append(f"контейнер {now['name']} не здоров: {now['health']}")
    elif now["policy"] != was["policy"]:
        problems.append(f"контейнер {now['name']}: политика рестарта изменилась "
                        f"({was['policy']} → {now['policy']}) — переживёт ли это следующий ребут, неизвестно")

# 1b) УТВЕРЖДЕНИЕ РЕЖИМА (требование владельца): после перезагрузки жив РОВНО выбранный стек.
vendor = after.get("vendor") or before.get("vendor") or "?"
telemetry = after.get("telemetry_vendor") or after.get("vendor") or "?"
stacks = {row["vendor"]: [x for x in (row["running"] or "").split(",") if x] for row in after["vendor_stacks"]}
#: Оси ДВЕ, и оба выбранных вендора — выбранные: рантайм и наблюдаемость.
selected = [name for name in dict.fromkeys([vendor, telemetry]) if name]
others = [name for name in stacks if name not in selected]
live = [f"{name} ({len(stacks[name])} контейнеров)" for name in selected if stacks.get(name)]
if live:
    notes.append(f"режим {', '.join(selected)}: подняты выбранные стеки — {'; '.join(live)}")
else:
    missing = [name for name in selected if name in stacks]
    if missing:
        problems.append(f"режим {', '.join(selected)}: ВЫБРАННЫЙ стек НЕ поднялся (0 контейнеров): {', '.join(missing)}")
    else:
        notes.append(f"режим {', '.join(selected)}: стеки этими проектами не поднимаются — проверять нечего")
for name in others:
    if stacks.get(name):
        problems.append(f"режим {', '.join(selected)}: поднялся и НЕвыбранный стек {name} ({', '.join(stacks[name])}) — "
                        f"нарушено «после перезагрузки стартует только выбранный»")
    else:
        notes.append(f"режим {', '.join(selected)}: стек {name} не поднялся ✓")

# 2) порты снова у контейнеров: наш набор портов должен совпасть
was_ports, now_ports = set(before["ports_ours"]), set(after["ports_ours"])
missing = was_ports - now_ports
if missing:
    problems.append(f"порты не вернулись: {', '.join(sorted(missing))} — их занял кто-то другой")
if now_ports - was_ports:
    notes.append(f"появились новые наши порты: {', '.join(sorted(now_ports - was_ports))}")

# 3) повторного логина не было: счётчики строк логина в журналах не выросли
for was in before["logs"]:
    now = next((l for l in after["logs"] if l["name"] == was["name"]), None)
    if now is None:
        continue
    if int(now["logins"]) > int(was["logins"]):
        problems.append(f"{now['name']}: в журнале появились строки логина "
                        f"({was['logins']} → {now['logins']}) — значит был повторный bot-логин")

# 4) сторожа и дрейф
for w in after["watchdogs"]:
    verdict = w["verdict"]
    #: ❗ НАЗВАННЫЙ ПРОПУСК — НЕ ОТКАЗ. У вендора без `runtime` продуктовый сторож молчит ОСОЗНАННО и
    #: печатает «не проверяется: PLATFORM_VENDOR=…». Поиск «ok» в вердикте записал бы такой пропуск в
    #: провалы, и ребут проходил бы «с ошибкой» из-за правильного поведения. Пропуск уходит в
    #: ПОЯСНЕНИЯ и называется там поимённо.
    if "не проверяется" in verdict:
        notes.append(f"сторож {w['name']}: {verdict[:100]}")
        continue
    if "ok" not in verdict:
        problems.append(f"сторож {w['name']}: {verdict[:80]}")
if after["drift"] != "чисто":
    problems.append(f"дрейф окружения: {after['drift']}")

# 8088 не наш порт: держателя у него быть не должно.
if after["holder_8088"]:
    notes.append(f"на порту 8088 кто-то есть: {after['holder_8088']} (этот порт не наш — проверьте, кто)")
#: GPU: наша потеря — ОТКАЗ, чужие процессы — пояснение (логика в `checks/gpu-verdict.py`).
for line in (gpu_problems_arg or "").splitlines():
    if line.strip():
        problems.append(line.strip())
for line in (gpu_notes_arg or "").splitlines():
    if line.strip():
        notes.append(line.strip())

for n in notes:
    print(f"  · {n}")
if problems:
    print(f"[reboot] НЕ ПРОЙДЕНО: {len(problems)}")
    for p in problems:
        print(f"  ✗ {p}")
    raise SystemExit(1)
print("[reboot] ПРОЙДЕНО: контейнеры поднялись сами, порты у контейнеров, повторного логина нет, "
      "сторожа ok, дрейфа нет")
PY
rc=$?
rm -f "$SNAPSHOT.after"
exit $rc
