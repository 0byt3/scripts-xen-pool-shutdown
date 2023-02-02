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

is_host_online() {
  local chech_host_addr="$1"

  ## if no line exists stating "0 receieved" in ping output then the host is online
  local ping_check=` ping -c 3 $chech_host_addr | grep '0 received' `

  ## just in case ping access is not available test connectivity over HTTPS
  curl -s -k -f --connect-timeout 2 "https://$check_host_addr" 2>&1 >/dev/null
  local curl_retval=$?

  if [ -z "$ping_check" ] || [ $curl_retval == 0 ]; then
    echo "TRUE"
  else
    echo "FALSE"
  fi
}

log() {
  # throw error if there are not two arguments
  if [ $# != 2 ]; then
    echo "The log function takes 2 arguments. Received $#." >&2
    return 1
  fi

  # supported logger levels are: emerg, alert, crit, err, warning, notice, info, debug
  if [ -z "` echo "$1" | egrep -i '(emerg|alert|crit|err|warning|notice|info|debug)' `" ]; then
    echo "Unsupport log level '$1'" >&2
    return 1
  else
  fi
    local log_level="$1"

  ## if the log is an error type then output to stderr as well, otherwise log
  msg="[${log_level}] `date '+%Y-%b%d %H:%M:%S'` ${this_hostname} ${2}"
  echo "${msg}" >> /var/log/xen-pool-shutdown.log
  if [  -n "` echo "$log_level" | grep '(emerg|err)' `" ]; then
    # logger -s -t "$PROGRAM_NAME" -p syslog.$log_level "$2"
    echo "${msg}" >&2
  # else
  #   logger -t "$PROGRAM_NAME" -p syslog.$log_level "$2"
  fi
}

shutdown_secondary_hosts() {
  local pool_secondary_hosts=` xe host-list params=name-label | awk '$1=="name-label" && $5!="'$this_host_uuid'" { print $5 }' `

  for secondary_host_name in "$pool_secondary_hosts"; do
    log info "Disabling host '$secondary_host_name'"
    xe host-disable name-label=$secondary_host_name
    
    log info "Issuing shutdown to '$secondary_host_name' using xe CLI."
    local shutdown_result=` xe host-shutdown name-label=$secondary_host_name 2>&1 `

    ## if host-shutdown via xapi fails then try over SSH using public key auth
    if [ $? != 0 ]; then
      
      log error "Error issuing shutdown to host '$secondary_host_name' using xe CLI: $shutdown_result"
      unset shutdown_result

      local secondary_host_addr=` xe host-list name-label=$secondary_host_name params=address --minimal `
      # if ping check succeeds then use ssh to poweroff
      if [ "` is_host_online "$secondary_host_addr" `" == "TRUE" ]; then
        log info "Issuing shutdown using ssh and public key authentication."
        ssh_result=` ssh -o PubkeyAuthentication=yes $secondary_host_addr "poweroff" 2>&1 `
        [ $? == 0 ] || log error "Error issuing shutdown using ssh: $ssh_result"
        unset ssh_result
      fi
      unset secondary_host_addr

    fi

  done
  unset pool_secondary_hosts
}

wait_hosts_shutdown() {
  local this_host_addr=` xe host-list hostname=$this_host_name params=address --minimal `
  local pool_secondary_addr=`xe host-list params=address | awk '$1=="address" && $5!="'$this_host_addr'" {print $5}' `

  local hosts_online="FALSE"
  local timer=0
  while true; do

    for host_addr in "${pool_secondary_addr}"; do
      [ "` is_host_online "$host_addr" `" == "TRUE" ] && hosts_online="TRUE" && break
    done
    
    if [ $timer == $WAIT_ON_HOSTS_TIMEOUT ]; then
      log error "Timed out waiting for secondary hosts to shutdown. Waited ${WAIT_ON_HOSTS_TIMEOUT} seconds."
      break
    fi

    [ hosts_online == "FALSE" ] && break || sleep 1s

    ((timer++))
  done

  unset pool_secondary_hosts
  unset this_host_addr
  [ $timer == $WAIT_ON_HOSTS_TIMEOUT ] || return 1
}

this_host_name=` hostname -s `

## issue shutdown to all VMs still running (not just the VMs on this host)
vm_shutdown_result=` xe vm-shutdown power-state=running is-control-domain=false --multiple 2>&1 `
[ $? == 0 ] || log error "Error issuing shutdown to VMs using xe CLI: $vm_shutdown_result"
unset vm_shutdown_result

## issue shutdown to secondary hosts
shutdown_secondary_hosts

## wait for secondary hosts to shutdown
wait_hosts_shutdown

## disable this host (required in order for shutdown to work)
vm_shutdown_result=` xe host-disable hostname=$this_host_name 2>&1 `
[ $? == 0 ] || log error "Error issuing disable to '$this_host_name': $vm_shutdown_result"
unset vm_shutdown_result

## shutdown this host
host_shutdown_result=` xe host-shutdown hostname=$this_host_name 2>&1 `
[ $? == 0 ] || log error "Error issuing shutdown to '$this_host_name': $host_shutdown_result"
unset shutdown_result
