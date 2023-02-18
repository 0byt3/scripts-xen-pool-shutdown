#!/bin/bash

############################################################################################
##                                                                                        ##
##  This script is intended to be run on the pool master and will shutdown all VMs and    ##
##  hosts in the pool.                                                                    ##
##                                                                                        ##
############################################################################################

## timeout in seconds to wait for other hosts to shutdown
WAIT_ON_HOSTS_TIMEOUT=600

## program name to appear in the logs
PROGRAM_NAME="xen-shutdown-script"

function is_host_online {
  local check_host_addr="$1"

  ## if no line exists stating "0 receieved" in ping output then the host is online
  local ping_check
  ping_check=$( ping -c 3 "$check_host_addr" | grep '0 received' )

  ## just in case ping access is not available test connectivity over HTTPS
  { curl -s -k -f --connect-timeout 2 "https://$check_host_addr" > /dev/null; } 2>&1
  local curl_retval=$?

  if [ -z "$ping_check" ] || [ $curl_retval == 0 ]; then
    echo "TRUE"
  else
    echo "FALSE"
  fi
}

function get_primary_host {
  
  ## If getting the pool primary server uuid times out then just output ? as the primary host and
  #   return the exit code (which will be non-zero)
  if ! timeout 2s xe pool-list params=master --minimal > /dev/null 2>&1; then
    local retval
    retval=$?
    echo "?"
    return $retval
  fi

  local primary_uuid
  primary_uuid=$( xe pool-list params=master --minimal )
  xe host-list uuid="$primary_uuid" params=hostname --minimal
  
  unset primary_uuid
}

