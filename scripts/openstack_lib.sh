##
#
# Basic helper functions used for printing/validating/etc.
# 
##

# set a default timeout of 60s for calls
export TIMEOUT=60

function log_output() {
    local dt=$(date +"%F %X %Z")
    local sn=$(basename $0)
    echo "${dt} $sn[$(echo $$)]: ${@}"
}

# takes a directory and base filename for generating curl output
# and prints out available transaction details
function print_response() {
    local tmpd=$1; local filen=$2

    if [ -f "$tmpd/stderr" -a -s "$tmpd/stderr" ]; then
        log_output "curl stderr:"
        cat "$tmpd/stderr"
    else
        log_output "no curl stderr logged"
    fi
    echo

    if [ -f "$tmpd"/"$filen"00 -a -s "$tmpd"/"$filen"00 ]; then
        log_output "response headers:"
        cat "$tmpd"/"$filen"00
    else
        log_output "no response headers logged"
    fi
    echo

    if [ -f "$tmpd"/"$filen"01 -a -s "$tmpd"/"$filen"01 ]; then
        log_output "response body:"
        cat "$tmpd"/"$filen"01
    else
        log_output "no response body logged"
    fi
    echo
}

# check for any non-standard required binaries (curl & jq)
function validate_bin() {
    if ! command -v jq >/dev/null 2>&1; then
        log_output "jq required but not found, exiting" && exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_output "curl required but not found, exiting" && exit 1
    fi
}

# use standard openstack.rc envvars
function validate_env() {
    if [ -z "$OS_USERNAME" \
         -o -z "$OS_PASSWORD" \
         -o -z "$OS_AUTH_URL" \
         -o -z "$OS_REGION_NAME" \
         -o -z "$OS_PROJECT_NAME" \
         -o -z "$OS_INTERFACE" ]; then
        log_output "OpenStack envvars must be set, exiting" && exit 1
    fi
}

# report failure on any non-200 family status
function check_http_status() {
    local status=$(head -n1 $1 | cut -d' ' -f2)
    if [ ${status:0:1} -eq 2 ]; then
      log_output "status = ${status} (OK)"
      return 0
    else
      log_output "status = ${status} (FAIL)"
      return 1
    fi
}

##
#
# API methods and supporting functions
#
# Each function here has some standard before/after boilerplate for
# setting & reverting pipefail. This is to ensure that these functions
# can be used directly in a shell environment via 'source' without
# permanently modifying the calling environment.
#
#
##

#
# Keystone
# 
 
