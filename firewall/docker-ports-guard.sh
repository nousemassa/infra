#!/usr/bin/env bash
# ОГРАНИЧЕНИЕ ОПУБЛИКОВАННЫХ ПОРТОВ ПО СЕТИ: наружу — ничего, контейнерам — можно.
#
# **Зачем.** Docker публикует порт в обход `INPUT` (DNAT + `FORWARD`), поэтому правила `ufw` на такие порты
# НЕ ДЕЙСТВУЮТ вообще: создаётся впечатление закрытого порта при открытом. Документированный хук Docker для
# пользовательских правил — цепочка `DOCKER-USER`, она проверяется ДО собственных правил Docker.
#
# **ЧТО ИМЕННО ЗАКРЫВАЕТСЯ И ПОЧЕМУ ЭТО НЕ ЛОМАЕТ РАБОТУ.** Каждый порт в списке нужен КОНТЕЙНЕРАМ (они
# ходят через адрес docker-моста) и не нужен машинам локальной сети. Проверено по композам:
#   4318 — приём OTLP стека наблюдаемости: спаны шлют контейнеры (`host.docker.internal:4318`, 3 места)
#   8087 — MCP-листенер: порт нужен вызывающей стороне через docker-хост (`host.docker.internal:8087`)
#   8680 — traefik платформы (UI и API): контейнеры ходят по `host.docker.internal:8680` (5 мест)
#   3000 — mcp-searxng: контейнеры ходят по ИМЕНИ службы `mcp-searxng:3000`
#   8080 — searxng: то же, по имени службы
# ❗ Хостовые процессы НЕ затрагиваются: их запросы идут через `OUTPUT`, а не `FORWARD`, поэтому пробы
# сторожей, дампы и `eval-live` на `127.0.0.1:*` продолжают работать как работали.
# ❗ ГЛАВНОЕ СЛЕДСТВИЕ, КОТОРОЕ НАДО ЗНАТЬ: UI платформы (`8680`) с ДРУГИХ устройств закрыт; доступ
# остаётся через ssh-туннель. Вернуть одному порту доступ из сети — одна команда (см. `open-one`).
#
#   bash infra/firewall/docker-ports-guard.sh apply       # поставить правила на все порты списка
#   bash infra/firewall/docker-ports-guard.sh status      # показать правила и СЧЁТЧИКИ (видно, что сработало)
#   bash infra/firewall/docker-ports-guard.sh remove       # снять свои правила (полный откат)
#   bash infra/firewall/docker-ports-guard.sh open-one N   # вернуть доступ из сети одному порту N
#
# Требует root. Правила iptables НЕ переживают перезагрузку — их ставит системный юнит
# `docker-ports-guard.service` (см. `install.sh` рядом).
set -uo pipefail

CHAIN="DOCKER-USER"
MARK="PORTS-GUARD"                     #: метка в комментарии: по ней находим ТОЛЬКО свои правила
#: ❗ ВАЖНО ПРО ПОРТЫ: в цепочке `FORWARD` виден УЖЕ ПОДМЕНЁННЫЙ порт (DNAT), поэтому правило обязано
#: матчить ВНУТРЕННИЙ порт контейнера, а не опубликованный. Замер: правило по `8680` не срабатывало ни
#: разу (счётчик DROP нулевой), потому что DNAT ведёт `8680 → …:80`.
PORTS=(4318 8087 3000 8080)     #: здесь опубликованный и внутренний СОВПАДАЮТ
MAPPED=(8680:80)                #: здесь РАЗЛИЧАЮТСЯ: опубликован 8680, внутри 80 (traefik)

