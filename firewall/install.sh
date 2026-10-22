#!/usr/bin/env bash
# Установка СИСТЕМНОГО юнита охраны опубликованных портов Docker.
#
#   sudo bash infra/firewall/install.sh          # разложить, включить, применить сейчас
#   sudo bash infra/firewall/install.sh --remove # выключить, убрать юнит, снять правила (полный откат)
#
# ❗ Это системный юнит (нужен root): он ставит правила iptables после старта docker. Юниты сторожей —
# пользовательские (`infra/systemd/`), и путать эти две установки нельзя.
# ❗ Скрипт снимает и старый юнит `agenta-otlp-guard.service`, если он остался от первой редакции правила
# (охранял только 4318): два набора правил на одни порты — источник необъяснимых «то пускает, то нет».
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="docker-ports-guard.service"
OLD="agenta-otlp-guard.service"
DEST="/etc/systemd/system"

[[ "$(id -u)" == "0" ]] || { echo "[install] ОСТАНОВ: нужен root" >&2; exit 2; }

if [[ "${1:-}" == "--remove" ]]; then
  for u in "$UNIT" "$OLD"; do systemctl disable --now "$u" 2>/dev/null || true; rm -f "$DEST/$u"; done
  systemctl daemon-reload
  bash "$SRC/docker-ports-guard.sh" remove
  echo "[install] юниты убраны, правила сняты"
  exit 0
fi

if [[ -f "$DEST/$OLD" ]]; then
  systemctl disable --now "$OLD" 2>/dev/null || true
  rm -f "$DEST/$OLD"
  echo "[install] прежний юнит $OLD снят (он охранял только порт 4318)"
fi

#: ❗ Раскладка с РЕНДЕРОМ: в юните стоит `__WORKSPACE__`, и копия без подстановки оставила бы в
#: `/etc/systemd/system` мёртвый `ExecStart`. Тот же приём, что у раскладки user-юнитов.
: "${AGENT_WORKSPACE:?AGENT_WORKSPACE не задан — путь воркспейса нужен для подстановки}"
sed "s|__WORKSPACE__|$AGENT_WORKSPACE|g" "$SRC/$UNIT" > "$DEST/$UNIT"
chmod 0644 "$DEST/$UNIT"
systemctl daemon-reload
systemctl enable --now "$UNIT"
systemctl --no-pager --lines=0 status "$UNIT" | sed 's/^/  /'
