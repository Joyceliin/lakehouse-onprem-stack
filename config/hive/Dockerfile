FROM apache/hive:3.1.3

USER root

COPY entrypoint.sh /entrypoint.sh

# Hive 3.1.3 ships with an old PostgreSQL JDBC driver that cannot authenticate
# against PostgreSQL users stored with SCRAM-SHA-256 passwords.
ADD https://repo1.maven.org/maven2/org/postgresql/postgresql/42.6.0/postgresql-42.6.0.jar /tmp/postgresql-42.6.0.jar
RUN sed -i 's/\r$//' /entrypoint.sh && chmod 0755 /entrypoint.sh
RUN rm -f /opt/hive/lib/postgresql-*.jar
RUN mv /tmp/postgresql-42.6.0.jar /opt/hive/lib/postgresql-42.6.0.jar
RUN cp /opt/hadoop/share/hadoop/tools/lib/hadoop-aws-*.jar /opt/hive/lib/
RUN cp /opt/hadoop/share/hadoop/tools/lib/aws-java-sdk-bundle-*.jar /opt/hive/lib/
RUN chmod 0644 /opt/hive/lib/postgresql-42.6.0.jar /opt/hive/lib/hadoop-aws-*.jar /opt/hive/lib/aws-java-sdk-bundle-*.jar
# gosu: entrypoint roda como root para ler Docker secrets (0400), depois desce para hive.
RUN apt-get update \
  && apt-get install -y --no-install-recommends gosu \
  && rm -rf /var/lib/apt/lists/*
# Permanece root — o entrypoint executa o Hive como usuário hive via gosu.
