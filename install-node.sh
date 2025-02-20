#!/bin/bash

export HOME=/root
export PRODUCT_NAME=openmesh
export BUILD_DIR=$HOME/$PRODUCT_NAME-install

mkdir -p $HOME/kube
mkdir -p /data/kafka

load_infra_config () {
  INFRA_CONFIG=$(cat "$HOME/infra_config.json")
}

function install_containerd() {
 cat <<EOF > /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
 modprobe overlay
 modprobe br_netfilter
 echo "Installing Containerd..."
 apt-get update
 apt-get install -y ca-certificates socat ebtables apt-transport-https cloud-utils prips containerd jq python3 ipcalc gpg
}

function enable_containerd() {
 systemctl daemon-reload
 systemctl enable containerd
 systemctl start containerd
}

function ceph_pre_check {
 apt install -y lvm2 ; \
 modprobe rbd
}

function bgp_routes {
 GATEWAY_IP=$(curl http://169.254.1.1/v1/ | jq -r ".network.addresses[] | select(.public == false) | .gateway")
 # TODO use metadata peer ips
 #ip route add 169.254.1.1 via $GATEWAY_IP
 ip route add 169.254.1.1 via $GATEWAY_IP
 sed -i.bak -E "/^\s+post-down route del -net 10\.0\.0\.0.* gw .*$/a \ \ \ \ up ip route add 169.254.255.1 via $GATEWAY_IP || true\n    up ip route add 169.254.255.2 via $GATEWAY_IP || true\n    down ip route del 169.254.255.1 || true\n    down ip route del 169.254.255.2 || true" /etc/network/interfaces
}

function install_kube_tools() {
 export kube_version=$(cat $HOME/infra_config.json | jq -r .kube_version) && \
 echo "Installing Kubeadm tools..." ;
 sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab
 swapoff -a
 apt-get update && apt-get install -y apt-transport-https
 curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
 echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
 apt-get update
 apt-get install -y kubelet=${kube_version} kubeadm=${kube_version} kubectl=${kube_version}
 echo "Waiting 180s to attempt to join cluster..."
}

function join_cluster() {
 export kube_token=$(cat $HOME/infra_config.json | jq -r .kube_token)
 echo "Attempting to join cluster"
 cat <<EOF > /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

 sysctl --system

 cat << EOF > /etc/kubeadm-join.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
nodeRegistration:
  kubeletExtraArgs:
    node-ip: $(curl -s http://169.254.1.1/v1/ | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .address')
discovery:
  bootstrapToken:
    apiServerEndpoint: $(ipcalc $(curl -s http://169.254.1.1/v1/ | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .parent_block.network')/$(curl -s http://169.254.1.1/v1/ | jq -r '.network.addresses[] | select(.public == false) | select(.management == true) | select(.address_family == 4) | .parent_block.cidr') | sed -n -e '/^HostMin/p' | awk '{print $2}'):6443
    token: ${kube_token}
    unsafeSkipCAVerification: true
EOF
  kubeadm join --config=/etc/kubeadm-join.yaml
}

install_containerd && \
enable_containerd && \
if [ "${storage}" = "ceph" ]; then
  ceph_pre_check
fi ; \
bgp_routes && \
install_kube_tools && \
sleep 180 && \
if [ "${ccm_enabled}" = "true" ]; then
  echo KUBELET_EXTRA_ARGS=\"--cloud-provider=external\" > /etc/default/kubelet
fi

join_cluster
