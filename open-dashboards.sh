#!/bin/bash
set -e

echo "⏳ Waiting for cluster to be accessible..."
until kubectl get nodes > /dev/null 2>&1; do
    echo "Cluster not ready yet, sleeping 5s..."
    sleep 5
done

echo "⏳ Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

echo "⏳ Waiting for Kafka UI to be ready..."
kubectl wait --for=condition=Available deployment/kafka-ui -n kafka --timeout=300s

echo "🧹 Cleaning up any old port-forwards..."
pkill -f "kubectl port-forward svc/argocd-server" || true
pkill -f "kubectl port-forward svc/kafka-ui" || true

echo "🚀 Starting Port Forwarding in the background..."
kubectl port-forward svc/argocd-server -n argocd 8090:443 > /dev/null 2>&1 &
kubectl port-forward svc/kafka-ui -n kafka 8081:8080 > /dev/null 2>&1 &

echo "🌐 Opening Dashboards in your browser..."
explorer.exe "https://localhost:8090"
explorer.exe "http://localhost:8081"

echo "✅ Dashboards are open and port-forwarding is running in the background!"
