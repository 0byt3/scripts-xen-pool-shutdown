#!/bin/bash

# shutdown_host_vms() {
#   xe_host_uuid="$1"

#   xe_host_name=
# }

host_name=` hostname -s `
hostuuid=` xe host-list name-label=$host_name params=uuid | awk '/uuid/ {print $5}' `

dom_uuids=`xe vm-list resident-on=$hostuuid power-state=running name-label="Control domain on host: $host_name" params=uuid | awk '/uuid/ {print $5}'`

for vmuuid in ` xe vm-list resident-on=$hostuuid power-state=running params=uuid | awk "\\$1==\\"uuid\\" && \\$5!=\\"$dom_uuid\\" {print \\$5}" `; do
  xe vm-shutdown uuid=$vmuuid &
done

echo -n "Waiting VM for shutdown jobs to complete on..."
while [ -n "`jobs | grep vm-shutdown`" ]; do
  echo -n "."
  sleep 1s
done

xe host-reboot name-label=$host_name
