#!/bin/bash

# 20240605173702 - 3

# grep '_RemotePageState constructor, create ffi begin' * | awk -F ':' '{print $1}' | sort | uniq -c

mkdir logs

sleep_main=5
sleep_conn=60
peer_id=505256207

while true
do
  current_time=$(date "+%Y%m%d%H%M%S")

  echo "Test begin at $current_time"

  nohup ./RustDesk > "logs/log_$current_time.txt" & 2>&1

  sleep $sleep_main

  for i in {1..5}; do
    echo "Test connection $i"
    ./RustDesk --connect $peer_id
    sleep $sleep_conn
    ./RustDesk --file-transfer $peer_id
    sleep 5
  done
  
  pkill RustDesk
  sleep 5

  echo "Test end"
done
