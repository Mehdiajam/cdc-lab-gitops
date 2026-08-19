#!/bin/bash
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 > /dev/null 2>&1 &
sleep 2
curl -s 'http://localhost:9090/api/v1/query?query=%7B__name__%3D~"debezium_metrics_.*"%7D' > debug_debezium.json
