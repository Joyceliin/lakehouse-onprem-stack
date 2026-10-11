#!/usr/bin/env bash
# Gera certificado TLS para o MinIO + truststore JKS (Hive/Trino).
# Senha do JKS e o próprio .jks ficam em .env_secrets — NÃO no .env.
#
# Uso:
#   LAKEHOUSE_PRIVATE_BIND_ADDRESS=10.x.x.x bash scripts/minio/gen-tls-certs.sh
#
# Saída:
#   config/minio/certs/private.key
#   config/minio/certs/public.crt
#   .env_secrets/minio_truststore.jks
#   .env_secrets/minio_truststore_password
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${LAKEHOUSE_MINIO_CERTS_DIR:-$ROOT/config/minio/certs}"
SECRETS_DIR="${LAKEHOUSE_SECRETS_DIR:-$ROOT/.env_secrets}"
TRUSTSTORE_FILE="${MINIO_TRUSTSTORE_FILE:-$SECRETS_DIR/minio_truststore.jks}"
TRUSTSTORE_PASS_FILE="${MINIO_TRUSTSTORE_PASSWORD_FILE:-$SECRETS_DIR/minio_truststore_password}"
DAYS="${MINIO_TLS_DAYS:-825}"
# Hostname(s) da URL web (vírgula). Ex.: minio.lakehouse.local ou storage.example.org
# Incluídos no SAN do certificado — necessário se o browser/API usa FQDN.
MINIO_TLS_DNS="${MINIO_TLS_DNS:-}"
CONTAINER_IP="${MINIO_CONTAINER_IP:-10.10.10.10}"
HOST_IP="${LAKEHOUSE_PRIVATE_BIND_ADDRESS:-}"

# CN = primeiro DNS web, senão "minio"
if [[ -n "$MINIO_TLS_DNS" ]]; then
  CN="${MINIO_TLS_CN:-${MINIO_TLS_DNS%%,*}}"
else
  CN="${MINIO_TLS_CN:-minio}"
fi

mkdir -p "$OUT" "$SECRETS_DIR"
chmod 700 "$OUT" "$SECRETS_DIR"

generate_pass() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '/+=\n' | head -c 32
  elif [[ -r /dev/urandom ]]; then
    head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32
  else
    echo "Sem openssl//dev/urandom." >&2
    exit 1
  fi
}

# Senha do JKS: reutiliza secret existente ou gera (nunca .env)
if [[ -r "$TRUSTSTORE_PASS_FILE" ]]; then
  TRUSTSTORE_PASS="$(tr -d '\r\n' < "$TRUSTSTORE_PASS_FILE")"
  [[ -n "$TRUSTSTORE_PASS" ]] || { echo "Arquivo de senha vazio: $TRUSTSTORE_PASS_FILE" >&2; exit 1; }
  echo "Usando senha existente em $TRUSTSTORE_PASS_FILE" >&2
else
  TRUSTSTORE_PASS="$(generate_pass)"
  umask 077
  printf '%s\n' "$TRUSTSTORE_PASS" > "$TRUSTSTORE_PASS_FILE"
  chmod 600 "$TRUSTSTORE_PASS_FILE"
  echo "Senha do truststore gravada em $TRUSTSTORE_PASS_FILE (600)" >&2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; unset TRUSTSTORE_PASS' EXIT

SAN="DNS:minio,DNS:localhost,IP:127.0.0.1,IP:${CONTAINER_IP}"
if [[ -n "$HOST_IP" ]]; then
  SAN="${SAN},IP:${HOST_IP}"
fi
if [[ -n "$MINIO_TLS_DNS" ]]; then
  IFS=',' read -r -a _dns_list <<< "$MINIO_TLS_DNS"
  for _d in "${_dns_list[@]}"; do
    _d="$(printf '%s' "$_d" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$_d" ]] || continue
    SAN="${SAN},DNS:${_d}"
  done
fi

cat > "$TMP/openssl.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${CN}
O = Lakehouse
OU = MinIO

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${SAN}
EOF

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$OUT/private.key" \
  -out "$OUT/public.crt" \
  -days "$DAYS" \
  -config "$TMP/openssl.cnf"

chmod 600 "$OUT/private.key"
chmod 644 "$OUT/public.crt"

rm -f "$TRUSTSTORE_FILE"
keytool -importcert -noprompt \
  -alias minio \
  -file "$OUT/public.crt" \
  -keystore "$TRUSTSTORE_FILE" \
  -storepass "$TRUSTSTORE_PASS" \
  -storetype JKS

chmod 600 "$TRUSTSTORE_FILE"
chmod 600 "$TRUSTSTORE_PASS_FILE" 2>/dev/null || true

# Trino no container roda como UID 1000 — sem world-readable (não usar 644).
TRINO_FS_UID="${TRINO_FS_UID:-1000}"
TRINO_FS_GID="${TRINO_FS_GID:-1000}"
if chown "$TRINO_FS_UID:$TRINO_FS_GID" "$TRUSTSTORE_FILE" "$TRUSTSTORE_PASS_FILE" 2>/dev/null; then
  echo "Dono truststore → ${TRINO_FS_UID}:${TRINO_FS_GID} (user trino no container), modo 600" >&2
else
  echo "AVISO: nao foi possivel chown ${TRINO_FS_UID}:${TRINO_FS_GID}. Ajuste manual:" >&2
  echo "  chown ${TRINO_FS_UID}:${TRINO_FS_GID} $TRUSTSTORE_FILE $TRUSTSTORE_PASS_FILE" >&2
  echo "  chmod 600 $TRUSTSTORE_FILE $TRUSTSTORE_PASS_FILE" >&2
fi

echo "Gerado:"
echo "  $OUT/private.key"
echo "  $OUT/public.crt     — SAN: $SAN"
echo "  $TRUSTSTORE_FILE"
echo "  $TRUSTSTORE_PASS_FILE"
echo ""
echo "Nao coloque a senha do truststore no .env."
echo "Proximos: bootstrap + set-user.sh trino|hive + up hive/trino"
