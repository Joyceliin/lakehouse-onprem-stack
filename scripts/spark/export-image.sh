#!/usr/bin/env bash
# Gera delta-stack/spark:4.1.2 localmente e exporta para .tar (deploy offline na VM1).
# Uso (Linux / WSL com bash instalado):
#   bash scripts/spark/export-image.sh
# Windows (Docker Desktop): .\scripts\spark\export-image.ps1
set -euo pipefail

IMAGE="delta-stack/spark:4.1.2"
BASE_IMAGE="apache/spark:4.1.2-scala2.13-java17-python3-ubuntu"
OUT_TAR="${1:-delta-stack-spark-4.1.2.tar}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> Build ${IMAGE} (context: config/spark)"
export DOCKER_BUILDKIT=1
docker build \
  -t "${IMAGE}" \
  -f "${ROOT}/config/spark/Dockerfile" \
  --build-arg "SPARK_BASE_IMAGE=${BASE_IMAGE}" \
  "${ROOT}/config/spark"

echo "==> Export ${OUT_TAR}"
docker save -o "${OUT_TAR}" "${IMAGE}"

ls -lh "${OUT_TAR}"
docker image inspect "${IMAGE}" --format 'ID={{.Id}} Criada={{.Created}} Tamanho={{.Size}} bytes'

echo ""
echo "Copie para a VM1, ex.:"
echo "  scp ${OUT_TAR} <user>@<VM1>:<destino>/"
echo "Na VM1:"
echo "  bash scripts/spark/load-image.sh ${OUT_TAR}"
echo "  docker compose -f docker-compose.spark-vm1.yml --env-file .env up -d --no-build"
