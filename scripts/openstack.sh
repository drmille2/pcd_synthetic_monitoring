#!/bin/bash 

SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
source "$SCRIPT_DIR"/openstack_lib.sh

function usage() {
    echo "openstack.sh -s {service_name} [service_args]"
}

ARGS=""
while getopts "s:t:n:m:c:y:a:" opt; do
  case $opt in
  s)
    SERVICE="$OPTARG"
    ;;
  t)
    TIMEOUT="$OPTARG"
    ;;
  n)
    NUM=" -n $OPTARG"
    ;;
  m)
    MAX=" -m $OPTARG"
    ;;
  c)
    SVC=" -n $OPTARG"
    ;;
  y)
    HYP=" -n $OPTARG"
    ;;
  a)
    AGENT=" -n $OPTARG"
    ;;
  esac
done

if [ -z $SERVICE ] ; then
  echo "-s argument required" && usage && exit 1;
fi

validate_bin
validate_env

rc=0
case ${SERVICE,,} in
    "keystone")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi
    ;;

    "nova")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi

        nova_list_servers $MAX $NUM
        if [ $? -ne 0 ]; then
            echo "nova_list_servers failed"
            rc=1
        fi

        nova_list_services $SVC
        if [ $? -ne 0 ]; then
            echo "nova_list_services failed"
            rc=1
        fi
    ;;

    "neutron")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi

        neutron_list_networks $NUM $MAX
        if [ $? -ne 0 ]; then
            echo "neutron_list_networks failed"
            rc=1
        fi

        neutron_list_agents $AGENT
        if [ $? -ne 0 ]; then
            echo "neutron_list_agents failed"
            rc=1
        fi
    ;;

    "cinder")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi

        cinder_list_volumes $MAX $NUM
        if [ $? -ne 0 ]; then
            echo "cinder_list_volumes failed"
            rc=1
        fi

        cinder_list_services $SVC
        if [ $? -ne 0 ]; then
            echo "cinder_list_services failed"
            rc=1
        fi
    ;;

    "glance")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi

        glance_list_images $MAX $NUM
        if [ $? -ne 0 ]; then
            echo "glance_list_images failed"
            rc=1
        fi
    ;;

    "placement")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi

        placement_list_providers $NUM
        if [ $? -ne 0 ]; then
            echo "placement_list_providers failed"
            rc=1
        fi
    ;;

    "resmgr")
        keystone_get_token
        if [ $? -ne 0 ]; then
            echo "keystone_get_token failed"
            exit 1;
        fi

        resmgr_list_hosts $NUM
        if [ $? -ne 0 ]; then
            echo "resmgr_list_hosts failed"
            rc=1
        fi
    ;;

    *)
    echo 'invalid service name, acceptable values are "keystone", "nova", "neutron", "cinder", "glance", "placement", "resmgr"' 
    ;;
esac

exit $rc

