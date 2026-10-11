#!/usr/bin/env bash

set -e

: "${DB_DRIVER:=derby}"

# Docker Compose monta secrets em /run/secrets/ como root:root 0400.
# O entrypoint inicia como root, lê os secrets e executa o Hive como hive.
as_hive() {
  if [ "$(id -u)" = "0" ]; then
    gosu hive "$@"
  else
    "$@"
  fi
}

read_secret_file() {
  local env_name="$1"
  local file_env_name="${env_name}_FILE"
  local file_path="${!file_env_name:-}"

  if [ -n "$file_path" ]; then
    if [ ! -r "$file_path" ]; then
      echo "Secret file for ${env_name} is not readable." >&2
      exit 1
    fi
    export "$env_name"="$(tr -d '\r\n' < "$file_path")"
  fi
}

initialize_hive() {
  if as_hive "$HIVE_HOME/bin/schematool" -dbType "$DB_DRIVER" -info; then
    echo "Hive schema already initialized."
    return 0
  fi

  as_hive "$HIVE_HOME/bin/schematool" -dbType "$DB_DRIVER" -initSchema
  echo "Initialized schema successfully."
}

export HIVE_CONF_DIR="$HIVE_HOME/conf"
if [ -d "${HIVE_CUSTOM_CONF_DIR:-}" ]; then
  find "$HIVE_CUSTOM_CONF_DIR" -type f -exec ln -sfn {} "$HIVE_CONF_DIR"/ \;
  export HADOOP_CONF_DIR="$HIVE_CONF_DIR"
  export TEZ_CONF_DIR="$HIVE_CONF_DIR"
fi

read_secret_file AWS_ACCESS_KEY_ID
read_secret_file AWS_SECRET_ACCESS_KEY

if [ -n "${HIVE_METASTORE_DB_PASSWORD_FILE:-}" ]; then
  if [ ! -r "$HIVE_METASTORE_DB_PASSWORD_FILE" ]; then
    echo "Hive metastore password file is not readable." >&2
    exit 1
  fi
  HIVE_METASTORE_DB_PASSWORD="$(tr -d '\r\n' < "$HIVE_METASTORE_DB_PASSWORD_FILE")"
  SERVICE_OPTS="${SERVICE_OPTS:-} -Djavax.jdo.option.ConnectionPassword=${HIVE_METASTORE_DB_PASSWORD}"
  unset HIVE_METASTORE_DB_PASSWORD
fi

export HADOOP_CLIENT_OPTS="${HADOOP_CLIENT_OPTS:-} -Xmx1G ${SERVICE_OPTS:-}"

# Truststore do MinIO (HTTPS) — JKS + senha via arquivos em secrets (não .env).
MINIO_TRUSTSTORE="${MINIO_TRUSTSTORE_PATH:-/opt/hive/conf/minio-truststore.jks}"
MINIO_TRUSTSTORE_PASS_FILE="${MINIO_TRUSTSTORE_PASSWORD_FILE:-/run/secrets/minio_truststore_password}"
if [ -r "$MINIO_TRUSTSTORE" ]; then
  if [ ! -r "$MINIO_TRUSTSTORE_PASS_FILE" ]; then
    echo "Truststore MinIO presente, mas senha ausente: ${MINIO_TRUSTSTORE_PASS_FILE}" >&2
    exit 1
  fi
  TS_PASS="$(tr -d '\r\n' < "$MINIO_TRUSTSTORE_PASS_FILE")"
  export HADOOP_CLIENT_OPTS="${HADOOP_CLIENT_OPTS} -Djavax.net.ssl.trustStore=${MINIO_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=${TS_PASS}"
  export HADOOP_OPTS="${HADOOP_OPTS:-} -Djavax.net.ssl.trustStore=${MINIO_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=${TS_PASS}"
  unset TS_PASS
fi

if [ "${IS_RESUME:-false}" != "true" ]; then
  initialize_hive
fi

if [ "${SERVICE_NAME}" = "hiveserver2" ]; then
  export HADOOP_CLASSPATH="$TEZ_HOME/*:$TEZ_HOME/lib/*:$HADOOP_CLASSPATH"
elif [ "${SERVICE_NAME}" = "metastore" ]; then
  # Sem -p o Hive 3.1 escuta sempre 9083; Trino usa HIVE_METASTORE_PORT (ex. 7077).
  export METASTORE_PORT="${METASTORE_PORT:-9083}"
fi

HIVE_CMD=( "$HIVE_HOME/bin/hive" --skiphadoopversion --skiphbasecp --service "$SERVICE_NAME" )
if [ "${SERVICE_NAME}" = "metastore" ]; then
  HIVE_CMD+=( -p "${METASTORE_PORT:-9083}" )
fi

if [ "$(id -u)" = "0" ]; then
  exec gosu hive "${HIVE_CMD[@]}"
else
  exec "${HIVE_CMD[@]}"
fi
