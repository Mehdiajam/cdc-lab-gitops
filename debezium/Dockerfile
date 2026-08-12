FROM quay.io/strimzi/kafka:0.42.0-kafka-3.7.1
USER root:root

# Create the plugins directory
RUN mkdir -p /opt/kafka/plugins/debezium-mysql

# Download the Debezium MySQL connector plugin
RUN curl -L -O https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/2.6.2.Final/debezium-connector-mysql-2.6.2.Final-plugin.tar.gz && \
    tar xzf debezium-connector-mysql-2.6.2.Final-plugin.tar.gz -C /opt/kafka/plugins/debezium-mysql --strip-components=1 && \
    rm debezium-connector-mysql-2.6.2.Final-plugin.tar.gz

USER 1001
