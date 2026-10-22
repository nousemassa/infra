#!/usr/bin/env bash
# Один владелец операции «наложить наши патчи на вендора Agenta» (шаг D17).
#
# Зачем отдельный скрипт-владелец. Патчи жили в двух несовместимых видах, и оба ломались МОЛЧА:
#   * проводка (compose с монтированиями) генерировалась ВНУТРЬ клона вендора, а `vendor/` в
#     `.gitignore` ⇒ свежий клон терял её и патчи переставали применяться, не сказав ни слова;
#   * сами патчи — ЦЕЛЫЕ файлы, которые затирают файл вендора целиком ⇒ при обновлении вендора
#     мы затирали ИХ правки в этих файлах (не «наше поверх», а «наш старый файл вместо нового»).
#
# Здесь одно место, которое:
#   1) берёт ЗАПИСАННУЮ базу из манифеста `infra/patches/patches.tsv` (база названа, а не подразумевается);
#   2) для `.py` НАКЛАДЫВАЕТ наше трёхсторонним слиянием: конфликт ⇒ ГРОМКИЙ отказ, а не тихая подмена;
#   3) для `.js` проверяет, что бандл в образе — ТОТ САМЫЙ (иначе патч устарел), и только потом кладёт наш;
#   4) собирает `infra/patches/applied/` — ровно то, что монтирует `infra/patches/compose.patches.yml`.
#
# Использование:
#   bash infra/vendor-bringup/apply-vendor-patches.sh              # собрать patches/applied/ (нужно ДО `up`)
#   bash infra/vendor-bringup/apply-vendor-patches.sh --check       # только проверить, ничего не писать
#   bash infra/vendor-bringup/apply-vendor-patches.sh --vendor DIR --out DIR   # проба в песочнице
#
# ❗ Любой отказ = ненулевой код И НИЧЕГО НЕ ЗАПИСАНО: результат собирается во временный каталог и
# переносится на место только когда ВСЕ патчи прошли (иначе в `applied/` осталась бы полу-правда).
#
# Честная граница: слияние не понимает СМЫСЛА — если вендор поменял ту же логику, будет конфликт,
# и решение принимает человек. Для бандлов `.js` настоящая «отвязка» невозможна без сборки фронтенда
# вендора из исходников; мы честно ограничиваемся обнаружением устаревания.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   #: корень воркспейса
VENDOR="$ROOT/vendor/agenta"
OUT="$ROOT/infra/patches/applied"
MANIFEST="$ROOT/infra/patches/patches.tsv"
PATCHES_DIR="$(dirname "$MANIFEST")"   #: наши файлы лежат РЯДОМ с манифестом, а не в корне воркспейса
CHECK=0

usage() {
  echo "использование: bash infra/vendor-bringup/apply-vendor-patches.sh [--check] [--vendor DIR] [--out DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)  CHECK=1; shift ;;
    --vendor) VENDOR="${2:?--vendor требует каталог}"; shift 2 ;;
    --out)    OUT="${2:?--out требует каталог}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[patches] ОСТАНОВ: неизвестный аргумент «$1»" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$MANIFEST" ]] || { echo "[patches] ОСТАНОВ: нет манифеста $MANIFEST" >&2; exit 2; }
[[ -d "$VENDOR"   ]] || { echo "[patches] ОСТАНОВ: нет клона вендора $VENDOR — сначала: bash infra/vendor-bringup/vendor-agenta.sh" >&2; exit 2; }

TMP="$(mktemp -d)"          # сюда собираем результат
SCRATCH="$(mktemp -d)"      # сюда — служебные файлы (базы), в applied/ они попасть не должны
trap 'rm -rf "$TMP" "$SCRATCH"' EXIT

# Версия вендора — НАЗВАТЬ всегда, а не подразумевать. Проверяем через `rev-parse --git-dir`, а не
# наличием каталога `.git`: в git-worktree `.git` — ФАЙЛ, и проверка на каталог молча решала бы,
# что это «не git-клон» (поймано пробой в песочнице).
if git -C "$VENDOR" rev-parse --git-dir >/dev/null 2>&1; then
  VERSION="$(git -C "$VENDOR" describe --tags --always 2>/dev/null || git -C "$VENDOR" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$VENDOR" status --porcelain | head -1)" ]]; then
    VERSION="$VERSION + незакоммиченные правки"
  fi
else
  VERSION="(не git-клон)"
fi
echo "[patches] вендор: $VENDOR @ $VERSION"

problems=0
REPORT=()

