#!/usr/bin/env bash
# Provisiona usuário MinIO.
#
# Como funcionam as policies (resumo):
#   MinIO IAM: policy nomeada → Statement Allow/Deny (Action + Resource).
#   User recebe uma (ou mais) policies anexadas.
#
# Dois modos neste script:
#
# 1) INTERNOS — JSON cravado em config/minio/policies/ (só stack):
#      trino → policy-trino-read (trino-read.json)
#      hive  → policy-hive-meta  (hive-meta.json)
#    ./scripts/minio/set-user.sh trino --write-secrets
#    ./scripts/minio/set-user.sh hive  --from-secrets
#
# 2) NOVOS USUÁRIOS — acesso por flags; policy gerada na hora (NÃO usa JSON do repo):
#    ./scripts/minio/set-user.sh <access_key> --read <specs> [--write <specs>]
#    Spec = bucket  ou  bucket/prefix  (lista separada por vírgula)
#
#    ./scripts/minio/set-user.sh svc_r5n1 --read silver/projeto_x
#    ./scripts/minio/set-user.sh usr_b9q2 --read silver/vendas,gold/vendas
#    ./scripts/minio/set-user.sh svc_z6c4 --read bronze --write silver \
#        --write-secrets --secrets-name svc_z6c4
#
# Bootstrap (init) só registra policies internas. Contas = sempre este script.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ROLE_OR_KEY=""
PROMPT_MODE=0
WRITE_SECRETS=0
FROM_SECRETS=0
READ_SPECS=""
WRITE_SPECS=""
SECRETS_NAME=""

usage() {
  cat >&2 <<'EOF'
Uso:
  Internos (JSON fixo):
    set-user.sh trino|hive --write-secrets|--from-secrets [--prompt]

  Novos (policy dinâmica):
    set-user.sh <access_key> --read bucket[/prefix],... [--write ...] [--prompt]
    set-user.sh <access_key> --read ... --write-secrets --secrets-name <nome>

  Exemplos:
    set-user.sh svc_r5n1 --read silver/projeto_x
    set-user.sh usr_b9q2 --read silver/vendas,gold
    set-user.sh trino --write-secrets
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt|-p) PROMPT_MODE=1; shift ;;
    --write-secrets) WRITE_SECRETS=1; shift ;;
    --from-secrets) FROM_SECRETS=1; shift ;;
    --read) READ_SPECS="${2:?}"; shift 2 ;;
    --write) WRITE_SPECS="${2:?}"; shift 2 ;;
    --secrets-name) SECRETS_NAME="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Opcao desconhecida: $1" >&2
      usage
      exit 1
      ;;
    *)
      [[ -z "$ROLE_OR_KEY" ]] || { echo "Arg extra: $1" >&2; usage; exit 1; }
      ROLE_OR_KEY="$1"
      shift
      ;;
  esac
done

[[ -n "$ROLE_OR_KEY" ]] || { usage; exit 1; }
[[ "$WRITE_SECRETS" -eq 1 && "$FROM_SECRETS" -eq 1 ]] && {
  echo "Use só --write-secrets OU --from-secrets." >&2
  exit 1
}

SECRETS_DIR="${LAKEHOUSE_SECRETS_DIR:-$ROOT/.env_secrets}"
CERTS_DIR="${LAKEHOUSE_MINIO_CERTS_DIR:-$ROOT/config/minio/certs}"
POLICIES_DIR="${MINIO_POLICIES_DIR:-$ROOT/config/minio/policies}"
ENDPOINT="${MINIO_ENDPOINT:-https://minio:9000}"

MODE=""
ACCESS_KEY=""
POLICY_NAME=""
POLICY_JSON=""
ACCESS_FILE=""
SECRET_FILE=""
SECRET_KEY=""
SHOW_ONCE=0
TMP_POLICY=""

cleanup() { [[ -n "${TMP_POLICY:-}" && -f "$TMP_POLICY" ]] && rm -f "$TMP_POLICY"; }
trap cleanup EXIT

case "$ROLE_OR_KEY" in
  trino)
    MODE="internal"
    POLICY_NAME="policy-trino-read"
    POLICY_JSON="trino-read.json"
    ACCESS_FILE="$SECRETS_DIR/minio_trino_access_key"
    SECRET_FILE="$SECRETS_DIR/minio_trino_secret_key"
    ;;
  hive)
    MODE="internal"
    POLICY_NAME="policy-hive-meta"
    POLICY_JSON="hive-meta.json"
    ACCESS_FILE="$SECRETS_DIR/minio_hive_access_key"
    SECRET_FILE="$SECRETS_DIR/minio_hive_secret_key"
    ;;
  *)
    MODE="dynamic"
    ACCESS_KEY="$ROLE_OR_KEY"
    POLICY_NAME="policy-user-$(printf '%s' "$ACCESS_KEY" | tr -c 'A-Za-z0-9_-' '_')"
    [[ -n "$READ_SPECS" || -n "$WRITE_SPECS" ]] || {
      echo "Usuario novo exige --read e/ou --write." >&2
      exit 1
    }
    if [[ -n "$SECRETS_NAME" ]]; then
      ACCESS_FILE="$SECRETS_DIR/minio_${SECRETS_NAME}_access_key"
      SECRET_FILE="$SECRETS_DIR/minio_${SECRETS_NAME}_secret_key"
    fi
    ;;
