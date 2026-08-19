#!/bin/bash
kubectl run mysql-client --restart='Never' --image docker.io/bitnami/mysql:8.4.2 --command -- mysql -h host.docker.internal -u debezium -pdbz_password -e "INSERT INTO cdc_test.customers (first_name, last_name, email) VALUES ('Test', 'User', 'test4@example.com');"
