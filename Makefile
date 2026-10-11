.PHONY: up down logs ps shell-spark shell-postgres trino-cli reset run-reconcile

COMPOSE_ENV_FILE ?= env_secrets/stack.secrets
COMPOSE ?= docker compose --env-file $(COMPOSE_ENV_FILE)

## Sobe a stack base
up:
	$(COMPOSE) up -d
	@echo ""
	@echo "Aguardando serviços iniciarem..."
	@sleep 20
	@echo ""
	@echo "Stack disponível em:"
	@echo "  MinIO Console   → http://localhost:9001"
	@echo "  Spark UI        → http://localhost:8080"
	@echo "  Kafka UI        → http://localhost:8085"
	@echo "  Trino           → http://localhost:8090"

## Para tudo (mantém volumes)
down:
	$(COMPOSE) down

## Remove tudo incluindo volumes (cuidado!)
reset:
	$(COMPOSE) down -v
	@echo "Stack e volumes removidos."

## Status dos containers
ps:
	$(COMPOSE) ps

## Logs em tempo real
logs:
	$(COMPOSE) logs -f

## Shell no Spark master
shell-spark:
	docker exec -it spark-master bash

## Shell no PostgreSQL
shell-postgres:
	docker exec -it postgres sh -lc 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

## CLI do Trino
trino-cli:
	docker exec -it trino trino --catalog delta --schema default

## Rodar reconciliação manualmente
run-reconcile:
	@test -n "$(CONFIG)" || (echo "Informe CONFIG=/opt/delta-projects/<projeto>/reconciliation.yml" && exit 1)
	docker exec spark-master spark-submit \
	  --master spark://spark-master:7077 \
	  /opt/delta-stack/scripts/reconciliation.py \
	  --config $(CONFIG)
