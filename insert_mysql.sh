#!/bin/bash
mysql -h $(grep nameserver /etc/resolv.conf | awk '{print $2}') -u debezium -pdbz_password -e "INSERT INTO cdc_test.customers (first_name, last_name, email) VALUES ('Test', 'User', 'test5@example.com');"
