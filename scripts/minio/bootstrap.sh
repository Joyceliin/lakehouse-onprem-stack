#!/usr/bin/env bash
# Reexecuta infra MinIO (compose minio-init). Sem criar usuarios.
#
#   bash scripts/minio/bootstrap.sh
#   ./scripts/minio/set-user.sh trino --write-secrets
#   ./scripts/minio/set-user.sh hive  --write-secrets
#   ./scripts/minio/set-user.sh svc_r5n1 --read silver/projeto_x
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/docker-compose.lakehouse-vm2.yml}"
cd "$ROOT"

docker compose -f "$COMPOSE_FILE" up -d minio
docker compose -f "$COMPOSE_FILE" run --rm --no-deps minio-init

echo "" >&2
echo "Infra OK. Contas:" >&2
echo "  ./scripts/minio/set-user.sh trino --write-secrets" >&2
echo "  ./scripts/minio/set-user.sh hive  --write-secrets" >&2
echo "  ./scripts/minio/set-user.sh <user> --read silver/projeto_x   # policy dinamica" >&2
