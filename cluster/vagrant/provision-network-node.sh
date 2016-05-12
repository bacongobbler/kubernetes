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

# provision-network-node configures flannel on the node
function provision-network-node {

  echo "Provisioning network on node"

  FLANNEL_ETCD_URL="http://${MASTER_IP}:4379"

  # Install flannel for overlay
  if ! which flanneld >/dev/null 2>&1; then

    curl -sL https://github.com/coreos/flannel/releases/download/v0.5.5/flannel-0.5.5-linux-amd64.tar.gz -o flannel-0.5.5-linux-amd64.tar.gz
    tar xzf flannel-0.5.5-linux-amd64.tar.gz
    mv flannel-0.5.5/flanneld /usr/bin
    mv flannel-0.5.5/mk-docker-opts.sh /usr/bin
    rm -rf flannel-0.5.5-linux-amd64.tar.gz flannel-0.5.5

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
