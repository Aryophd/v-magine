#!/bin/bash
set -e

config_network_adapter () {
    local IFACE=$1
    local IPADDR=$2
    local NETMASK=$3

    cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$IFACE
DEVICE="$IFACE"
BOOTPROTO="none"
MTU="1500"
ONBOOT="yes"
IPADDR="$IPADDR"
NETMASK="$NETMASK"
EOF
}

get_interface_ipv4 () {
    local IFACE=$1
    /usr/sbin/ip addr show $IFACE | /usr/bin/sed -n 's/^\s*inet \([0-9.]*\)\/\([0-9]*\)\s* brd \([0-9.]*\).*$/\1 \2 \3/p'
}

set_interface_static_ipv4_from_dhcp () {
    local IFACE=$1
    local IPADDR
    local PREFIX
    local NETMASK
    local BCAST

    read IPADDR PREFIX BCAST <<< `get_interface_ipv4 $IFACE`
    NETMASK=`/usr/bin/ipcalc -4 --netmask $IPADDR/$PREFIX | /usr/bin/sed -n  's/^\NETMASK=\(.*\).*$/\1/p'`

    config_network_adapter $SSHUSER_HOST $IFACE $IPADDR $NETMASK
}

config_ovs_network_adapter () {
    local ADAPTER=$1

    cat << EOF > /etc/sysconfig/network-scripts/ifcfg-$ADAPTER
DEVICE="$ADAPTER"
BOOTPROTO="none"
MTU="1500"
ONBOOT="yes"
EOF
}

exec_with_retry () {
    local MAX_RETRIES=$1
    local INTERVAL=$2

    local COUNTER=0
    while [ $COUNTER -lt $MAX_RETRIES ]; do
        local EXIT=0
        eval '${@:3}' || EXIT=$?
        if [ $EXIT -eq 0 ]; then
            return 0
        fi
        let COUNTER=COUNTER+1

        if [ -n "$INTERVAL" ]; then
            sleep $INTERVAL
        fi
    done
    return $EXIT
}

function ovs_bridge_exists() {
    local BRIDGE_NAME=$1
    /usr/bin/ovs-vsctl show | grep "^\s*Bridge $BRIDGE_NAME\$" > /dev/null
}

function rdo_cleanup() {
    yum remove -y mariadb
    yum remove -y "*openstack*" "*nova*" "*neutron*" "*keystone*" "*glance*" "*cinder*" "*swift*" "*heat*" "*rdo-release*"

    rm -rf /etc/nagios /etc/yum.repos.d/packstack_* /root/.my.cnf \
    /var/lib/mysql/ /var/lib/glance /var/lib/nova /etc/nova /etc/neutron /etc/swift \
    /srv/node/device*/* /var/lib/cinder/ /etc/rsync.d/frag* \
    /var/cache/swift /var/log/keystone || true

    vgremove -f cinder-volumes || true
}

rdo_cleanup

if ! /usr/bin/rpm -q epel-release > /dev/null
then
    exec_with_retry 5 0 /usr/bin/rpm -Uvh http://download.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-2.noarch.rpm
fi

ANSWER_FILE=packstack-answers.txt
MGMT_IFACE=eth1
DATA_IFACE=eth2
EXT_IFACE=eth3
OVS_DATA_BRIDGE=br-data
OVS_EXT_BRIDGE=br-ex
NTP_HOSTS=0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org

set_interface_static_ipv4_from_dhcp $MGMT_IFACE
/usr/sbin/ifup $MGMT_IFACE
config_ovs_network_adapter $DATA_IFACE
/usr/sbin/ifup $DATA_IFACE
config_ovs_network_adapter $EXT_IFACE
/usr/sbin/ifup $EXT_IFACE

read HOST_IP NETMASK_BITS BCAST  <<< `get_interface_ipv4 $MGMT_IFACE`

exec_with_retry 5 0 /usr/bin/yum update -y

if ! /usr/bin/rpm -q rdo-release > /dev/null
then
    exec_with_retry 5 0 /usr/bin/yum install -y https://rdo.fedorapeople.org/rdo-release.rpm
fi

exec_with_retry 5 0 /usr/bin/yum install -y openstack-packstack
exec_with_retry 5 0 /usr/bin/yum install openstack-utils -y

/usr/bin/packstack --gen-answer-file=$ANSWER_FILE

openstack-config --set $ANSWER_FILE general CONFIG_CONTROLLER_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_COMPUTE_HOSTS $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_NETWORK_HOSTS $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_STORAGE_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_AMQP_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_MARIADB_HOST $HOST_IP
openstack-config --set $ANSWER_FILE general CONFIG_MONGODB_HOST $HOST_IP

openstack-config --set $ANSWER_FILE general CONFIG_USE_EPEL y
openstack-config --set $ANSWER_FILE general CONFIG_HEAT_INSTALL y
#openstack-config --set $ANSWER_FILE general CONFIG_HEAT_CFN_INSTALL y
#openstack-config --set $ANSWER_FILE general CONFIG_HEAT_CLOUDWATCH_INSTALL y

openstack-config --set $ANSWER_FILE general CONFIG_NOVA_NETWORK_PUBIF $EXT_IFACE
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_TYPE_DRIVERS vlan
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_TENANT_NETWORK_TYPES vlan
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_MECHANISM_DRIVERS openvswitch,hyperv
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_ML2_VLAN_RANGES physnet1:500:2000
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS physnet1:$OVS_DATA_BRIDGE
openstack-config --set $ANSWER_FILE general CONFIG_NEUTRON_OVS_BRIDGE_IFACES $OVS_DATA_BRIDGE:$DATA_IFACE
openstack-config --set $ANSWER_FILE general CONFIG_NTP_SERVERS $NTP_HOSTS

exec_with_retry 5 0 /usr/bin/yum install -y openvswitch
/bin/systemctl start openvswitch.service

if ovs_bridge_exists $OVS_DATA_BRIDGE
then
    /usr/bin/ovs-vsctl del-br $OVS_DATA_BRIDGE
fi

/usr/bin/ovs-vsctl add-br $OVS_DATA_BRIDGE
/usr/bin/ovs-vsctl add-port $OVS_DATA_BRIDGE $DATA_IFACE

if ovs_bridge_exists $OVS_EXT_BRIDGE
then
    /usr/bin/ovs-vsctl del-br $OVS_EXT_BRIDGE
fi

/usr/bin/ovs-vsctl add-br $OVS_EXT_BRIDGE
/usr/bin/ovs-vsctl add-port $OVS_EXT_BRIDGE $EXT_IFACE

exec_with_retry 5 0 /usr/bin/packstack --answer-file=$ANSWER_FILE

# Disable nova-compute on this host
source /root/keystonerc_admin
exec_with_retry 5 0 /usr/bin/nova service-disable $(hostname) nova-compute
/bin/systemctl disable openstack-nova-compute.service

/usr/sbin/iptables -I INPUT -i $MGMT_IFACE -p tcp --dport 3260 -j ACCEPT
/usr/sbin/iptables -I INPUT -i $MGMT_IFACE -p tcp --dport 5672 -j ACCEPT
/usr/sbin/iptables -I INPUT -i $MGMT_IFACE -p tcp --dport 9696 -j ACCEPT
/usr/sbin/iptables -I INPUT -i $MGMT_IFACE -p tcp --dport 9292 -j ACCEPT
/usr/sbin/iptables -I INPUT -i $MGMT_IFACE -p tcp --dport 8776 -j ACCEPT
/usr/sbin/service iptables save

echo "Done!"