# takes service name and sets SERVICE_URL to the respective service endpoint 
# from a keystone catalog requires OS_REGION_NAME and OS_INTERFACE to be set
function keystone_get_endpoint() {

    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0

    if [ -z "$1" ]; then
        log_output "keystone_get_endpoint :: service name must be specified"
        return 1
    fi

    if [ -z "$CATALOG" ]; then
      keystone_get_token
      if [ $? -ne 0 ]; then
          echo "keystone_get_endpoint :: failure" && return 1
      fi
    fi

     SERVICE_URL=$(echo $CATALOG | jq -r --arg service "$1" --arg region $OS_REGION_NAME --arg interface $OS_INTERFACE '.token.catalog[] | select(.name == $service) | .endpoints[] | select (.interface == $interface) | select(.region == $region) .url')

    if [ -z "$SERVICE_URL" ]; then
        log_output "keystone_get_endpoint :: failed to discover service url for service=[$1]" 
        rc=1
    fi

    log_output "keystone_get_endpoint :: success, ${1} url is ${SERVICE_URL}"

    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

# perform a password login via keystone and set OS_TOKEN and CATALOG global vars
# requires OS_USERNAME, OS_PASSWORD, OS_AUTH_URL, and OS_PROJECT_NAME
function keystone_get_token() {

    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="get_token"

    local body
    read -r -d '' body <<EOF
    {
      "auth": {
        "identity": {
          "methods": ["password"] ,
            "password": {
              "user": {
                "name": "${OS_USERNAME}",
                "domain": {"id": "default"},
                "password": "${OS_PASSWORD}"
              }
            }
          },
      "scope": {
        "project": {
          "name": "${OS_PROJECT_NAME}",
          "domain": {"id": "default"}
          }
        }
      }
    }
EOF

    curl --max-time $TIMEOUT -sS -k -i -H "Content-Type: application/json" "${OS_AUTH_URL}/auth/tokens" -d "$body"  >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null
    CATALOG=$(cat "$tmpd"/"$filen"01)
    OS_TOKEN=$(cat "$tmpd"/"$filen"00 | grep -i ^X-Subject-Token | awk -F : '{print $2}' | tr -d '\r')

    if [ $? -ne 0 -o -z "$OS_TOKEN" -o -z "$CATALOG" ]; then
        log_output  "keystone_get_token :: error obtaining token and service catalog"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "keystone_get_token :: success"
    fi

    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "keystone_get_token :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

#
# Nova
# 

# list nova servers, optional parameter can be supplied as a limit
# -n num_server -- number of required servers (fail if fewer, default 0)
# -m max_server -- max number of servers to list (cannot be less than num_servers, default 100)
function nova_list_servers() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_servers"

    local max_server=100
    local num_server=0

    echo "nova_list_servers got args $@"
    local OPTIND n m
    while getopts "n:m:" opt; do
        case $opt in
        m)
          local max_server="$OPTARG"
          ;;
        n)
          local num_server="$OPTARG"          
          ;;
        esac
    done

    # if max servers is less than required we will always fail
    # so we need to max sure they're at least equal
    if [[ $max_server < $num_server ]]; then
        local max_server="$num_server"
    fi

    local path="servers?limit=$max_server"

    keystone_get_endpoint nova
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "nova_list_servers :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "nova_list_servers :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.servers | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output  "nova_list_servers :: error obtaining server list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_server ]]; then
        log_output  "nova_list_servers :: failure, $count servers returned, $num_server required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "nova_list_servers :: success, $count servers returned, $num_server required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "nova_list_servers :: http status check failed"
        rc=1
    fi

    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

# list nova hypervisors, optional parameter can be supplied as a limit
# -n num_hypervisor -- number of required hyperviors (fail if fewer, default 0)
# -m max_hypervisor -- max number of hypervisors to list (cannot be less than num_hypervisor, default 100)
function nova_list_hypervisors() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_hypervisors"
    local max_hypervisor=0
    local num_hypervisor=100

    local OPTIND n m 
    while getopts "n:m:" opt; do
        case $opt in
        m)
          local max_hypervisor="$OPTARG"
          ;;
        n)
          local num_hypervisor="$OPTARG"          
          ;;
        esac
    done

    # this is not supported until version 2.33, but doesn't cause
    # any issues on older versions--will just be ignored
    # 
    # if max hypervisors is less than required we will always fail
    # so we need to max sure they're at least equal
    if [[ $max_hypervisor < $num_hypervisor ]]; then
        local max_hypervisor="$num_hypervisor"
    fi

    local path="os-hypervisors?limit=$max_hypervisor"


    keystone_get_endpoint nova
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "nova_list_hypervisors :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "nova_list_hypervisors :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.hypervisors | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "nova_list_hypervisors :: error obtaining server list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_hypervisor ]]; then
        log_output "nova_list_hypervisors :: failure, $count hypervisors returned, $num_hypervisor required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "nova_list_hypervisors :: success, $count hypervisors returned, $num_hypervisor required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "nova_list_hypervisors :: http status check failed"
        rc=1
    fi

    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

# list nova services
# -n num_service -- number of required services (fail if fewer, default 0)
function nova_list_services() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_services"
    local num_service=0

    local OPTIND n 
    while getopts "n:" opt; do
        case $opt in
        n)
          local num_service="$OPTARG"          
          ;;
        esac
    done

    local path="os-services"

    keystone_get_endpoint nova
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "nova_list_services :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "nova_list_services :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.services | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "nova_list_services :: error obtaining services list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_service ]]; then
        log_output "nova_list_services :: failure, $count services returned, $num_service required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "nova_list_services :: success, $count services returned, $num_service required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "nova_list_services :: http status check failed"
        rc=1
    fi

    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
  
}

