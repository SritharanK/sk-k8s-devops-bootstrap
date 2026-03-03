#!/bin/bash
# -----------------------------------------------------------------------------
# Project: GitOps Kubernetes Platform Bootstrap
# Author : Sritharan K (https://www.skengineer.be)
# License: MIT
# -----------------------------------------------------------------------------

# Function to allow a port range in UFW
allow_port_range() {
  local port_range=$1
  local protocol=$2

  echo "Allowing port range $port_range/$protocol"
  sudo ufw allow $port_range/$protocol
}

# Allow custom SSH port (set SSH_PORT env or edit; default 22)
allow_port_range "${SSH_PORT:-22}" "tcp"

# Enable UFW if not already enabled
if ! sudo ufw status | grep -q "Status: active"; then
  echo "Enabling UFW"
  sudo ufw enable
fi


# Default rules
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow Jenkins default port
allow_port_range "8080" "tcp"

# Allow Jenkins custom port
allow_port_range "8081" "tcp"

# Kubernetes API Server
allow_port_range "6443" "tcp"

# etcd
allow_port_range "2379:2380" "tcp"

# Kubelet
allow_port_range "10250" "tcp"

# Kube-scheduler
allow_port_range "10251" "tcp"

# Kube-controller-manager
allow_port_range "10252" "tcp"

# CoreDNS
allow_port_range "53" "tcp"
allow_port_range "53" "udp"

# Kube-proxy
allow_port_range "10256" "tcp"

# Metrics-server
allow_port_range "443" "tcp"

# NodePort Services
allow_port_range "30000:32767" "tcp"
allow_port_range "30000:32767" "udp"

# Flannel
allow_port_range "8472" "udp"

# Calico
allow_port_range "179" "tcp"
allow_port_range "5473" "tcp"
allow_port_range "4789" "tcp"

# Weave Net
allow_port_range "6783" "tcp"
allow_port_range "6783" "udp"
allow_port_range "6784" "tcp"
allow_port_range "6784" "udp"

# Allow Kubernetes CIDR Pod IP range
sudo ufw allow out to 10.42.0.0/16
sudo ufw allow out to 10.43.0.0/16


# Istio (if used)
allow_port_range "15000:15999" "tcp"

sudo ufw deny out to 10.0.0.0/8
sudo ufw deny out to 172.16.0.0/12
sudo ufw deny out to 192.168.0.0/16
sudo ufw deny out to 100.64.0.0/10

# Reload UFW to apply changes
echo "Reloading UFW"
sudo ufw reload

# Show UFW status
echo "UFW status:"
sudo ufw status verbose
