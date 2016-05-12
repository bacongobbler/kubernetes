#!/bin/bash

# Copyright 2015 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# provision-network-master configures flannel on the master
function provision-network-master {

  echo "Provisioning network on master"

  FLANNEL_ETCD_URL="http://${MASTER_IP}:4379"

  # Install etcd for flannel data
  if ! which etcd >/dev/null 2>&1; then

    curl -sL https://github.com/coreos/etcd/releases/download/v2.3.3/etcd-v2.3.3-linux-amd64.tar.gz -o etcd-v2.3.3-linux-amd64.tar.gz
    tar xzf etcd-v2.3.3-linux-amd64.tar.gz
    mv etcd-v2.3.3-linux-amd64/etcd etcd-v2.3.3-linux-amd64/etcdctl /usr/bin
    rm -rf etcd-v2.3.3-linux-amd64.tar.gz etcd-v2.3.3-linux-amd64

    # install etcd user and etcd data dir
    ETCD_DATA_DIR="/var/lib/etcd/flannel.etcd"
    useradd etcd
    mkdir -p ${ETCD_DATA_DIR}
    chown -R etcd:etcd ${ETCD_DATA_DIR}


    # Modify etcd configuration for flannel data
    mkdir /etc/etcd
    cat <<EOF >/etc/etcd/etcd.conf
ETCD_NAME=flannel
ETCD_DATA_DIR="/var/lib/etcd/flannel.etcd"
ETCD_LISTEN_PEER_URLS="http://${MASTER_IP}:4380"
ETCD_LISTEN_CLIENT_URLS="http://${MASTER_IP}:4379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${MASTER_IP}:4380"
ETCD_INITIAL_CLUSTER="flannel=http://${MASTER_IP}:4380"
ETCD_ADVERTISE_CLIENT_URLS="${FLANNEL_ETCD_URL}"
EOF

    cat <<EOF >/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
EnvironmentFile=-/etc/etcd/etcd.conf
User=etcd
# set GOMAXPROCS to number of processors
ExecStart=/bin/bash -c "GOMAXPROCS=\$(nproc) /usr/bin/etcd --name=\"\${ETCD_NAME}\" --data-dir=\"\${ETCD_DATA_DIR}\" --listen-client-urls=\"\${ETCD_LISTEN_CLIENT_URLS}\""
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # Enable and start etcd
    systemctl enable etcd
    systemctl start etcd

  fi

  # Install flannel for overlay
  if ! which flanneld >/dev/null 2>&1; then

    curl -sL https://github.com/coreos/flannel/releases/download/v0.5.5/flannel-0.5.5-linux-amd64.tar.gz -o flannel-0.5.5-linux-amd64.tar.gz
    tar xzf flannel-0.5.5-linux-amd64.tar.gz
    mv flannel-0.5.5/flanneld /usr/bin
    mv flannel-0.5.5/mk-docker-opts.sh /usr/bin
    rm -rf flannel-0.5.5-linux-amd64.tar.gz flannel-0.5.5

    cat <<EOF >/etc/flannel-config.json
{
    "Network": "${CONTAINER_SUBNET}",
    "SubnetLen": 24,
    "Backend": {
        "Type": "udp",
        "Port": 8285
     }
}
EOF

    # Import default configuration into etcd for master setup
    etcdctl -C ${FLANNEL_ETCD_URL} set /coreos.com/network/config < /etc/flannel-config.json

    # Configure local daemon to speak to master
    NETWORK_CONF_PATH=/etc/network/interfaces
    if_to_edit=$( find ${NETWORK_CONF_PATH} | xargs grep -l VAGRANT-BEGIN )
    NETWORK_IF_NAME=`echo ${if_to_edit} | awk -F- '{ print $3 }'`
    cat <<EOF >/etc/default/flanneld
FLANNEL_ETCD="${FLANNEL_ETCD_URL}"
FLANNEL_ETCD_KEY="/coreos.com/network"
FLANNEL_OPTIONS="-iface=${NETWORK_IF_NAME} --ip-masq"
EOF

    cat <<EOF >/lib/systemd/system/flanneld.service
[Unit]
Description=Flanneld overlay address etcd agent
After=network.target
After=network-online.target
Wants=network-online.target
After=etcd.service
Before=docker.service

[Service]
Type=notify
EnvironmentFile=/etc/default/flanneld
EnvironmentFile=-/etc/default/docker-network
ExecStart=/usr/bin/flanneld -etcd-endpoints=\${FLANNEL_ETCD} -etcd-prefix=\${FLANNEL_ETCD_KEY} \$FLANNEL_OPTIONS
ExecStartPost=/usr/bin/mk-docker-opts.sh -k DOCKER_NETWORK_OPTIONS -d /run/flannel/docker
Restart=on-failure

[Install]
WantedBy=multi-user.target
RequiredBy=docker.service
EOF

    # Start flannel
    systemctl enable flanneld
    systemctl start flanneld
  fi

  echo "Network configuration verified"
}
