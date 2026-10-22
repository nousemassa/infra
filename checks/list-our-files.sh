#!/usr/bin/env bash
# list-our-files.sh — перечислить НАШИ файлы: корень воркспейса и каждый репозиторий из манифеста.
#
# **Зачем отдельный помощник.** Проекты — отдельные репозитории, поэтому `git ls-files` по корню видит
# только корневые файлы. Оба потребителя такого списка (сканер секретов и сборщик публичного снапшота)
# ослепли бы МОЛЧА, оставаясь зелёными: сканер перестал бы видеть `.env` в проектах, а снапшот
# потерял бы проекты целиком. Один владелец вопроса «что считается нашими файлами» — здесь.
#
# Учитывается `.gitignore` КАЖДОГО репозитория (он у каждого свой): иначе `.env`, `.sessions/` и
# `*.egg-info/` вернулись бы в набор.
#
# Использование:
#   bash infra/checks/list-our-files.sh          # пути ОТ КОРНЯ воркспейса, по строке
#   bash infra/checks/list-our-files.sh -z       # то же, NUL-разделителем (имена с пробелами)
#   bash infra/checks/list-our-files.sh --repos  # только КАТАЛОГИ репозиториев (для проверки индексов)
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/workspace.sh"

mode="${1:-}"
roots=()
if [[ -d "$WORKSPACE/.git" ]]; then
  roots+=("$WORKSPACE")
fi
if [[ -f "$WORKSPACE/repos.tsv" ]]; then
  while IFS=$'\t' read -r folder rest; do
    [[ -z "$folder" || "$folder" == "#"* ]] && continue
    [[ -d "$WORKSPACE/$folder/.git" ]] && roots+=("$WORKSPACE/$folder")
  done < "$WORKSPACE/repos.tsv"
fi

if [[ "$mode" == "--repos" ]]; then
  printf '%s\n' "${roots[@]}"
  exit 0
fi

#: ❗ Разделитель НЕ через переменную: в bash NUL в строке не живёт (`separator=$'\0'` даёт ПУСТУЮ
#: строку), и NUL-режим молча склеил бы все пути в одну строку — снапшот собрал бы 0 файлов.
#: Проверка: NUL-режим обязан дать столько же записей, сколько обычный.
for repo in "${roots[@]}"; do
  if [[ "$repo" == "$WORKSPACE" ]]; then prefix=""; else prefix="$(basename "$repo")/"; fi
  while IFS= read -r -d '' rel; do
    if [[ "$mode" == "-z" ]]; then
      printf '%s\0' "$prefix$rel"
    else
      printf '%s\n' "$prefix$rel"
    fi
  done < <(git -C "$repo" ls-files --cached --others --exclude-standard -z 2>/dev/null || true)
done
