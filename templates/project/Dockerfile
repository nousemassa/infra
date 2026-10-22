# Образ проекта `__PROJECT__`. Общий слой ставится КОЛЁСОМ из `wheels/`:
# порядок «core → колёсо → образы» обязателен, иначе образ соберётся со СТАРЫМ кодом молча.
FROM python:3.12-slim

WORKDIR /srv/__PROJECT__

COPY wheels /wheels-core
COPY pyproject.toml /srv/__PROJECT__/pyproject.toml
COPY __PROJECT___agent /srv/__PROJECT__/__PROJECT___agent

#: Версия общего слоя обязана совпадать с `pyproject.toml` шаблона: расхождение даёт образ
#: со старым кодом при «правильной» зависимости.
RUN pip install --no-cache-dir --find-links=/wheels-core agent-core==0.18.0 && pip install --no-cache-dir -e /srv/__PROJECT__

#: Порт ВНУТРИ контейнера; наружу публикуется 127.0.0.1:__PORT__ (см. композ).
EXPOSE 8000
CMD ["python", "-m", "__PROJECT___agent.main"]
