#!/bin/bash
# Fix the mysql-connector by updating config via REST API (disables SSL)
POD=$(kubectl get pod -n kafka -l app=kafka-connect -o jsonpath='{.items[0].metadata.name}')
echo "Using pod: $POD"

kubectl exec -n kafka "$POD" -i -- curl -s -X PUT \
  -H 'Content-Type: application/json' \
  http://localhost:8083/connectors/mysql-connector/config \
  -d @- <<'EOF'
{
  "connector.class": "io.debezium.connector.mysql.MySqlConnector",
  "tasks.max": "1",
  "database.hostname": "host.docker.internal",
  "database.port": "3306",
  "database.user": "${env:MYSQL_USER}",
  "database.password": "${env:MYSQL_PASSWORD}",
  "database.server.id": "184054",
  "topic.prefix": "mysqlcdc",
  "database.include.list": "cdc_test",
  "schema.history.internal.kafka.bootstrap.servers": "cdc-kafka-kafka-bootstrap:9092",
  "schema.history.internal.kafka.topic": "schema-changes.cdc_test",
  "database.connectionTimeZone": "UTC",
  "database.ssl.mode": "disabled",
  "column.mask.with.12.chars": "cdc_test.customers.email",
  "transforms": "route",
  "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
  "transforms.route.regex": "([^.]+)\\.([^.]+)\\.([^.]+)",
  "transforms.route.replacement": "$3"
}
EOF

echo ""
echo "Waiting 5s for connector to restart..."
sleep 5

echo "Connector status:"
kubectl exec -n kafka "$POD" -- curl -s http://localhost:8083/connectors/mysql-connector/status | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('Connector:', d['connector']['state'], '| Task:', d['tasks'][0]['state'])"
