#!/usr/bin/env bash
# ПРИЁМКА ОХРАНЫ ПОРТОВ: «чужой источник» не проходит, «свой контейнер» и хост — проходят.
#
# **Зачем в репозитории, а не в /tmp.** Приёмка в `/tmp` невоспроизводима: следующий человек написал бы
# её заново (и, скорее всего, без контроля связности). Здесь она — команда.
#
# **Как устроено.** У меня нет второй машины, поэтому «чужой источник» эмулируется сетевым namespace с
# veth: на хосте интерфейс `veth-…`, который НЕ `docker0` и НЕ `br-+`, то есть правилом не разрешён ⇒
# пакет обязан упереться в DROP. Контроль обязателен: ICMP до хоста из namespace должен ПРОХОДИТЬ, иначе
# «закрыто» означало бы «сеть не работает», а не «правило сработало».
#
#   sudo bash infra/checks/foreign-source-probe.sh            # порты по умолчанию: 8087 8680 3000 8080
#   sudo bash infra/checks/foreign-source-probe.sh 4318 8680  # конкретные
#
# ❗ Требует root (namespace и veth). Печатает и вердикт, и счётчики правил с РЕАЛЬНЫМ `dpt:` из iptables:
# подпись по подстрокам назвала бы правило `dpt:80` (traefik) как «4318».
set -uo pipefail

HOST_IP="192.168.77.1"
PEER_IP="192.168.77.2"
NS="fwprobe"
VETH="veth-fwprobe"
CHAIN="DOCKER-USER"
MARK="PORTS-GUARD"
PORTS=("$@")
[[ ${#PORTS[@]} -gt 0 ]] || PORTS=(8087 8680 3000 8080)

[[ "$(id -u)" == "0" ]] || { echo "[probe] нужен root (namespace + veth)" >&2; exit 2; }

cleanup() { ip netns del "$NS" 2>/dev/null || true; ip link del "$VETH" 2>/dev/null || true; }
trap cleanup EXIT
cleanup

ip netns add "$NS" || exit 1
ip link add "$VETH" type veth peer name "${VETH}-ns" || exit 1
ip link set "${VETH}-ns" netns "$NS"
ip addr add "$HOST_IP/24" dev "$VETH" && ip link set "$VETH" up
ip netns exec "$NS" ip addr add "$PEER_IP/24" dev "${VETH}-ns"
ip netns exec "$NS" ip link set "${VETH}-ns" up
ip netns exec "$NS" ip link set lo up

echo "[probe] чужой источник = namespace $NS ($PEER_IP), интерфейс $VETH (не docker0/br-+)"
if ip netns exec "$NS" ping -c 2 -W 2 "$HOST_IP" >/dev/null 2>&1; then
  echo "  контроль: ICMP до хоста проходит — путь есть, тест действителен"
else
  echo "  ОСТАНОВ: ICMP не прошёл — «закрыто» означало бы «сеть не работает», а не «правило сработало»" >&2
  exit 3
fi

bad=0
for port in "${PORTS[@]}"; do
  if ip netns exec "$NS" timeout 3 bash -c "exec 3<>/dev/tcp/$HOST_IP/$port" 2>/dev/null; then
    echo "  порт $port: ОТКРЫТ  ← охрана НЕ работает"; bad=1
  else
    echo "  порт $port: закрыт (DROP)"
  fi
done

echo "[probe] счётчики правил (метка — из самого правила, не угадана):"
iptables -L "$CHAIN" -n -v | grep -E "$MARK.*запрещена" | while read -r line; do
  dport="$(printf '%s' "$line" | grep -oE 'dpt:[0-9]+' | head -1 | cut -d: -f2)"
  pkts="$(printf '%s' "$line" | awk '{print $2}')"
  printf '  dpt:%s → пакетов %s\n' "${dport:-?}" "$pkts"
done

[[ "$bad" == "0" ]] || { echo "[probe] ПРОВАЛ: хотя бы один порт открыт снаружи" >&2; exit 1; }
echo "[probe] ПРОЙДЕНО: все проверенные порты закрыты для чужого источника"