die() { echo "[ports-guard] ОСТАНОВ: $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "нужен root (правила iptables меняются только от root)"
iptables -L "$CHAIN" -n >/dev/null 2>&1 || die "цепочки $CHAIN нет — docker не поднят? Её создаёт он"

#: Снимаем только свои правила (по метке), в цикле: после удаления нумерация сдвигается.
remove_rules() {
  local n
  #: Метки ДВЕ: наша нынешняя и «OTLP-GUARD» от первой редакции (охраняла только 4318). Снять надо обе —
  #: два набора правил на одни порты дают необъяснимое «то пускает, то нет».
  while n="$(iptables -L "$CHAIN" --line-numbers -n 2>/dev/null \
              | awk '/\*\// && (index($0, "PORTS-GUARD") || index($0, "OTLP-GUARD")) {print $1; exit}')" \
        && [[ -n "$n" ]]; do
    iptables -D "$CHAIN" "$n" || break
  done
}

#: Снять правила ОДНОГО порта (для `open-one`): полный `remove_rules` снял бы охрану со всех.
remove_rules_for() {
  local port="$1" n
  while n="$(iptables -L "$CHAIN" --line-numbers -n 2>/dev/null \
              | awk -v m="$MARK $port:" '/\*\// && index($0, m) {print $1; exit}')" && [[ -n "$n" ]]; do
    iptables -D "$CHAIN" "$n" || break
  done
}

#: Порты, которые реально надо охранять (внутренние).
targets() {
  local entry
  printf '%s\n' "${PORTS[@]}"
  for entry in "${MAPPED[@]}"; do printf '%s\n' "${entry#*:}"; done
}

apply_rules() {
  remove_rules
  local p
  for p in $(targets | sort -un); do
    #: ❗ Разрешаем ИНТЕРФЕЙС, а не подсети: у нас их ДВЕ (`172.27.x` и `10.10.x`), и правило вида
    #: `-s 10.0.0.0/8` впустило бы половину локальной сети — защита стала бы дырявой «для удобства».
    #: Трафик контейнеров к опубликованному порту приходит на docker-мост: `docker0` (сеть по умолчанию)
    #: или `br-XXXX` (созданные compose).
    #: ❗ ВСТАВКА В НАЧАЛО (`-I`), и в обратном порядке: Docker держит в этой цепочке свой `-j RETURN`,
    #: и правило, дописанное в конец, до него НЕ доходит. Замер до правки: правила стояли, счётчики DROP
    #: были нулевые, порты оставались ОТКРЫТЫ с чужого адреса. Итоговый порядок сверху вниз:
    #: docker0 → контейнеры, br-+ → контейнеры, остальное → DROP.
    iptables -I "$CHAIN" 1 -p tcp --dport "$p" -m comment --comment "$MARK $p: сеть запрещена" -j DROP
    iptables -I "$CHAIN" 1 -p tcp --dport "$p" -i 'br-+' -m comment --comment "$MARK $p: контейнеры" -j RETURN
    iptables -I "$CHAIN" 1 -p tcp --dport "$p" -i docker0 -m comment --comment "$MARK $p: контейнеры" -j RETURN
  done
}

case "${1:-status}" in
  apply)
    BK="/var/backups/infra-iptables-$(date +%Y%m%d-%H%M%S).rules"
    mkdir -p /var/backups && iptables-save > "$BK" 2>/dev/null && echo "[ports-guard] слепок до: $BK"
    apply_rules
    echo "[ports-guard] порты под охраной (внутренние): $(targets | sort -un | tr '\n' ' ')"
    iptables -L "$CHAIN" -n -v --line-numbers | grep -E "Chain|$MARK"
    ;;
  remove)
    remove_rules
    echo "[ports-guard] свои правила сняты (полный откат)"
    ;;
  status)
    echo "[ports-guard] порты под охраной (внутренние): $(targets | sort -un | tr '\n' ' ')"
    #: Печатаем ВСЮ цепочку: важно видеть, что стоит ВЫШЕ наших правил (там живёт docker'ов `RETURN`).
    iptables -L "$CHAIN" -n -v --line-numbers | head -14 | sed 's/^/  /'
    ;;
  open-one)
    PORT="${2:-}"; [[ -n "$PORT" ]] || die "укажите порт: $0 open-one 8680"
    remove_rules_for "$PORT"
    echo "[ports-guard] порт $PORT выведен из-под охраны (доступен из сети)"
    ;;
  *) die "использование: $0 apply|status|remove|open-one <порт>" ;;
esac
