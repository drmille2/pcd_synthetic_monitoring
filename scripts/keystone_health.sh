#!/bin/bash 

DU=$1
keystone_output=$(curl -s https://"$DU"/keystone/v3)
status=$(echo $keystone_output | jq '.version.status' -r)

if [ "$status" != "stable" ]; then
  echo "Error: Keystone API failed to report 'stable'. Full output: "
  echo $keystone_output
  exit 1
else
  echo "Keystone API reports stable"
fi
