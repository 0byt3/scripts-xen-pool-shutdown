#!/bin/bash

## timeout in seconds to wait for other hosts to shutdown (only applies if this is the pool's master)
WAIT_ON_HOSTS_TIMEOUT=600

PROGRAM_NAME="xen-shutdown-script"

get_addr_of_hosts() {
  ## check to make sure host_uuid exists
  if [ -z "$host_uuid" ]; then
    echo "Missing host_uuid var. Required by get_addr_of_hosts function." >&2
    return 1
  fi
  local this_host_addr=` xe host-list uuid=$host_uuid params=address | awk '/address/ {print $5}' `
  for host_addr in ` xe host-list params=address | awk '$5!="'$this_host_addr'" && $1=="address" { print $5 }' `; do
    echo "$host_addr"
  done

}

get_vm_name_from_uuid() {
  xe vm-list uuid=$1 params=name-label | awk '/name-label/ {print $5}'
}

is_host_online() {
  local chech_host_addr="$1"

  ## if no line exists stating "0 receieved" in ping output then the host is online
  [ -z "` ping -c 3 $chech_host_addr | grep '0 received' `" ] && return 0 || return 1
}

log() {
  # throw error if there are two arguments
  if [ $# != 2 ]; then
    echo "The log function requires 2 arguments. Received only $#." >&2
    return 1
  fi

  # supported logger levels are: emerg, alert, crit, err, warning, notice, info, debug
  if [ -n "` echo "$1" | egrep -i '(emerg|alert|crit|err|warning|notice|info|debug)' `" ]; then
    echo "Unsupport log level '$1'" >&2
    exit 1
  else
    local log_level="$1"
  fi

  ## if the log is an error type then output to stderr as well otherwise log
  if [  -n "` echo "$1" | grep '(emerg|err)' `" ]; then
    logger -s -t "$PROGRAM_NAME" -p syslog.$log_level "$2"
  else
    logger -t "$PROGRAM_NAME" -p syslog.$log_level "$2"
  fi
}

shutdown_hosts() {
  for host_addr in ` get_addr_of_hosts `; do
    if ` is_host_online "$host_addr" `; then
      xe host-disable address=$host_addr
      xe host-shutdown address=$host_addr
      ## if host-shutdown via xapi fails then try over SSH using public key auth
      [ $? == 0 ] || ssh -o PubkeyAuthentication=yes $host_addr "poweroff"
    fi
  done
}

shutdown_vms() {

  if [ -n "$1" ]; then
    local xe_host_uuid="$1"
    local vm_uuids=` xe vm-list resident-on=$xe_host_uuid is-control-domain=false power-state=running params=uuid | awk "\\$1==\\"uuid\\" {print \\$5}" `
  else
    local vm_uuids=` xe vm-list is-control-domain=false power-state=running params=uuid | awk "\\$1==\\"uuid\\" {print \\$5}" `
  fi
  
  for vm_uuid in "$vm_uuids"; do
    local vm_name=`get_vm_name_from_uuid`
    log info "Issuing shutdown to VM '$vm_uuid' ($vm_name)"
    xe vm-shutdown uuid=$vm_uuid &
  done

  # Wait for VMs to shutdown
  while [ -n "` jobs | grep vm-shutdown `" ]; do
    sleep 1s
  done
}

## wait for other hosts to shutdown
wait_on_hosts() {
  local timeout=$1
  local loop_count=0

  while true; do
    local hosts_online="FALSE"
    for host_addr in ` get_addr_of_hosts `; do
      
      if ` is_host_online "$host_addr" `; then
        local hosts_online="TRUE"
        break
      fi
    done
    
    ## if a host is still online then wait 1 second then continue, otherwise break while loop
    [ "$hosts_online" == "TRUE" ] && sleep 1s || break

    ## if timeout has been reached, break while loop
    [ $loop_count == $timeout ] && break

    ((loop_count++))
  done

  ## if did not stop due to timeout stop with code 0, otherwise stop with code 1 (timed out)
  [ $loop_count != $timeout ] && return 0 || return 1
}

host_name=` hostname -s `
host_uuid=` xe host-list hostname=$host_name params=uuid | awk '/uuid/ {print $5}' `

## shutdown VMs on this host
shutdown_vms "$host_uuid"

## if this is the master then we need to wait for the other hosts to shutdown.
#   the other hosts won't be able to use xe command if the master is off
master_uuid=` xe pool-list params=master | awk '/master/ {print $5}' `

if [ "$master_uuid" == "$host_uuid" ]; then
  # wait for other hosts in the pool to shutdown
  wait_on_hosts

  ## if hosts are not finished shutting down then take matters into our own hands
  if [ $? != 0 ]; then
    ## issue shutdown to all VMs still running (not just the VMs on this host)
    shutdown_vms

    ## attempt to issue a shutdown command to each host

  fi
fi

xe host-shutdown hostname=$host_name
