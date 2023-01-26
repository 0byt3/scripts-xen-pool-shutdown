#!/bin/bash

shutdown_vms() {

  if [ -n "$1" ]; then
    xe_host_uuid="$1"
    vm_uuids=` xe vm-list resident-on=$xe_host_uuid is-control-domain=false power-state=running params=uuid | awk "\\$1==\\"uuid\\" {print \\$5}" `
  else
    vm_uuids=` xe vm-list is-control-domain=false power-state=running params=uuid | awk "\\$1==\\"uuid\\" {print \\$5}" `
  fi
  
  for vm_uuid in "$vm_uuids"; do
    xe vm-shutdown uuid=$vm_uuid &
  done

  # Wait for VMs to shutdown
  while [ -n "` jobs | grep vm-shutdown `" ]; do
    sleep 1s
  done
}

## wait for other hosts to shutdown
wait_on_hosts() {
  this_host_addr==` xe host-list uuid=$host_uuid params=address | awk '/address/ {print $5}' `
  hosts_online="TRUE"
  while [ "$hosts_online" == "TRUE" ]; do
    hosts_online="FALSE"
    for host_addr in ` xe host-list params=address | awk "\\$5\!=\"$this_host_addr\" { print \\$5 }" `; do
      ## if no line exists stating "0 receieved" in ping output then the host is online
      [ -n "` ping -c 3 $host_addr | grep '0 received' `" ] || hosts_online="TRUE"
    done

    [ "$hosts_online" == "TRUE" ] && sleep 1s
  done
}

host_name=` hostname -s `
host_uuid=` xe host-list hostname=$host_name params=uuid | awk '/uuid/ {print $5}' `

shutdown_vms "$host_uuid"

## if this is the master then we need to wait for the other hosts to shutdown.
#   the other hosts won't be able to interact with xe if the master is off
master_uuid=` xe pool-list params=master | awk '/master/ {print $5}' `

if [ "$master_uuid" == "$host_uuid" ]; then
  wait_on_hosts
fi

xe host-shutdown hostname=$host_name

xcp-python-libs