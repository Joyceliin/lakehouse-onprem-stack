# syntax=docker/dockerfile:1.4
#
# Build rápido:
#   - usa imagem oficial com Spark 4.1.2 já instalado (evita tarball ~400 MB)
#   - camadas pesadas (JARs/pip) ficam antes do COPY de configs
#   - rebuild após mudar só .conf/.sh reutiliza cache das camadas anteriores
#   - evite --no-cache salvo troca de versão
#   - DOCKER_BUILDKIT=1 acelera apt/pip e cache de JARs entre rebuilds
#
ARG SPARK_BASE_IMAGE=apache/spark:4.1.2-scala2.13-java17-python3-ubuntu
FROM ${SPARK_BASE_IMAGE}

USER root

ARG DELTA_VERSION=4.1.0
ARG HADOOP_AWS_VERSION=3.4.2
ARG AWS_SDK_BUNDLE_VERSION=2.29.52
ARG POSTGRES_JDBC_VERSION=42.7.4

ENV SPARK_HOME=/opt/spark
ENV PATH="${SPARK_HOME}/bin:${SPARK_HOME}/sbin:${PATH}"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends curl gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/spark-python-requirements.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --no-cache-dir -r /tmp/spark-python-requirements.txt \
    && rm /tmp/spark-python-requirements.txt

# Delta Lake + S3A + PostgreSQL JDBC
# Spark 4.1 usa Scala 2.13; Delta 4.1 publica artefato específico para Spark 4.1.
# O aws-sdk-bundle é o download mais pesado (~500 MB) — normal demorar na 1ª vez.
RUN --mount=type=cache,target=/var/cache/spark-extra-jars \
    set -eux; \
    fetch_jar() { \
      url="$1"; \
      dest="$2"; \
      cache="/var/cache/spark-extra-jars/$(basename "${dest}")"; \
      if [ -f "${cache}" ]; then \
        cp "${cache}" "${dest}"; \
      else \
        curl -fsSL "${url}" -o "${dest}"; \
        cp "${dest}" "${cache}"; \
      fi; \
    }; \
    fetch_jar \
      "https://repo1.maven.org/maven2/io/delta/delta-spark_4.1_2.13/${DELTA_VERSION}/delta-spark_4.1_2.13-${DELTA_VERSION}.jar" \
      "${SPARK_HOME}/jars/delta-spark_4.1_2.13-${DELTA_VERSION}.jar"; \
    fetch_jar \
      "https://repo1.maven.org/maven2/io/delta/delta-storage/${DELTA_VERSION}/delta-storage-${DELTA_VERSION}.jar" \
      "${SPARK_HOME}/jars/delta-storage-${DELTA_VERSION}.jar"; \
    fetch_jar \
      "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar" \
      "${SPARK_HOME}/jars/hadoop-aws-${HADOOP_AWS_VERSION}.jar"; \
    fetch_jar \
      "https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_SDK_BUNDLE_VERSION}/bundle-${AWS_SDK_BUNDLE_VERSION}.jar" \
      "${SPARK_HOME}/jars/aws-sdk-bundle-${AWS_SDK_BUNDLE_VERSION}.jar"; \
    fetch_jar \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRES_JDBC_VERSION}/postgresql-${POSTGRES_JDBC_VERSION}.jar" \
      "${SPARK_HOME}/jars/postgresql-${POSTGRES_JDBC_VERSION}.jar"

COPY spark-defaults.conf ${SPARK_HOME}/conf/spark-defaults.conf
COPY spark-defaults.conf.template ${SPARK_HOME}/conf/spark-defaults.conf.template
COPY start-spark.sh ${SPARK_HOME}/bin/start-spark.sh
RUN chmod +x ${SPARK_HOME}/bin/start-spark.sh

WORKDIR /opt/spark

ENTRYPOINT ["/opt/spark/bin/start-spark.sh"]
