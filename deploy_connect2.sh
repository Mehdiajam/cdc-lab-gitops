#!/bin/bash
echo "Waiting for Kafka Connect to be ready..."
kubectl wait --for=condition=Available deployment/kafka-connect -n kafka --timeout=300s

echo "Registering connector..."
# Port forward to the service so curl can reach it from WSL
kubectl port-forward svc/kafka-connect -n kafka 8083:8083 &
PF_PID=$!
sleep 5

curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" localhost:8083/connectors/ -d @connector-configs/mysql-connector.json

kill $PF_PID