#
# Neutron
# 

# list neutron networks, optional parameter can be supplied as a limit
# -n num_network -- number of required agents (fail if fewer, default 0)
# -m max_network -- max number of networks to list (cannot be less than num_network, default 100)
function neutron_list_networks() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_networks"

    local max_network=100
    local num_network=0

    local OPTIND n m 
    while getopts "n:m:" opt; do
        case $opt in
        m)
          local max_network="$OPTARG"
          ;;
        n)
          local num_network="$OPTARG"          
          ;;
        esac
    done

    # if max networks is less than required we will always fail
    # so we need to max sure they're at least equal
    if [[ $max_network < $num_network ]]; then
        local max_network="$num_network"
    fi

    local path="v2.0/networks?limit=$max_network"

    keystone_get_endpoint neutron
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null


    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "neutron_list_networks :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "neutron_list_networks :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.networks | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output  "neutron_list_networks :: error obtaining network list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_network ]]; then
        log_output  "neutron_list_networks :: failure, $count networks returned, $num_network required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "neutron_list_networks :: success, $count networks returned, $num_network required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "neutron_list_networks :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

# list neutron agents
# -n num_agent -- number of required agents (fail if fewer, default 0)
function neutron_list_agents() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_agents"
    local num_agent=0

    local OPTIND n m 
    while getopts "n:" opt; do
        case $opt in
        n)
          local num_agent="$OPTARG"          
          ;;
        esac
    done

    local path="v2.0/agents"

    keystone_get_endpoint neutron
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "neutron_list_agents :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "neutron_list_agents :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.agents| length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output  "neutron_list_agents :: error obtaining agent list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_agent ]]; then
        log_output "neutron_list_agents :: failure, $count agents returned, $num_agent required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "neutron_list_agents :: success, $count agents returned, $num_agent required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "neutron_list_agents :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
    
}

#
# Cinder
# 
 
# list cinder volumes, optional parameter can be supplied as a limit
# -n num_volume -- number of required volumes (fail if fewer, default 0)
# -m max_volume -- max number of volumes to list (cannot be less than num_hypervisor, default 100)
function cinder_list_volumes() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_volumes"
    local max_volume=100
    local num_volume=0

    local OPTIND n m 
    while getopts "n:m:" opt; do
        case $opt in
        m)
          local max_volume="$OPTARG"
          ;;
        n)
          local num_volume="$OPTARG"          
          ;;
        esac
    done

    # if max volumes is less than required we will always fail
    # so we need to max sure they're at least equal
    if [[ $max_volume < $num_volume ]]; then
        local max_volume="$num_volume"
    fi

    local path="volumes?limit=$max_volume"

    keystone_get_endpoint cinderv3
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "cinder_list_volumes :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "cinder_list_volumes :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.volumes | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "cinder_list_volumes :: error obtaining volume list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_volume ]]; then
        log_output "cinder_list_volumes :: failure, $count volumes returned, $num_volume required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "cinder_list_volumes success, $count volumes returned, $num_volume required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "cinder_list_volumes :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

# list cinder services
# -n num_service -- number of required services (fail if fewer, default 0)
function cinder_list_services() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_services"
    local num_service=0

    local OPTIND n m 
    while getopts "n:m:" opt; do
        case $opt in
        n)
          local num_service="$OPTARG"          
          ;;
        esac
    done

    local path="os-services"

    keystone_get_endpoint cinderv3
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "cinder_list_services :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "cinder_list_services :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.services | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "cinder_list_services :: error obtaining services list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_service ]]; then
        log_output "cinder_list_services :: failure, $count services returned, $num_service required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "cinder_list_services :: success, $count services returned, $num_service required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "cinder_list_services :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

#
# Glance
# 

