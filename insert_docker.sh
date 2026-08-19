#!/bin/bash
docker run --rm mysql:8.0 mysql -h host.docker.internal -u root -pnewpassword -e "INSERT INTO cdc_test.customers (name, email) VALUES ('Test User', CONCAT('test', UNIX_TIMESTAMP(), '@example.com'));"
