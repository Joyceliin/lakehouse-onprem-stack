#!/bin/bash
set -e

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

read_secret_file AWS_ACCESS_KEY_ID
read_secret_file AWS_SECRET_ACCESS_KEY
read_secret_file SPARK_AUTH_SECRET
read_secret_file POSTGRES_PASSWORD
read_secret_file CONTROL_DB_PASSWORD

# TLS do MinIO: quando o certificado público está montado, a JVM passa a
# confiar nele. Parte das CAs padrão do Java (HTTPS externo continua valendo)
# e acrescenta a do MinIO. JAVA_TOOL_OPTIONS vale para master, worker, driver
# e executores, que herdam o ambiente deste processo.
# O truststore só tem certificados públicos; "changeit" é a senha padrão do
# cacerts do Java, não um segredo.
MINIO_CA_CERT="${MINIO_CA_CERT:-/etc/spark-certs/minio-ca.crt}"
if [ -f "$MINIO_CA_CERT" ]; then
  JAVA_HOME_DIR="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
  SPARK_TRUSTSTORE="${SPARK_TRUSTSTORE:-/tmp/spark-truststore.jks}"
  cp "${JAVA_HOME_DIR}/lib/security/cacerts" "$SPARK_TRUSTSTORE"
  chmod 600 "$SPARK_TRUSTSTORE"
  keytool -importcert -noprompt \
    -alias minio \
    -file "$MINIO_CA_CERT" \
    -keystore "$SPARK_TRUSTSTORE" \
    -storepass changeit >/dev/null
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Djavax.net.ssl.trustStore=${SPARK_TRUSTSTORE} -Djavax.net.ssl.trustStorePassword=changeit"
fi

if [ -f "${SPARK_HOME}/conf/spark-defaults.conf.template" ]; then
  envsubst < "${SPARK_HOME}/conf/spark-defaults.conf.template" > "${SPARK_HOME}/conf/spark-defaults.conf"
fi

# JARs em /opt/spark/extra-jars (bind mount de config/spark/jars no host)
if [ -d /opt/spark/extra-jars ]; then
  EXTRA_CP=""
  for jar in /opt/spark/extra-jars/*.jar; do
    [ -f "$jar" ] || continue
    EXTRA_CP="${EXTRA_CP}:${jar}"
  done
  if [ -n "$EXTRA_CP" ]; then
    EXTRA_CP="${EXTRA_CP#:}"
    {
      echo "spark.driver.extraClassPath ${EXTRA_CP}"
      echo "spark.executor.extraClassPath ${EXTRA_CP}"
    } >> "${SPARK_HOME}/conf/spark-defaults.conf"
  fi
fi

PY4J_ZIP=""
for candidate in "${SPARK_HOME}"/python/lib/py4j-*-src.zip; do
  PY4J_ZIP="$candidate"
  break
done

if [ -f "$PY4J_ZIP" ]; then
  export PYTHONPATH="${SPARK_HOME}/python:${PY4J_ZIP}:${PYTHONPATH:-}"
else
  export PYTHONPATH="${SPARK_HOME}/python:${PYTHONPATH:-}"
fi

exec "$@"