esac

if [[ "$MODE" == "internal" && "$WRITE_SECRETS" -eq 0 && "$FROM_SECRETS" -eq 0 ]]; then
  echo "Interno '${ROLE_OR_KEY}': use --write-secrets ou --from-secrets." >&2
  exit 1
fi
if [[ "$MODE" == "dynamic" && "$FROM_SECRETS" -eq 1 && -z "$SECRETS_NAME" ]]; then
  echo "--from-secrets dinamico exige --secrets-name." >&2
  exit 1
fi
if [[ "$MODE" == "dynamic" && "$WRITE_SECRETS" -eq 1 && -z "$SECRETS_NAME" ]]; then
  echo "--write-secrets dinamico exige --secrets-name." >&2
  exit 1
fi

read_secret_file() {
  [[ -r "$1" ]] || { echo "Secret ausente: $1" >&2; exit 1; }
  tr -d '\r\n' < "$1"
}

generate_token() {
  local n="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -d '/+=\n' | head -c "$n"
  elif [[ -r /dev/urandom ]]; then
    head -c 64 /dev/urandom | base64 | tr -d '/+=\n' | head -c "$n"
  else
    echo "Sem openssl." >&2
    exit 1
  fi
}

read_prompt() {
  local label="$1" p1 p2
  [[ -t 0 ]] || { echo "Precisa de TTY." >&2; exit 1; }
  read -r -s -p "${label}: " p1; echo >&2
  read -r -s -p "Confirme: " p2; echo >&2
  [[ -n "$p1" && "$p1" == "$p2" && ${#p1} -ge 16 ]] || {
    echo "Valor invalido." >&2
    exit 1
  }
  printf '%s' "$p1"
}

write_secret_file() {
  mkdir -p "$(dirname "$1")"
  chmod 700 "$(dirname "$1")" 2>/dev/null || true
  umask 077
  printf '%s\n' "$2" > "$1"
  chmod 600 "$1"
}

# --- credenciais ---
if [[ "$FROM_SECRETS" -eq 1 ]]; then
  ACCESS_KEY="$(read_secret_file "$ACCESS_FILE")"
  SECRET_KEY="$(read_secret_file "$SECRET_FILE")"
elif [[ "$WRITE_SECRETS" -eq 1 ]]; then
  if [[ "$MODE" == "dynamic" ]]; then
    ACCESS_KEY="$ROLE_OR_KEY"
  fi
  if [[ "$PROMPT_MODE" -eq 1 ]]; then
    if [[ "$MODE" == "internal" ]]; then
      ACCESS_KEY="$(read_prompt "Access key (${ROLE_OR_KEY})")"
    fi
    SECRET_KEY="$(read_prompt "Secret key")"
  else
    if [[ "$MODE" == "internal" ]]; then
      ACCESS_KEY="$(generate_token 20)"
    fi
    SECRET_KEY="$(generate_token 40)"
    SHOW_ONCE=1
  fi
  write_secret_file "$ACCESS_FILE" "$ACCESS_KEY"
  write_secret_file "$SECRET_FILE" "$SECRET_KEY"
  echo "Gravado: $ACCESS_FILE" >&2
  echo "Gravado: $SECRET_FILE" >&2
else
  # dinamico sem persistir secret (humano / ad-hoc)
  ACCESS_KEY="$ROLE_OR_KEY"
  if [[ "$PROMPT_MODE" -eq 1 ]]; then
    SECRET_KEY="$(read_prompt "Secret key (${ACCESS_KEY})")"
  else
    SECRET_KEY="$(generate_token 40)"
    SHOW_ONCE=1
  fi
fi

[[ -n "$ACCESS_KEY" && -n "$SECRET_KEY" ]] || {
  echo "access/secret vazios — confira os arquivos em .env_secrets (tamanho com: wc -c ...)." >&2
  exit 1
}
# --from-secrets: aceita keys já existentes (qualquer comprimento > 0).
# Gerados por este script: exige secret com entropia mínima.
if [[ "$FROM_SECRETS" -eq 0 && ${#SECRET_KEY} -lt 16 ]]; then
  echo "Secret gerada curta demais (${#SECRET_KEY})." >&2
  exit 1
fi
if [[ ${#ACCESS_KEY} -lt 3 ]]; then
  echo "Access key curta demais (${#ACCESS_KEY})." >&2
  exit 1
fi

build_dynamic_policy() {
  TMP_POLICY="$(mktemp)"
  local stmts="" sep="" spec bucket prefix

  add_read() {
    spec="$1"
    bucket="${spec%%/*}"
    if [[ "$spec" == */* ]]; then
      prefix="${spec#*/}"
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":[\"arn:aws:s3:::${bucket}/${prefix}/*\"]}"
      sep=","
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${bucket}\"],\"Condition\":{\"StringLike\":{\"s3:prefix\":[\"${prefix}/*\",\"${prefix}\"]}}}"
    else
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\"],\"Resource\":[\"arn:aws:s3:::${bucket}/*\"]}"
      sep=","
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${bucket}\"]}"
    fi
    sep=","
  }

  add_write() {
    spec="$1"
    bucket="${spec%%/*}"
    if [[ "$spec" == */* ]]; then
      prefix="${spec#*/}"
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:AbortMultipartUpload\"],\"Resource\":[\"arn:aws:s3:::${bucket}/${prefix}/*\"]}"
      sep=","
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${bucket}\"],\"Condition\":{\"StringLike\":{\"s3:prefix\":[\"${prefix}/*\",\"${prefix}\"]}}}"
    else
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:AbortMultipartUpload\"],\"Resource\":[\"arn:aws:s3:::${bucket}/*\"]}"
      sep=","
      stmts+="${sep}{\"Effect\":\"Allow\",\"Action\":[\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${bucket}\"]}"
    fi
    sep=","
  }

  local IFS=','
  if [[ -n "$READ_SPECS" ]]; then
    for spec in $READ_SPECS; do
      spec="$(printf '%s' "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$spec" ]] && add_read "$spec"
    done
  fi
  if [[ -n "$WRITE_SPECS" ]]; then
    for spec in $WRITE_SPECS; do
      spec="$(printf '%s' "$spec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -n "$spec" ]] && add_write "$spec"
    done
  fi
  [[ -n "$stmts" ]] || { echo "Policy vazia." >&2; exit 1; }
  printf '{"Version":"2012-10-17","Statement":[%s]}\n' "$stmts" > "$TMP_POLICY"
}

ROOT_USER="$(read_secret_file "$SECRETS_DIR/minio_root_user")"
ROOT_PASSWORD="$(read_secret_file "$SECRETS_DIR/minio_root_password")"
[[ -r "$CERTS_DIR/public.crt" ]] || { echo "Falta public.crt" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker necessario." >&2; exit 1; }
docker inspect minio >/dev/null 2>&1 || { echo "minio nao esta up." >&2; exit 1; }
NETWORK="$(docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' minio | awk '{print $1}')"

POLICY_MOUNT=()
POLICY_SETUP="true"

if [[ "$MODE" == "internal" ]]; then
  [[ -r "$POLICIES_DIR/$POLICY_JSON" ]] || {
    echo "Falta policy interna: $POLICIES_DIR/$POLICY_JSON" >&2
    exit 1
  }
  POLICY_MOUNT=(-v "$POLICIES_DIR/$POLICY_JSON:/policies/$POLICY_JSON:ro")
  POLICY_SETUP="mc admin policy create local ${POLICY_NAME} /policies/${POLICY_JSON} || true"
else
  build_dynamic_policy
  POLICY_MOUNT=(-v "$TMP_POLICY:/policies/dynamic.json:ro")
  POLICY_SETUP="mc admin policy remove local ${POLICY_NAME} >/dev/null 2>&1 || true; mc admin policy create local ${POLICY_NAME} /policies/dynamic.json"
fi

docker run --rm --network "$NETWORK" \
  -e MINIO_ENDPOINT="$ENDPOINT" \
  -e ROOT_USER="$ROOT_USER" \
  -e ROOT_PASSWORD="$ROOT_PASSWORD" \
  -e ACCESS_KEY="$ACCESS_KEY" \
  -e SECRET_KEY="$SECRET_KEY" \
  -e POLICY_NAME="$POLICY_NAME" \
  -v "$CERTS_DIR/public.crt:/certs/public.crt:ro" \
  "${POLICY_MOUNT[@]}" \
  --entrypoint /bin/sh minio/mc -c '
    set -eu
    mkdir -p /root/.mc/certs/CAs
    cp /certs/public.crt /root/.mc/certs/CAs/minio.crt
    mc alias set local "$MINIO_ENDPOINT" "$ROOT_USER" "$ROOT_PASSWORD" >/dev/null
    '"$POLICY_SETUP"'
    mc admin user remove local "$ACCESS_KEY" >/dev/null 2>&1 || true
    mc admin user add local "$ACCESS_KEY" "$SECRET_KEY"
    mc admin policy attach local "$POLICY_NAME" --user "$ACCESS_KEY"
    echo "minio: user=${ACCESS_KEY} policy=${POLICY_NAME}" >&2
  '

unset ROOT_USER ROOT_PASSWORD

echo "OK — policy: ${POLICY_NAME}" >&2
if [[ "$MODE" == "dynamic" ]]; then
  echo "  read:  ${READ_SPECS:-—}" >&2
  echo "  write: ${WRITE_SPECS:-—}" >&2
fi

if [[ "$SHOW_ONCE" -eq 1 ]]; then
  echo "" >&2
  echo ">>> CREDENCIAIS (copie agora) <<<" >&2
  echo "access_key=${ACCESS_KEY}" >&2
  printf 'secret_key=%s\n' "$SECRET_KEY"
  echo ">>> fim <<<" >&2
fi
unset SECRET_KEY

if [[ "$MODE" == "internal" ]]; then
  echo "Recrie hive/trino se rotacionou SA." >&2
fi