# list glance images, optional parameter can be supplied as a limit
# -n num_image -- number of required images (fail if fewer, default 0)
# -m max_image -- max number of images to list (cannot be less than num_image, default 100)
function glance_list_images() {
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_images"
    local max_image=100
    local num_image=0

    local OPTIND n m 
    while getopts "n:m:" opt; do
        case $opt in
        m)
          local max_image="$OPTARG"
          ;;
        n)
          local num_image="$OPTARG"          
          ;;
        esac
    done

    # if max images is less than required we will always fail
    # so we need to max sure they're at least equal
    if [[ $max_image < $num_image ]]; then
        local max_image="$num_image"
    fi

    local path="v2/images?limit=$max_image"

    keystone_get_endpoint glance
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "glance_list_images :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "glance_list_images :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq -r '.images | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "glance_list_images :: error obtaining image list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [ $count -lt $num_image ]; then
        log_output "glance_list_images :: failure, $count images returned, $num_image images required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "glance_list_images :: success, $count images returned, $num_image images required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "glance_list_images :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

#
# Placement
# 

# list placement resources providers
# -n num_provider -- number of required providers (fail if fewer, default 0)
function placement_list_providers() {
  
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_providers"
    local num_provider=0

    local OPTIND n m 
    while getopts "n:" opt; do
        case $opt in
        n)
          local num_provider="$OPTARG"          
          ;;
        esac
    done


    local path="resource_providers"

    keystone_get_endpoint placement
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "placement_list_providers :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "placement_list_providers :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq '.[] | length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "placement_list_providers :: error obtaining provider list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_provider ]]; then
        log_output "placement_list_providers :: failure, $count providers returned, $num_provider required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "placement_list_providers :: success, $count providers returned, $num_provider required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "placement_list_providers :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

#
# Resmgr
# 
 
# list resmgr hosts
# -n num_host -- number of required hosts (fail if fewer, default 0)
function resmgr_list_hosts() {
  
    local OPTIND n m 
    local orig_pipefail="$(set -o | awk '$1 == "pipefail" {print $2}')"
    set -o pipefail
    local rc=0
    local tmpd=$(mktemp -d)
    local filen="list_hosts"
    local num_host=0

    local OPTIND n m 
    while getopts "n:" opt; do
        case $opt in
        n)
          local num_host="$OPTARG"          
          ;;
        esac
    done

    local path="v1/hosts"

    keystone_get_endpoint resmgr
    curl --max-time $TIMEOUT -sS -k -i -H "X-Auth-Token: ${OS_TOKEN}" -H "Content-Type: application/json" "${SERVICE_URL}/${path}" >"$tmpd/$filen" 2>>"$tmpd"/stderr
    pushd $tmpd >/dev/null && csplit --prefix=$filen $filen /^$/ {*} >/dev/null

    if [ ! -f "$tmpd"/"$filen"01 -o ! -s "$tmpd"/"$filen"01 ]; then
        log_output "resmgr_list_hosts :: failure, no response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    elif ! jq < "$tmpd"/"$filen"01 >/dev/null 2>&1; then
        log_output "resmgr_list_hosts :: failure, invalid json response body returned"        
        print_response "$tmpd" "$filen"
        return 1
    else
        local count=$(jq 'length' "$tmpd"/"$filen"01)
    fi

    if [ $? -ne 0 ]; then
        log_output "resmgr_list_hosts :: error obtaining host list"
        print_response "$tmpd" "$filen"
        rc=1
    elif [[ $count < $num_host ]]; then
        log_output "resmgr_list_hosts :: failure, $count hosts returned, $num_host required"
        print_response "$tmpd" "$filen"
        rc=1
    else
        log_output "resmgr_list_hosts :: success, $count hosts returned, $num_host required"
    fi
    
    check_http_status "$tmpd"/"$filen"00
    if [ $? -ne 0 ]; then
        log_output "resmgr_list_hosts :: http status check failed"
        rc=1
    fi
          
    popd > /dev/null && rm -rf "$tmpd"
    if [ "$orig_pipefail" == "off" ]; then
        set +o pipefail
    fi

    return $rc
}

