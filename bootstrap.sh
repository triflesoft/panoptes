#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

function update_file {
    NAME=$1
    FILE_URI=$2
    FILE_PATH=$3
    ETAG_PATH=$4

    if [ ! -f "$ETAG_PATH" ] || [ "$(($(date +%s) - $(stat -c %Y "$ETAG_PATH")))" -gt 500000 ]
    then
        if [ -f "$ETAG_PATH" ]
        then
            ETAG_OLD=$(cat $ETAG_PATH)
        else
            ETAG_OLD="-"
        fi

        ETAG_NEW=$(curl --silent --head --location $FILE_URI | grep -oP '(?<=^etag: ")[^"]+(?=")')

        if [[ "$ETAG_OLD" != "$ETAG_NEW" ]]
        then
            echo "$NAME is being downloaded..." >&2
            curl --location --output $FILE_PATH $FILE_URI
            echo -n $ETAG_NEW > $ETAG_PATH
            echo "$NAME has been downloaded" >&2
            echo "UPDATED"
            return
        else
            touch $ETAG_PATH
        fi
    fi

    echo "SKIPPED"
}

function update_tar_gz_file {
    NAME=$1
    FILE_URI=$2
    FILE_PATH=$3
    ETAG_PATH=$4
    DIRECTORY_PATH=$5

    RESULT=$(update_file $NAME $FILE_URI $FILE_PATH $ETAG_PATH)

    if [ "$RESULT" == "UPDATED" ]
    then
        echo "$NAME is being extracted..." >&2
        mkdir -p $DIRECTORY_PATH
        tar --verbose --file $FILE_PATH --directory $DIRECTORY_PATH --extract --ungzip --overwrite --strip-components 1
        echo "$NAME has been extracted" >&2
    fi
}

function do_bootstrap {
    if [ "$#" -ne 1 ]; then
        echo "Usage:" >&2
        echo "  $0 configuration.json" >&2
        exit 1
    fi

    CONF_PATH=$(realpath --canonicalize-existing --logical $1)

    cd "$(dirname "$0")"

    echo $CONF_PATH

    if [ ! -f "$CONF_PATH" ]
    then
        echo "Server configration $CONF_PATH does not exists." >&2
    fi

    cat $CONF_PATH | jq --indent 4

    SSH_HOSTNAME=$(cat $CONF_PATH | jq '.ssh.hostname' --raw-output)
    SSH_USERNAME=$(cat $CONF_PATH | jq '.ssh.username' --raw-output)
    SSH_IDENTITY=$(cat $CONF_PATH | jq '.ssh?.identity? // "--"' --raw-output)

    echo "SSH_HOSTNAME = $SSH_HOSTNAME"
    echo "SSH_USERNAME = $SSH_USERNAME"
    echo "SSH_IDENTITY = $SSH_IDENTITY"

    SUFFIX="_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

    if [ $SSH_IDENTITY == "--" ]
    then
        scp -p $SELF_FILE_PATH $SSH_USERNAME@$SSH_HOSTNAME:/tmp/temp$SUFFIX.sh
        scp -p $CONF_PATH      $SSH_USERNAME@$SSH_HOSTNAME:/tmp/temp$SUFFIX.json
        ssh                                     $SSH_USERNAME@$SSH_HOSTNAME "sudo chmod 755 /tmp/temp$SUFFIX.sh && sudo /tmp/temp$SUFFIX.sh /tmp/temp$SUFFIX.json"
    else
        scp -i $SSH_IDENTITY -p $SELF_FILE_PATH $SSH_USERNAME@$SSH_HOSTNAME:/tmp/temp$SUFFIX.sh
        scp -i $SSH_IDENTITY -p $CONF_PATH      $SSH_USERNAME@$SSH_HOSTNAME:/tmp/temp$SUFFIX.json
        ssh -i $SSH_IDENTITY                    $SSH_USERNAME@$SSH_HOSTNAME "sudo chmod 755 /tmp/temp$SUFFIX.sh && sudo /tmp/temp$SUFFIX.sh /tmp/temp$SUFFIX.json"
    fi
}

