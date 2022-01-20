#!/usr/bin/env bash

function check_uptime() {
  retries=$1
  timeout=$2

  for _ in seq 1 $retries; do
    BOOTTIME=$(./hack/vmuptime.ext | grep "^BOOTTIME" | cut -d= -f2 | tr -dc '[:digit:]')
    if [ -n "${BOOTTIME}" ]
      then
        echo "${BOOTTIME}"
        return 0;
      else
        sleep $timeout;
    fi
  done;
  echo "VM boot time could not be retrieved"
  return 1;
}
