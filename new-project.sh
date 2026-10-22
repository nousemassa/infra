#!/usr/bin/env bash
# Новый проект из шаблона: разворачивает `templates/project/` в папку проекта, подставляет имя и порт и
# добавляет строку в РЕЕСТР (`compose-projects.tsv`) — после этого сторож, дрейф, ребут-чек и гейты видят
# проект сами (правило 6 контракта).
#
#   bash infra/new-project.sh <имя> <порт>     # имя: латиница, цифры, дефис; порт: 1024..65535
#
# Ничего не запускает: цель шага — «проект есть и гейты его видят». Дальше — чек-лист из `CONTRACT.md`.
set -euo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$INFRA/.." && pwd)"
TEMPLATE="$INFRA/templates/project"
REGISTRY="$INFRA/compose-projects.tsv"

NAME="${1:-}"; PORT="${2:-}"
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "[new-project] ОСТАНОВ: имя должно быть латиницей (строчные), цифрами и дефисом: получил «$NAME»" >&2; exit 2
fi
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  echo "[new-project] ОСТАНОВ: порт 1024..65535: получил «$PORT»" >&2; exit 2
fi
DEST="$WORKSPACE/$NAME"
[[ -e "$DEST" ]] && { echo "[new-project] ОСТАНОВ: $DEST уже существует" >&2; exit 2; }
if grep -q "	$NAME/" "$REGISTRY" 2>/dev/null; then
  echo "[new-project] ОСТАНОВ: проект «$NAME» уже есть в реестре $REGISTRY" >&2; exit 2
fi

#: Копируем шаблон КАК ЕСТЬ, затем подставляем плейсхолдеры. Подстановка — только для файлов, поэтому
#: имена каталогов тоже правим (пакет называется `agenta_<проект>`).
cp -a "$TEMPLATE" "$DEST"
mv "$DEST/__PROJECT___agent" "$DEST/${NAME}_agent"
while IFS= read -r -d '' file; do
  #: `__YEAR__` — в шаблоне `LICENSE`: год подставляем ТЕКУЩИЙ, иначе проект 2027-го унаследовал бы
  #: год шаблона (класс «молча неверно»).
  sed -i "s/__PROJECT__/$NAME/g; s/__PORT__/$PORT/g; s/__YEAR__/$(date +%Y)/g" "$file"
done < <(find "$DEST" -type f -print0)
#: Имена файлов тоже несут плейсхолдер — sed правит только СОДЕРЖИМОЕ, поэтому переименовываем руками.
mv "$DEST/compose.__PROJECT__.yaml" "$DEST/compose.$NAME.yaml"
mv "$DEST/__PROJECT__-up.sh" "$DEST/$NAME-up.sh"
chmod +x "$DEST/$NAME-up.sh"

printf '%s\t%s/compose.%s.yaml\n' "$NAME" "$NAME" "$NAME" >> "$REGISTRY"

# --- git-часть: репозиторий проекта, строка в МАНИФЕСТЕ и строка игнорирования в корне ---------------
MANIFEST="$WORKSPACE/repos.tsv"
ROOT_IGNORE="$WORKSPACE/.gitignore"

#: Манифест: папка, имя репозитория, ветка, url. Ветка — `master`, как у остальных; `url` ПУСТ
#: намеренно: внешний адрес заводит владелец, и скрипт говорит об этом прямо, а не делает вид, что
#: проект откуда-то склонирован.
printf '%s\t%s\tmaster\t\n' "$NAME" "$NAME" >> "$MANIFEST"

#: ❗ Корень обязан ИГНОРИРОВАТЬ папку проекта: папки проектов отслеживают их собственные
#: репозитории, и без этой строки новый проект висел бы в статусе корня неотслеживаемым — вечно
#: грязный воркспейс.
#: Ставим сразу после `infra/` (последней из объявленных папок), чтобы список читался одним куском.
awk -v name="$NAME" '{print} $0 == "infra/" && !done {print name "/"; done=1}' "$ROOT_IGNORE" > "$ROOT_IGNORE.tmp"
mv "$ROOT_IGNORE.tmp" "$ROOT_IGNORE"

#: Свой репозиторий проекта. Шаблон несёт `.gitignore`, поэтому первый коммит не забирает ни `.env`,
#: ни логи, ни артефакты сборки — это правило заведено в шаблоне именно ради этого коммита.
git -C "$DEST" init -b master -q
git -C "$DEST" add -A
git -C "$DEST" commit -q -m "Новый проект из шаблона: $NAME (порт $PORT)"

echo "[new-project] создан $DEST (порт $PORT)"
echo "[new-project] репозиторий проекта: $(git -C "$DEST" rev-list --count HEAD) коммит, ветка master"
echo "[new-project] строки добавлены: реестр $REGISTRY, манифест $MANIFEST, игнор корня $ROOT_IGNORE"
echo "[new-project] дальше — чек-лист из CONTRACT.md, минимум:"
echo "  docker compose -f $NAME/compose.$NAME.yaml config -q   # композ разбирается"
echo "  make -C infra check          # пути в юнитах сходятся с фактом"
echo "  и «Наблюдение»: сторож в infra/health/, юнит-пара, список включения, список ребут-чека"
echo "  проект обязан быть виден: манифест ⇄ папка ⇄ игнор корня"
echo "  изменить корень (repos.tsv, .gitignore) — в КОММИТ КОРНЯ; это не часть репозитория проекта"
#: ❗ Одинарные кавычки, а не двойные: в двойных обратные кавычки — это ПОДСТАНОВКА КОМАНДЫ, и
#: строка про `lint` выполнила бы системную команду `lint` (залив вывод её справкой).
echo '  НАЗВАНО (не молча): имена целей воркспейса (`lint`) перечислены ЯВНО, поэтому новый проект'
echo '    не линтуется, пока его не добавят в список — расширение области линтера решение владельца'
echo '  НАЗВАНО: внешнего url у проекта нет — remote заводит владелец'
