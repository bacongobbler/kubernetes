#!/bin/bash

# Copyright 2014 The Kubernetes Authors All rights reserved.
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

set -o errexit
set -o nounset
set -o pipefail

# Set the host name explicitly
# See: https://github.com/mitchellh/vagrant/issues/2430
hostnamectl set-hostname ${MASTER_NAME}

NETWORK_CONF_PATH=/etc/network/interfaces
if_to_edit=$( find ${NETWORK_CONF_PATH} | xargs grep -l VAGRANT-BEGIN )
NETWORK_IF_NAME=`echo ${if_to_edit} | awk -F- '{ print $3 }'`

function release_not_found() {
  echo "It looks as if you don't have a compiled version of Kubernetes.  If you" >&2
  echo "are running from a clone of the git repo, please run 'make quick-release'." >&2
  echo "Note that this requires having Docker installed.  If you are running " >&2
  echo "from a release tarball, something is wrong.  Look at " >&2
  echo "http://kubernetes.io/ for information on how to contact the development team for help." >&2
  exit 1
}

# Setup hosts file to support ping by hostname to each node in the cluster from apiserver
for (( i=0; i<${#NODE_NAMES[@]}; i++)); do
  node=${NODE_NAMES[$i]}
  ip=${NODE_IPS[$i]}
  if [ ! "$(cat /etc/hosts | grep $node)" ]; then
    echo "Adding $node to hosts file"
    echo "$ip $node" >> /etc/hosts
  fi
done
echo "127.0.0.1 localhost" >> /etc/hosts # enables cmds like 'kubectl get pods' on master.
echo "$MASTER_IP $MASTER_NAME" >> /etc/hosts

prepare-package-manager

# Configure the master network
if [ "${NETWORK_PROVIDER}" != "kubenet" ]; then
  provision-network-master
fi

write-salt-config kubernetes-master

# Generate and distribute a shared secret (bearer token) to
# apiserver and kubelet so that kubelet can authenticate to
# apiserver to send events.
known_tokens_file="/srv/salt-overlay/salt/kube-apiserver/known_tokens.csv"
if [[ ! -f "${known_tokens_file}" ]]; then

  mkdir -p /srv/salt-overlay/salt/kube-apiserver
  known_tokens_file="/srv/salt-overlay/salt/kube-apiserver/known_tokens.csv"
  (umask u=rw,go= ;
   echo "$KUBELET_TOKEN,kubelet,kubelet" > $known_tokens_file;
   echo "$KUBE_PROXY_TOKEN,kube_proxy,kube_proxy" >> $known_tokens_file;
   echo "$KUBE_BEARER_TOKEN,admin,admin" >> $known_tokens_file)

  mkdir -p /srv/salt-overlay/salt/kubelet
  kubelet_auth_file="/srv/salt-overlay/salt/kubelet/kubernetes_auth"
  (umask u=rw,go= ; echo "{\"BearerToken\": \"$KUBELET_TOKEN\", \"Insecure\": true }" > $kubelet_auth_file)

  create-salt-kubelet-auth
  create-salt-kubeproxy-auth
  # Generate tokens for other "service accounts".  Append to known_tokens.
  #
  # NB: If this list ever changes, this script actually has to
  # change to detect the existence of this file, kill any deleted
  # old tokens and add any new tokens (to handle the upgrade case).
  service_accounts=("system:scheduler" "system:controller_manager" "system:logging" "system:monitoring" "system:dns")
  for account in "${service_accounts[@]}"; do
    token=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
    echo "${token},${account},${account}" >> "${known_tokens_file}"
  done
fi


readonly BASIC_AUTH_FILE="/srv/salt-overlay/salt/kube-apiserver/basic_auth.csv"
if [ ! -e "${BASIC_AUTH_FILE}" ]; then
  mkdir -p /srv/salt-overlay/salt/kube-apiserver
  (umask 077;
    echo "${MASTER_PASSWD},${MASTER_USER},admin" > "${BASIC_AUTH_FILE}")
fi

install-salt

run-salt
