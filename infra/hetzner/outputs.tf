locals {
  server_nodes = [
    for name in local.server_names : {
      name        = name
      public_ipv4 = hcloud_server.server[name].ipv4_address
      public_ipv6 = hcloud_server.server[name].ipv6_address
      private_ip  = one([for attachment in hcloud_server.server[name].network : attachment.ip])
    }
  ]

  agent_nodes = [
    for name in local.agent_names : {
      name        = name
      public_ipv4 = hcloud_server.agent[name].ipv4_address
      public_ipv6 = hcloud_server.agent[name].ipv6_address
      private_ip  = one([for attachment in hcloud_server.agent[name].network : attachment.ip])
    }
  ]

  registration_address = hcloud_load_balancer_network.api.ip
}

output "ansible_inventory" {
  description = "Ansible inventory for the RKE2 roles. Write it with: tofu output -raw ansible_inventory > ../../ansible/inventories/reference/hosts.yml"
  value = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    admin_username       = var.admin_username
    node_cidrs           = [var.subnet_cidr]
    ssh_cidrs            = var.admin_cidrs
    api_cidrs            = var.admin_cidrs
    registration_address = local.registration_address
    api_endpoint         = var.load_balancer_public ? hcloud_load_balancer.api.ipv4 : local.registration_address
    tls_san_extra        = var.load_balancer_public ? [hcloud_load_balancer.api.ipv4, local.registration_address] : [local.registration_address]
    servers              = local.server_nodes
    agents               = local.agent_nodes
  })
}

output "load_balancer_ipv4" {
  description = "Public IPv4 of the API load balancer. Assigned even when load_balancer_public is false, but then nothing listens on it."
  value       = hcloud_load_balancer.api.ipv4
}

output "load_balancer_private_ip" {
  description = "Private IPv4 of the API load balancer in the cluster subnet."
  value       = hcloud_load_balancer_network.api.ip
}

output "registration_address" {
  description = "Fixed RKE2 registration address (load balancer private IP). Agents and joining servers use https://<address>:9345."
  value       = local.registration_address
}

output "servers" {
  description = "RKE2 server nodes: name to public and private addresses."
  value = {
    for node in local.server_nodes : node.name => {
      public_ipv4 = node.public_ipv4
      public_ipv6 = node.public_ipv6
      private_ip  = node.private_ip
    }
  }
}

output "agents" {
  description = "RKE2 agent nodes: name to public and private addresses."
  value = {
    for node in local.agent_nodes : node.name => {
      public_ipv4 = node.public_ipv4
      public_ipv6 = node.public_ipv6
      private_ip  = node.private_ip
    }
  }
}
