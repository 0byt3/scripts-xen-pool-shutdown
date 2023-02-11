#!/bin/bash

## name of the shutdown script
SCRIPT_NAME=xen-pool-shutdown.bash

APCUPSD_CONF_PATH="/etc/apcupsd/apcupsd.conf"

## APCUPSd scripts directory
apcupsd_scriptdir=` awk '/^[[:space:]]*SCRIPTDIR/ {print $2}' $APCUPSD_CONF_PATH `
apcupsd_doshutdown_script="$apcupsd_scriptdir/doshutdown"

## if the doshutdown script doesn't exist, create it
if [ ! -f "$apcupsd_doshutdown_script" ]; then
  echo -e '#!/bin/bash\n' > "$apcupsd_doshutdown_script"
fi
## make sure apcupsd doshutdown script is executable
chmod a+x "$apcupsd_doshutdown_script"

## get dir of current script (assuming xen shutdown script is also in this dir)
script_dir=` dirname $0 `

shutdown_script_src="$script_dir/$SCRIPT_NAME"
shutdown_script_dest="/scripts/$SCRIPT_NAME"

## make sure xen shutdown script is in this directory otherwise fail
if [ ! -f "$shutdown_script_src" ]; then
  echo "Xen shutdown script '$shutdown_script_src' does not exist" >&2
  exit 1
fi

## place xen shutdown script in /scripts
test -d /scripts || mkdir /scripts
if [ -f "$shutdown_script_dest" ]; then
  ## compare checksums to see if they're the same file
  src_md5=`md5sum $shutdown_script_src | awk '{print $1}'`
  dest_md5=`md5sum $shutdown_script_dest | awk '{print $1}'`

  if [ "$src_md5" == "$dest_md5" ]; then
    echo "'$SCRIPT_NAME' is already in /scripts"
  else
    echo "'$shutdown_script_dest' already exists and is not the same as '$shutdown_script_src'."
    echo "Replace '$shutdown_script_dest' with '$shutdown_script_src'?"
    read -p "[y/N]: " replace_file
    echo ""
    [ -z "`echo "$replace_file" | egrep -i '^[[:space:]]*y(es|)[[:space:]]*$' `" ] || rm -f "$shutdown_script_dest"
  fi
fi
test -f $shutdown_script_dest || cp $shutdown_script_src $shutdown_script_dest

## make sure xen shutdown script is executable
chmod u+x,g+x $shutdown_script_dest

## append execution of xen shutdown script to the apcupsd doshutdown script
if [ -z "` grep "$shutdown_script_dest" $apcupsd_doshutdown_script `" ]; then
  echo -e "\\n$shutdown_script_dest" >> $apcupsd_doshutdown_script
fi