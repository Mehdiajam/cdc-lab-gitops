#!/bin/bash
set -e

echo "🚀 Deleting corrupted cluster (if any)..."
kind delete cluster --name cdc-lab || true

echo "🚀 Creating fresh cluster..."
kind create cluster --name cdc-lab

echo "🚀 Building custom Debezium Connect image..."
docker build -t custom-debezium-connect:1.0 ./debezium
kind load docker-image custom-debezium-connect:1.0 --name cdc-lab

echo "🚀 Installing Argo CD..."
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for Argo CD to be ready..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

echo "🚀 Bootstrapping cluster state..."
kubectl create namespace kafka || true

# Install Strimzi operator first
echo "🚀 Installing Strimzi Operator..."
kubectl apply -f https://strimzi.io/install/latest?namespace=kafka -n kafka
echo "⏳ Waiting for Strimzi to be ready..."
kubectl wait --for=condition=Ready pods -l name=strimzi-cluster-operator -n kafka --timeout=300s

# Apply the local manifests immediately so you don't have to wait for a git push during local testing
echo "🚀 Applying local infrastructure manifests..."
kubectl apply -f secrets.yaml
kubectl apply -f kafka/kafka-cluster.yaml
kubectl apply -f debezium/kafka-connect.yaml

# Wait for Kafka Connect to be ready before applying connector
echo "⏳ Waiting for Kafka Connect to be ready... (this can take a couple minutes)"
kubectl wait --for=condition=Available deployment/kafka-connect -n kafka --timeout=300s || echo "Kafka Connect might still be starting, moving on..."

# Also apply ArgoCD application so it takes over management
echo "🚀 Registering Argo CD Application..."
kubectl apply -f argocd/cdc-app.yaml

echo "🚀 Registering Connectors via REST API..."
# Wait for REST API to be up
until kubectl exec deployment/kafka-connect -n kafka -- curl -s http://localhost:8083/ > /dev/null; do sleep 2; done;

kubectl exec deployment/kafka-connect -n kafka -i -- curl -s -X POST -H 'Accept:application/json' -H 'Content-Type:application/json' localhost:8083/connectors/ -d @- < connector-configs/mysql-connector.json
kubectl exec deployment/kafka-connect -n kafka -i -- curl -s -X POST -H 'Accept:application/json' -H 'Content-Type:application/json' localhost:8083/connectors/ -d @- < connector-configs/postgres-sink-connector.json

echo "🚀 Starting Port Forwarding in the background..."
kubectl port-forward svc/argocd-server -n argocd 8090:443 > /dev/null 2>&1 &
kubectl port-forward svc/kafka-ui -n kafka 8081:8080 > /dev/null 2>&1 &

echo "🌐 Opening Dashboards in your browser..."
explorer.exe "https://localhost:8090"
explorer.exe "http://localhost:8081"

echo "✅ Bootstrap complete! To fully sync via GitOps, remember to commit and push your changes to GitHub."
