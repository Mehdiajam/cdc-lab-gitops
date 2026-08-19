#!/bin/bash
jq '.data.activeTargets[] | select(.labels.job == "kafka/connect-metrics") | {health, lastError}' targets_new.json
