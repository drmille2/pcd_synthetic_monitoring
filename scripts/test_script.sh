#!/bin/bash

sleep_random() {
  sign=$(($RANDOM%(2)))
  splay=$(($RANDOM%(500)))
  if [[ $sign -eq 0 ]]; then
    duration=$(bc <<< "scale=3; $1 + $splay/1000")
  else
    duration=$(bc <<< "scale=3; $1 - $splay/1000")
  fi
  sleep $duration
}

echo "Simulated monitor test"
echo "Sleeping for $1 seconds with 1s random splay"
echo "Simulating "$2"% failure rate"

res=$(($RANDOM%(100)))
sleep_random $1
if [[ res -lt $2 ]]; then
  echo "simulated failure"
  exit 1
else
  echo "simulated success"
  exit 0
fi
exit 0
