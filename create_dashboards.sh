#!/bin/bash
mkdir -p grafana-dashboards

# 1. Download Debezium Dashboard
echo "Downloading Debezium Dashboard..."
curl -sL "https://grafana.com/api/dashboards/18608/revisions/latest/download" > debezium.json

# Wrap into ConfigMap
echo "Creating ConfigMap for Debezium..."
kubectl create configmap debezium-dashboard --from-file=debezium-dashboard.json=debezium.json -n monitoring --dry-run=client -o yaml > grafana-dashboards/debezium-dashboard.yaml

# Add labels
sed -i '/metadata:/a\  labels:\n    grafana_dashboard: "1"' grafana-dashboards/debezium-dashboard.yaml

# 2. Download Strimzi Dashboard
echo "Downloading Strimzi Dashboard..."
curl -sL "https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/main/examples/metrics/grafana-dashboards/strimzi-kafka.json" > strimzi.json

# Wrap into ConfigMap
echo "Creating ConfigMap for Strimzi..."
kubectl create configmap strimzi-dashboard --from-file=strimzi-dashboard.json=strimzi.json -n monitoring --dry-run=client -o yaml > grafana-dashboards/strimzi-dashboard.yaml

# Add labels
sed -i '/metadata:/a\  labels:\n    grafana_dashboard: "1"' grafana-dashboards/strimzi-dashboard.yaml

rm debezium.json strimzi.json
echo "Dashboards successfully created in grafana-dashboards/ directory!"
