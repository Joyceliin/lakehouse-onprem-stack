#!/usr/bin/env sh
# Bootstrap MinIO — SOMENTE infraestrutura + policies INTERNAS (JSON cravado).
# Policies no repo: trino-read.json, hive-meta.json
#
# Usuarios novos: scripts/minio/set-user.sh <key> --read/--write  (policy dinamica)
# SAs internos:   scripts/minio/set-user.sh trino|hive --write-secrets|--from-secrets
set -eu

read_secret() {
  tr -d '\r\n' < "$1"
}

POLICIES="${MINIO_POLICIES_DIR:-/policies}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-https://minio:9000}"

ROOT_USER="$(read_secret /run/secrets/minio_root_user)"
ROOT_PASSWORD="$(read_secret /run/secrets/minio_root_password)"

if [ -r /certs/public.crt ]; then
  mkdir -p /root/.mc/certs/CAs
  cp /certs/public.crt /root/.mc/certs/CAs/minio.crt
fi

mc alias set local "${MINIO_ENDPOINT}" "${ROOT_USER}" "${ROOT_PASSWORD}"

for bucket in bronze silver gold landing markers; do
  mc mb --ignore-existing "local/${bucket}"
done

for bucket in bronze silver gold landing markers; do
  mc version enable "local/${bucket}" || true
done

# Versões antigas expiram sozinhas: 10 dias nas camadas medalhão, 30 nos
# buckets de apoio.
set_lifecycle() {
  mc ilm rule rm --all --force "local/$1" >/dev/null 2>&1 || true
  mc ilm rule add "local/$1" \
    --noncurrent-expire-days "$2" \
    --expire-delete-marker || true
}

NONCURRENT_DAYS="${MINIO_LIFECYCLE_NONCURRENT_DAYS:-10}"
for bucket in bronze silver gold; do
  set_lifecycle "$bucket" "$NONCURRENT_DAYS"
done

SUPPORT_NONCURRENT_DAYS="${MINIO_LIFECYCLE_SUPPORT_NONCURRENT_DAYS:-30}"
for bucket in landing markers; do
  set_lifecycle "$bucket" "$SUPPORT_NONCURRENT_DAYS"
done

# Só policies internas da stack (não criar policies de usuario aqui)
mc admin policy create local policy-trino-read "${POLICIES}/trino-read.json" || true
mc admin policy create local policy-hive-meta "${POLICIES}/hive-meta.json" || true

echo "minio-init: infra + policies internas (trino/hive) OK."
echo "minio-init: SAs → set-user.sh trino|hive --write-secrets"
echo "minio-init: novos → set-user.sh <user> --read bucket[/prefix] ..."
