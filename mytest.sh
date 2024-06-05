#!/bin/bash

# 20240605173702 - 3

mkdir logs

sleep_main=5
sleep_conn=60
peer_id=1997116099

while true
do
  current_time=$(date "+%Y%m%d%H%M%S")

  echo "Test begin at $current_time"

  nohup ./RustDesk > "logs/log_$current_time.txt" & 2>&1

  sleep $sleep_main

  ./RustDesk --connect $peer_id

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
