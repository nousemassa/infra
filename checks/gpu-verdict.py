#!/usr/bin/env python3
"""GPU-процессы до/после перезагрузки: что изменилось у НАС и что просто чужое.

**Зачем отдельным файлом.** Считать ЧИСЛО процессов на GPU нельзя: пропажа чужого процесса
(**Google Chrome**, `on_device_model`, 2.9 ГиБ VRAM) и потеря НАШЕЙ службы выглядели бы одинаково, и
настоящая потеря тонула бы в шуме. Поэтому сравнение идёт по именам процессов, раздельно для своих и
чужих.

**Что считается.** Наши — по имени процесса (они стабильны: `llama-server` для инференса и
`jev-score-v2` для решателя). Пропажа НАШЕГО процесса — отказ (это потеря службы). Изменение ЧУЖИХ —
пояснение: о нём сообщаем, но вердикт не красим.

**Как проверяется без перезагрузки.** `--self-test` прогоняет ровно ту же функцию `classify()` на
подготовленных парах, поэтому «проверка краснеет на нашей потере» доказуемо без перезагрузки.

    python3 infra/checks/gpu-verdict.py before.json after.json   # PROBLEM:/NOTE: построчно, rc=1 при отказе
    python3 infra/checks/gpu-verdict.py --self-test              # доказательство, что проверка умеет краснеть
"""
from __future__ import annotations

import json
import sys

#: Наши GPU-процессы — по имени. Список закрытый: он про НАШИ службы, а не про всё, что живёт на карте.
OUR_PROCESSES = ("llama-server", "jev-score-v2")


def _names(entries: list[str]) -> list[str]:
    """Имена процесса из строк вида `/app/bin/llama-server, 306 MiB`."""
    return [entry.split(",", 1)[0].strip() for entry in entries]


def _is_ours(name: str) -> bool:
    return any(marker in name for marker in OUR_PROCESSES)


def classify(before: list[str], after: list[str]) -> tuple[list[str], list[str]]:
    """(отказы, пояснения). Отказ — только потеря НАШЕГО процесса; чужое идёт в пояснения."""
    was_ours = sorted({name for name in _names(before) if _is_ours(name)})
    now_ours = sorted({name for name in _names(after) if _is_ours(name)})
    problems: list[str] = []
    notes: list[str] = []
    for name in was_ours:
        if name not in now_ours:
            problems.append(f"наш GPU-процесс {name} не поднялся после перезагрузки")

    was_foreign = sorted({name for name in _names(before) if not _is_ours(name)})
    now_foreign = sorted({name for name in _names(after) if not _is_ours(name)})
    if was_foreign != now_foreign:
        gone = [name for name in was_foreign if name not in now_foreign]
        came = [name for name in now_foreign if name not in was_foreign]
        parts = []
        if gone:
            parts.append("ушло: " + "; ".join(gone))
        if came:
            parts.append("появилось: " + "; ".join(came))
        notes.append("на GPU изменились ЧУЖИЕ процессы (" + ", ".join(parts) +
                     ") — к нашим службам отношения не имеет")
    return problems, notes


def _self_test() -> int:
    """Доказательство, что проверка может покраснеть — и что чужое её не красит."""
    ours_before = ["/app/bin/llama-server, 306 MiB", "/app/_build/build/jev-score-v2, 1672 MiB"]
    chrome = ["/opt/google/chrome/chrome --type=utility, 2959 MiB"]
    cases = [
        ("наша потеря → ОТКАЗ", ours_before + chrome, ours_before[:1], True),
        ("чужое ушло → только пояснение", ours_before + chrome, ours_before, False),
        ("ничего не менялось → тишина", ours_before, ours_before, False),
    ]
    bad = 0
    for title, before, after, expect_problem in cases:
        problems, notes = classify(before, after)
        ok = bool(problems) == expect_problem
        print(f"  [{'ok' if ok else 'ПРОВАЛ'}] {title}: отказов {len(problems)}, пояснений {len(notes)}")
        bad += 0 if ok else 1
    print("[gpu-verdict] самопроверка: " + ("ПРОЙДЕНА" if bad == 0 else f"ПРОВАЛЕНА ({bad})"))
    return 0 if bad == 0 else 1


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    if len(argv) != 3:
        print("использование: gpu-verdict.py <снимок-до.json> <снимок-после.json> | --self-test", file=sys.stderr)
        return 2
    before = json.load(open(argv[1])).get("vram") or []
    after = json.load(open(argv[2])).get("vram") or []
    problems, notes = classify(before, after)
    for problem in problems:
        print(f"PROBLEM: {problem}")
    for note in notes:
        print(f"NOTE: {note}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