while IFS=$'\t' read -r kind our vendor_source target base image; do
  [[ -z "${kind:-}" || "$kind" == \#* ]] && continue
  src="$PATCHES_DIR/${our#patches/}"
  dst="$TMP/${our#patches/}"
  mkdir -p "$(dirname "$dst")"
  if [[ ! -f "$src" ]]; then
    REPORT+=("$our: ОТКАЗ — нашего файла нет"); problems=$((problems + 1)); continue
  fi

  case "$kind" in
    py)
      vpath="${vendor_source#clone:}"
      if ! git -C "$VENDOR" cat-file -e "$base:$vpath" 2>/dev/null; then
        REPORT+=("$our: ОТКАЗ — база $base не содержит $vpath (клон на другой версии? нужна база $base)")
        problems=$((problems + 1)); continue
      fi
      basefile="$SCRATCH/${our//\//_}.base"
      git -C "$VENDOR" show "$base:$vpath" > "$basefile"
      theirs="$VENDOR/$vpath"
      if [[ ! -f "$theirs" ]]; then
        REPORT+=("$our: ОТКАЗ — в клоне нет $vpath"); problems=$((problems + 1)); continue
      fi
      set +e
      git merge-file -p "$src" "$basefile" "$theirs" > "$dst"
      rc=$?
      set -e
      if [[ $rc -gt 0 ]]; then
        rm -f "$dst"
        REPORT+=("$our: ОТКАЗ — КОНФЛИКТ слияния ($rc мест), чужое изменило НАШ участок в $vpath — решает человек")
        problems=$((problems + 1)); continue
      fi
      # названное допущение: слияние опирается на КЛОН, а контейнер бежит на ОБРАЗЕ — сверить, что они не разошлись
      note=""
      if [[ -n "${image:-}" ]]; then
        set +e
        img_hash="$(docker run --rm --entrypoint sh "$image" -c "sha256sum '$target'" 2>/dev/null | awk 'NR==1{print $1}')"
        set -e
        clone_hash="$(sha256sum "$theirs" | awk '{print $1}')"
        if [[ "$img_hash" =~ ^[0-9a-f]{64}$ ]]; then
          if [[ "$img_hash" == "$clone_hash" ]]; then note="; образ ⇄ клон совпадают"
          else note="; ❗ РАСХОЖДЕНИЕ: образ ${img_hash:0:12} ≠ клон ${clone_hash:0:12} — слияние опирается на КЛОН, а контейнер бежит на ОБРАЗЕ"; fi
        else
          note="; образ не сверен (недоступен)"
        fi
      fi
      if cmp -s "$basefile" "$theirs"; then
        REPORT+=("$our: применён (вендор $vpath не менял)$note")
      else
        REPORT+=("$our: СЛИТ с чужими правками ($vpath изменён вендором)$note")
      fi
      ;;
    js)
      image="${vendor_source#image:}"
      want="${base#sha256:}"
      set +e
      got="$(docker run --rm --entrypoint sh "$image" -c "sha256sum '$target'" 2>&1)"
      rc=$?
      set -e
      got_hash="$(printf '%s\n' "$got" | awk 'NR==1{print $1}')"
      if [[ $rc -ne 0 || ! "$got_hash" =~ ^[0-9a-f]{64}$ ]]; then
        REPORT+=("$our: ОТКАЗ — не смог прочитать $target из образа $image (образ не локально?): $(printf '%s' "$got" | head -1)")
        problems=$((problems + 1)); continue
      fi
      if [[ "$got_hash" != "$want" ]]; then
        REPORT+=("$our: ОТКАЗ — бандл вендора пересобран (в образе ${got_hash:0:12}, ждали ${want:0:12}) — наш патч устарел, пересобрать из исходников вендора")
        problems=$((problems + 1)); continue
      fi
      cp -p "$src" "$dst"
      REPORT+=("$our: заменён (цель $target в $image — та самая)")
      ;;
    *)
      REPORT+=("$our: ОТКАЗ — неизвестный kind «$kind»"); problems=$((problems + 1)); continue
      ;;
  esac
done < "$MANIFEST"

echo
for line in "${REPORT[@]}"; do echo "  $line"; done
echo

if [[ $problems -gt 0 ]]; then
  echo "[patches] ЕСТЬ ОТКАЗЫ: $problems — НИЧЕГО НЕ ЗАПИСАНО" >&2
  exit 1
fi

if [[ $CHECK -eq 1 ]]; then
  echo "[patches] проверка пройдена: ${#REPORT[@]} патчей на версии вендора $VERSION (--check: ничего не писал)"
  exit 0
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$TMP/." "$OUT/"
echo "[patches] собрано: ${#REPORT[@]} файлов в $OUT (вендор $VERSION)"
echo "[patches] монтируются из patches/applied/ — см. patches/compose.patches.yml"
