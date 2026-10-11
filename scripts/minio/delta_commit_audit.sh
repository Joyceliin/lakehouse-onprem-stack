#!/usr/bin/env bash
# scripts/minio/delta_commit_audit.sh
# Audita os ultimos commits de uma tabela Delta no MinIO: qual operacao o job
# executa, em que modo, quantos arquivos cria e descarta a cada rodada.
# Somente leitura.
#
# Uso:
#   MINIO_ENDPOINT=https://<minio-host>:9000 \
#     bash scripts/minio/delta_commit_audit.sh bronze/projeto_b/tb_amostra 20
#
# HTTPS (VM2): exige config/minio/certs/public.crt (CA do mc).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS_DIR="${LAKEHOUSE_SECRETS_DIR:-$ROOT/.env_secrets}"
CERTS_DIR="${LAKEHOUSE_MINIO_CERTS_DIR:-$ROOT/config/minio/certs}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://127.0.0.1:9000}"
MC_IMAGE="${MC_IMAGE:-minio/mc}"
ALIAS_NAME="myminio"
SUMMARIZER="$ROOT/scripts/minio/summarize_commits.py"

TABLE="${1:?informe o caminho da tabela, ex: bronze/projeto_b/tb_amostra}"
LIMIT="${2:-20}"

read_secret() {
  local path="$1"
  if [ ! -r "$path" ]; then
    echo "Secret ausente ou ilegivel: ${path}" >&2
    exit 1
  fi
  tr -d '\r\n' < "$path"
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 e obrigatorio no host (a imagem mc nao tem awk/sed)." >&2
  exit 1
fi

CERT_MOUNT=()
MC_ALIAS_SETUP="mc alias set ${ALIAS_NAME} ${MINIO_ENDPOINT} \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null"
case "${MINIO_ENDPOINT}" in
  https://*)
    if [ ! -r "${CERTS_DIR}/public.crt" ]; then
      echo "HTTPS exige CA: ${CERTS_DIR}/public.crt (rode scripts/minio/gen-tls-certs.sh)." >&2
      exit 1
    fi
    CERT_MOUNT=(-v "${CERTS_DIR}/public.crt:/certs/public.crt:ro")
    MC_ALIAS_SETUP="mkdir -p /root/.mc/certs/CAs && cp /certs/public.crt /root/.mc/certs/CAs/minio.crt && ${MC_ALIAS_SETUP}"
    ;;
esac

export MINIO_ROOT_USER
export MINIO_ROOT_PASSWORD
MINIO_ROOT_USER="$(read_secret "${SECRETS_DIR}/minio_root_user")"
MINIO_ROOT_PASSWORD="$(read_secret "${SECRETS_DIR}/minio_root_password")"

mc_sh() {
  docker run --rm --network host \
    -e MINIO_ROOT_USER \
    -e MINIO_ROOT_PASSWORD \
    "${CERT_MOUNT[@]}" \
    --entrypoint /bin/sh \
    "${MC_IMAGE}" \
    -c "${MC_ALIAS_SETUP} && $*"
}

LOG_PATH="${ALIAS_NAME}/${TABLE}/_delta_log"

# Ultimos N commits .json (a imagem mc nao tem grep; filtragem fica no host).
versions="$(mc_sh "mc ls ${LOG_PATH}/" \
  | python3 -c '
import sys
names = [line.split()[-1] for line in sys.stdin if line.strip()]
commits = sorted(n for n in names if n.endswith(".json") and n[0].isdigit())
print(" ".join(commits[-int(sys.argv[1]):]))
' "${LIMIT}")"

if [ -z "${versions}" ]; then
  echo "Nenhum commit .json encontrado em ${TABLE}/_delta_log" >&2
  exit 1
fi

echo "tabela=${TABLE} commits=${LIMIT}"
mc_sh "for v in ${versions}; do echo \"---COMMIT \$v---\"; mc cat ${LOG_PATH}/\$v; done" \
  | python3 "${SUMMARIZER}"