function log {
  # throw error if there are not two arguments
  if [ $# != 2 ]; then
    echo "The log function takes 2 arguments. Received $#." >&2
    return 1
  fi

  # supported logger levels are: emerg, alert, crit, err, warning, notice, info, debug
  if ! echo "$1" | grep -iqE '(emerg|alert|crit|err|warning|notice|info|debug)'; then
    echo "Unsupport log level '$1'" >&2
    return 1
  fi
  local log_level="$1"

  ## if the log is an error type then output to stderr as well, otherwise log
  msg="[$log_level] $(date '+%Y-%b%d %H:%M:%S') $this_hostname $2"
  echo "$msg" >> /var/log/xen-pool-shutdown.log
  if  echo "$log_level" | grep -iqE '(emerg|err)'; then
    # logger -s -t "$PROGRAM_NAME" -p syslog.$log_level "$2"
    echo "$msg" >&2
  else
    echo "$msg"
  #   logger -t "$PROGRAM_NAME" -p syslog.$log_level "$2"
  fi
}

function shutdown_secondary_hosts {
  ## get a list of secondary hosts in the pool
  local pool_secondary_hosts
  pool_secondary_hosts=$( xe host-list params=name-label | awk '$1=="name-label" && $5!="'$this_host_name'" { print $5 }' )

  while read secondary_host_name; do
    log info "Disabling host '$secondary_host_name'"
    xe host-disable name-label="$secondary_host_name"
    
    log info "Issuing shutdown to '$secondary_host_name' using xe CLI."
    local shutdown_result
    shutdown_result=$( xe host-shutdown name-label="$secondary_host_name" 2>&1 )

    ## if host-shutdown via xapi fails then try over SSH using public key auth
    if [ $? != 0 ]; then
      
      log error "Error issuing shutdown to host '$secondary_host_name' using xe CLI: $shutdown_result"
      unset shutdown_result

      ## first check if host is online, otherwise don't bother attempting ssh
      local secondary_host_addr
      secondary_host_addr=$( xe host-list name-label="$secondary_host_name" params=address --minimal )

      # if ping check succeeds then use ssh to poweroff
      if [ "$( is_host_online "$secondary_host_addr" )" == "TRUE" ]; then
        log info "Issuing shutdown using ssh and public key authentication."
        ssh_result=$( ssh -n -o PubkeyAuthentication=yes -o PasswordAuthentication=no "$secondary_host_addr" "poweroff" 2>&1 )
        [ $? == 0 ] || log error "Error issuing shutdown using ssh: $ssh_result"
        unset ssh_result
      fi
      unset secondary_host_addr

    fi

  done <<<"$pool_secondary_hosts"
  unset pool_secondary_hosts
}

function shutdown_vms {
  if [ -z "$1" ]; then
    log error "The 'shutdown_vms' function requires an argument for the hostname of the host. For any host use '*'."
    return 1
  fi

  local xcp_host_name
  xcp_host_name="$1"

  local xcp_host_uuid
  if [ "$xcp_host_name" != "*" ]; then
    xcp_host_uuid=$( xe host-list hostname="$xcp_host_name" params=uuid --minimal )
  fi

  ## check if any VMs are running
  if [ "$xcp_host_name" == "*" ]; then
    num_vms_running=$(xe vm-list is-control-domain=false power-state=running params=uuid --minimal | sed 's/,/ /g' | wc -w)
  else
    num_vms_running=$(xe vm-list host-uuid="$xcp_host_uuid" is-control-domain=false power-state=running params=uuid --minimal | sed 's/,/ /g' | wc -w)
  fi
  if [ "$num_vms_running" -lt 1 ]; then
    log info "No virtual machines are running. No VM shutdown required."
    return 0
  fi

  log info "Shutting down virtual machines."
  
  local vm_shutdown_stderr_path
  vm_shutdown_stderr_path="/tmp/$PROGRAM_NAME.vm_shutdown.$RANDOM.stderr"
  
  local vm_shutdown_time_result
  if [ "$xcp_host_name" == "*" ]; then
    vm_shutdown_time_result=$( time (xe vm-shutdown power-state=running is-control-domain=false --multiple >/dev/null 2>"$vm_shutdown_stderr_path") 2>&1 )
  else
    vm_shutdown_time_result=$( time (xe vm-shutdown host-uuid="$xcp_host_uuid" power-state=running is-control-domain=false --multiple >/dev/null 2>"$vm_shutdown_stderr_path") 2>&1 )
  fi

  if [ -f "$vm_shutdown_stderr_path" ] && [ -n "$(cat "$vm_shutdown_stderr_path")" ]; then
    local vm_shutdown_stderr
    vm_shutdown_stderr=$(cat "$vm_shutdown_stderr_path")
    log error "Error issuing shutdown to VMs using xe CLI: $vm_shutdown_stderr"
    unset vm_shutdown_stderr
  else
    local vm_shutdown_time
    vm_shutdown_time=$(echo "$vm_shutdown_time_result" | awk '/real/ {print $2}')
    log info "Virtual machine shutdown took $vm_shutdown_time"
    unset vm_shutdown_time
  fi
  test -f "$vm_shutdown_stderr_path" && rm -f "$vm_shutdown_stderr_path"
  unset vm_shutdown_stderr_path
  unset vm_shutdown_time_result
}

function wait_hosts_shutdown {
  log info "Waiting for secondary hosts to shutdown"

  local this_host_addr
  this_host_addr=$( xe host-list hostname="$this_host_name" params=address --minimal )
  local pool_secondary_addrs
  pool_secondary_addrs=$(xe host-list params=address | awk '$1=="address" && $5!="'$this_host_addr'" {print $5}' )

  local timer
  timer=0
  while true; do
    local hosts_online="FALSE"
    while read host_addr; do
      # [ "` is_host_online "$host_addr" `" == "TRUE" ] && echo "host '$host_addr' is online" && hosts_online="TRUE" && break
      [ "$( is_host_online "$host_addr" )" == "TRUE" ] && hosts_online="TRUE" && break
    done <<<"$pool_secondary_addrs"
    
    if [ $timer -eq $WAIT_ON_HOSTS_TIMEOUT ]; then
      log error "Timed out waiting for secondary hosts to shutdown. Waited ${WAIT_ON_HOSTS_TIMEOUT} seconds."
      break
    fi

    if [ $hosts_online == "FALSE" ]; then
      log info "All secondary hosts are offline"
      break
    else
      sleep 1s
    fi

    ((timer++))
  done

  unset pool_secondary_hosts
  unset this_host_addr
  [ $timer -eq $WAIT_ON_HOSTS_TIMEOUT ] || return 1
}

## Determine if this server is the primary server in the pool
if ! primary_host=$( get_primary_host ); then
  xe host-
fi

this_host_name=$( hostname )

## issue shutdown to all VMs still running (not just the VMs on this host)
shutdown_vms "*"

## instruct secondary hosts to shutdown
shutdown_secondary_hosts

## wait for secondary hosts to shutdown
wait_hosts_shutdown

## disable this host (required in order for shutdown to work)
log info "Issuing disable to '$this_host_name'"
if ! vm_shutdown_result=$( xe host-disable hostname="$this_host_name" 2>&1 ); then
  log error "Error issuing disable to '$this_host_name': $vm_shutdown_result"
fi
unset vm_shutdown_result

# ## shutdown this host
# log info "Issuing shutdown to '$this_host_name'"
# host_shutdown_result=` xe host-shutdown hostname=$this_host_name 2>&1 `
# [ $? == 0 ] || log error "Error issuing shutdown to '$this_host_name': $host_shutdown_result"
# unset shutdown_result