function do_provision {
    if [ "$#" -ne 1 ]; then
        echo "Usage:" >&2
        echo "  $0 configuration.json" >&2
        exit 1
    fi

    id

    OS_CODE=$(cat /etc/os-release | grep -Po '(?<=ID=")([a-z]+)(?=")')
    OS_FAMILY=$(cat /etc/os-release | grep -Po '(?<=ID_LIKE=")([a-z ]+)(?=")')
    OS_VERSION=$(cat /etc/os-release | grep -Po '(?<=VERSION_ID=")([0-9\.]+)(?=")')

    echo "OS_CODE    = $OS_CODE"
    echo "OS_FAMILY  = $OS_FAMILY"
    echo "OS_VERSION = $OS_VERSION"

    if [[ " $OS_FAMILY " == *" rhel "* ]]
    then
        OS_CODE="rhel"
    fi

    OS_ID="$OS_CODE-$OS_VERSION"

    echo "OS_ID      = $OS_ID"

    UV_VERSION="0.9.27"
    CPU_ARCHITECTURE=$(uname --machine | tr '[:upper:]' '[:lower:]')
    OS_FLAVOR=$(uname --kernel-name | tr '[:upper:]' '[:lower:]')

    UV_ARCHIVE_FILE_URI="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$CPU_ARCHITECTURE-unknown-$OS_FLAVOR-gnu.tar.gz"
    UV_ARCHIVE_FILE_PATH="_uv.tar.gz"
    UV_ARCHIVE_ETAG_PATH="_uv.etag"
    UV_DIRECTORY_PATH="_uv"

    update_tar_gz_file "UV" $UV_ARCHIVE_FILE_URI $UV_ARCHIVE_FILE_PATH $UV_ARCHIVE_ETAG_PATH $UV_DIRECTORY_PATH

    case $OS_ID in
        rhel-10.1)
            dnf --assumeyes --quiet remove firewalld
            dnf --assumeyes --quiet install epel-release
            crb enable
            dnf --assumeyes --quiet update
            dnf --assumeyes --quiet install certbot conntrack-tools curl dnf-automatic dnsmasq freeradius freeradius-rest freeradius-utils git glibc-langpack-en htop iotop jq lsof nano nftables openvpn openssl patch policycoreutils-python-utils polkit python3-certbot-dns-route53 rsync strongswan strongswan-sqlite tar telnet tmux traceroute unzip valkey wget
            ;;
    esac

    mkdir -p /usr/local/bin

    cp --verbose --force --no-preserve=ownership "$UV_DIRECTORY_PATH/uv"  "/usr/local/bin/uv"
    cp --verbose --force --no-preserve=ownership "$UV_DIRECTORY_PATH/uvx" "/usr/local/bin/uvx"
    chmod 755 "/usr/local/bin/uv" "/usr/local/bin/uvx"

    chcon --user=system_u --role=object_r --type=bin_t --recursive /usr/local/bin
    restorecon -R /usr/local/bin
    ls -laZ /usr/local/bin/
    /usr/local/bin/uv --version

    rm --recursive --force /etc/panoptes
    mkdir -p /etc/panoptes
    cp --verbose --force --no-preserve=ownership "$1" "/etc/panoptes/panoptes.json"
    chcon --user=system_u --role=object_r --type=etc_t --recursive /etc/panoptes
    restorecon -R /etc/panoptes
    ls -laZ /etc/panoptes/

    rm --recursive --force /opt/panoptes
    mkdir -p /opt/panoptes
    curl --output /tmp/panoptes-provision.zip --location https://github.com/triflesoft/panoptes-provision/archive/refs/heads/main.zip
    unzip -oK /tmp/panoptes-provision.zip -d /tmp/panoptes-provision
    mv --force /tmp/panoptes-provision/panoptes-main/* /opt/panoptes-provision
    ls -laZ /opt/panoptes-provision/

    /opt/panoptes/provision/provision-$OS_CODE.sh
}

SELF_FILE_PATH=$(realpath $0)
SELF_FILE_NAME="${SELF_FILE_PATH##*/}"
SELF_BASE_NAME="${SELF_FILE_NAME%%.*}"

case $SELF_BASE_NAME in
    bootstrap)
        do_bootstrap "$@"
        ;;
    temp_*)
        do_provision "$@"
        ;;
esac
