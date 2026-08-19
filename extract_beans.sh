#!/bin/bash
kubectl exec -n kafka deployment/kafka-connect -- curl -sL -o /tmp/jmxterm.jar https://github.com/jiaqi/jmxterm/releases/download/v1.0.4/jmxterm-1.0.4-uber.jar
kubectl exec -it -n kafka deployment/kafka-connect -- sh -c 'echo "beans" | java -jar /tmp/jmxterm.jar -n -v silent -l 1' > debezium_beans_list.txt
