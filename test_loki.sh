#!/bin/bash
curl -s -G --data-urlencode 'query={cluster="kind-cdc-lab"}' http://172.19.0.3:32084/loki/api/v1/query
