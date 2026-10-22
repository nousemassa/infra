# Проект `__PROJECT__`. Свой Makefile — чтобы проект поднимался и проверялся БЕЗ воркспейса.
# Логика живёт в лончере, цели её не дублируют.
.PHONY: up status stop restart check

up:
	bash __PROJECT__-up.sh up

status:
	bash __PROJECT__-up.sh status

stop:
	bash __PROJECT__-up.sh stop

restart: stop up

# Офлайн-проверка: композ разбирается настоящим парсером, имя проекта не менялось (иначе ПУСТЫЕ тома).
check:
	@docker compose -f compose.__PROJECT__.yaml config -q \
	  && test "$$(docker compose -f compose.__PROJECT__.yaml config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')" = "__PROJECT__" \
	  && echo "[__PROJECT__] композ разбирается, имя проекта — __PROJECT__ (тома на месте) ✓"
