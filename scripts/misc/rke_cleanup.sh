#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------

# Function to remove directories and files
cleanup() {
  local target=$1

  if [ -e "$target" ]; then
    echo "Removing $target"
    sudo rm -rf "$target"
  else
    echo "$target does not exist"
  fi
}

# Stop and remove any remaining Docker containers related to Kubernetes
echo "Stopping and removing Kubernetes-related Docker containers"
containers=$(sudo docker ps -a --filter "name=k8s_" --format "{{.ID}}")
if [ -n "$containers" ]; then
  sudo docker stop $containers
  sudo docker rm $containers
else
  echo "No Kubernetes-related Docker containers found"
fi

# Remove Kubernetes-related Docker images
echo "Removing Kubernetes-related Docker images"
images=$(sudo docker images --filter "reference=k8s.gcr.io/*" --format "{{.ID}}")
if [ -n "$images" ]; then
  sudo docker rmi $images
else
  echo "No Kubernetes-related Docker images found"
fi

# Remove Kubernetes-related directories and files
echo "Cleaning up Kubernetes-related directories and files"
cleanup "/etc/kubernetes"
cleanup "/var/lib/etcd"
cleanup "/var/lib/kubelet"
cleanup "/var/lib/rancher"
cleanup "/var/log/containers"
cleanup "/var/log/pods"
cleanup "/var/run/calico"
cleanup "/var/lib/cni"
cleanup "/opt/cni/bin"
cleanup "/etc/cni/net.d"

# Remove any additional network interfaces created by CNI plugins
echo "Cleaning up additional network interfaces created by CNI plugins"
interfaces=$(ip link show | grep cni | awk '{print $2}' | sed 's/://')
for interface in $interfaces; do
  sudo ip link delete $interface
done

# Clean up iptables rules related to Kubernetes
echo "Cleaning up iptables rules related to Kubernetes"
# sudo iptables -F
# sudo iptables -X
# sudo iptables -t nat -F
# sudo iptables -t nat -X
# sudo iptables -t mangle -F
# sudo iptables -t mangle -X
# sudo iptables -t raw -F
# sudo iptables -t raw -X

# Clean up IPVS rules
echo "Cleaning up IPVS rules"
sudo ipvsadm --clear