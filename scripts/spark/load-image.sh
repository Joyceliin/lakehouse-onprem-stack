#!/usr/bin/env bash
# Carrega imagem Spark exportada via docker save (VM1 sem build).
# Uso:
#   bash scripts/spark/load-image.sh delta-stack-spark-4.1.2.tar
set -euo pipefail

TAR="${1:?informe o .tar: bash scripts/spark/load-image.sh delta-stack-spark-4.1.2.tar}"

if [ ! -f "${TAR}" ]; then
  echo "Arquivo não encontrado: ${TAR}" >&2
  exit 1
fi

echo "==> docker load -i ${TAR}"
docker load -i "${TAR}"

echo "==> Imagens delta-stack/spark"
docker images "delta-stack/spark"

echo ""
echo "Subir sem rebuild:"
echo "  docker compose -f docker-compose.spark-vm1.yml --env-file .env up -d --no-build"
