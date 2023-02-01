#!/bin/bash

## !!! Setup rsyslog to create specific log files for this shutdown script

## shutdown script name
shut_script_name=xen-pool-shutdown.bash

## get dir of current script
script_dir=`dirname $0`

## get PROGRAM_NAME variable from the shutdown script
eval "` awk '/PROGRAM_NAME=/' $script_dir/$shut_script_name `"

cat > "/etc/rsyslog.d/01-$PROGRAM_NAME.conf" << EOF
if \$syslogtag == "$PROGRAM_NAME:" and \$syslogseverity-text == "err" then /var/log/$PROGRAM_NAME.err.log
if \$syslogtag == "$PROGRAM_NAME:" then /var/log/$PROGRAM_NAME.log
& stop
EOF


## !!! Create a systemd timer to re-enable the host at boot, so VMs will start