#!/usr/bin/env bash
# scripts/minio/purge-deleted-versions.sh
# Purge sob demanda: remove TODAS as versões de objetos cuja versão atual
# é um delete marker (VACUUM / DeleteObject). Objetos current não são tocados.
# Compatível com mc antigo (sem --purge-deleted).
#
# Dry-run (padrão):
#   MINIO_ENDPOINT=https://<minio-host>:9000 \
#     bash scripts/minio/purge-deleted-versions.sh bronze
#
# Aplicar:
#   APPLY=1 MINIO_ENDPOINT=https://<minio-host>:9000 \
#     bash scripts/minio/purge-deleted-versions.sh bronze silver gold
#
# HTTPS (VM2): exige config/minio/certs/public.crt (CA do mc).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SECRETS_DIR="${LAKEHOUSE_SECRETS_DIR:-$ROOT/.env_secrets}"
CERTS_DIR="${LAKEHOUSE_MINIO_CERTS_DIR:-$ROOT/config/minio/certs}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://127.0.0.1:9000}"
MC_IMAGE="${MC_IMAGE:-minio/mc}"
ALIAS_NAME="myminio"
APPLY="${APPLY:-0}"
LISTER="$ROOT/scripts/minio/list_delete_markers.py"

if [ "$#" -eq 0 ]; then
  set -- bronze silver gold
fi

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

mc_sh_stdin() {
  docker run -i --rm --network host \
    -e MINIO_ROOT_USER \
    -e MINIO_ROOT_PASSWORD \
    "${CERT_MOUNT[@]}" \
    --entrypoint /bin/sh \
    "${MC_IMAGE}" \
    -c "${MC_ALIAS_SETUP} && $*"
}

echo "endpoint=${MINIO_ENDPOINT} apply=${APPLY} buckets=$*"

for bucket in "$@"; do
  echo "=== ${bucket} ==="
  tmp="$(mktemp)"
  mc_sh "mc ls --recursive --versions --json ${ALIAS_NAME}/${bucket}" \
    | python3 "${LISTER}" "${ALIAS_NAME}/${bucket}" \
    > "${tmp}"

  count="$(grep -c . "${tmp}" || true)"
  echo "candidatos=${count}"

  if [ "${count}" -eq 0 ]; then
    rm -f "${tmp}"
    continue
  fi

  if [ "${APPLY}" != "1" ]; then
    echo "dry-run (primeiros 20):"
    head -n 20 "${tmp}"
    echo "para aplicar neste bucket: APPLY=1 ... ${bucket}"
    rm -f "${tmp}"
    continue
  fi

  echo "purging ${count} objetos deletados em ${bucket}"
  mc_sh_stdin "mc rm --stdin --versions --force" < "${tmp}"
  rm -f "${tmp}"
done
