# Offline tests for the Hetzner example. The hcloud provider is mocked, so no API token, network
# access or cloud resources are needed: `tofu init -backend=false && tofu test`.
#
# What this proves: resource counts, firewall rules, load balancer targets and services, the
# rendered Ansible inventory, and the input validations. What it cannot prove: that Hetzner accepts
# the server types, images and locations, or that the cluster works; that needs a real `tofu apply`.

mock_provider "hcloud" {
  # The provider exposes IDs as strings but many arguments that take them are numbers, so the
  # mocked IDs must be numeric strings.
  mock_resource "hcloud_network" {
    defaults = { id = "1001" }
  }
  mock_resource "hcloud_network_subnet" {
    defaults = { id = "1001-10.20.0.0/24" }
  }
  mock_resource "hcloud_ssh_key" {
    defaults = { id = "2001" }
  }
  mock_resource "hcloud_firewall" {
    defaults = { id = "3001" }
  }
  mock_resource "hcloud_placement_group" {
    defaults = { id = "4001" }
  }
  mock_resource "hcloud_server" {
    defaults = {
      id           = "5001"
      ipv4_address = "203.0.113.10"
      ipv6_address = "2001:db8::10"
    }
  }
  mock_resource "hcloud_load_balancer" {
    defaults = {
      id   = "6001"
      ipv4 = "198.51.100.10"
      ipv6 = "2001:db8::100"
    }
  }
}

variables {
  hcloud_token   = "mocked-provider-ignores-this-value"
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOfflineTestKeyOnlyNotUsedForAnyHost test@example.com"
  admin_cidrs    = ["203.0.113.0/24"]
}

run "reference_topology" {
  command = apply

  assert {
    condition     = length(hcloud_server.server) == 3 && length(hcloud_server.agent) == 2
    error_message = "The default topology must have three servers and two agents."
  }

  assert {
    condition = [for name in sort(keys(hcloud_server.server)) : one(hcloud_server.server[name].network).ip] == [
      "10.20.0.10", "10.20.0.11", "10.20.0.12",
    ]
    error_message = "Servers must get fixed private addresses from host 10 upward."
  }

  assert {
    condition     = alltrue([for s in hcloud_server.server : s.placement_group_id == tonumber(hcloud_placement_group.servers.id)])
    error_message = "Every server must be in the spread placement group."
  }

  assert {
    condition = alltrue(concat(
      [for s in hcloud_server.server : contains(s.firewall_ids, tonumber(hcloud_firewall.nodes.id))],
      [for s in hcloud_server.agent : contains(s.firewall_ids, tonumber(hcloud_firewall.nodes.id))],
    ))
    error_message = "The firewall must be attached to every node at creation."
  }

  assert {
    condition     = length(hcloud_firewall.nodes.rule) == 2
    error_message = "The firewall must hold exactly two inbound rules (SSH and ICMP)."
  }

  assert {
    condition = length([
      for r in hcloud_firewall.nodes.rule : r
      if r.direction == "in" && r.protocol == "tcp" && r.port == "22" && toset(r.source_ips) == toset(["203.0.113.0/24"])
    ]) == 1
    error_message = "SSH must be open only to the admin CIDRs."
  }

  assert {
    condition     = length([for r in hcloud_firewall.nodes.rule : r if r.protocol == "tcp" && r.port != "22"]) == 0
    error_message = "No TCP port other than SSH may be open on the public interface."
  }

  assert {
    condition     = length(hcloud_load_balancer_target.server) == 3
    error_message = "Every server must be a load balancer target."
  }

  assert {
    condition     = alltrue([for t in hcloud_load_balancer_target.server : t.use_private_ip])
    error_message = "Load balancer targets must use the private network."
  }

  assert {
    condition = (
      hcloud_load_balancer_service.kube_api.listen_port == 6443 &&
      hcloud_load_balancer_service.rke2_supervisor.listen_port == 9345
    )
    error_message = "The load balancer must serve the Kubernetes API (6443) and the RKE2 supervisor (9345)."
  }

  assert {
    condition     = hcloud_load_balancer_network.api.ip == "10.20.0.254" && hcloud_load_balancer_network.api.enable_public_interface
    error_message = "The load balancer must sit on host 254 of the subnet with its public interface enabled by default."
  }

  assert {
    condition = (
      yamldecode(output.ansible_inventory).all.vars.infra_registration_address == "10.20.0.254" &&
      yamldecode(output.ansible_inventory).all.vars.rke2_api_endpoint == "198.51.100.10" &&
      yamldecode(output.ansible_inventory).all.vars.rke2_tls_san_extra == ["198.51.100.10", "10.20.0.254"] &&
      yamldecode(output.ansible_inventory).all.vars.firewall_node_cidrs == ["10.20.0.0/24"] &&
      yamldecode(output.ansible_inventory).all.vars.firewall_ssh_cidrs == ["203.0.113.0/24"] &&
      yamldecode(output.ansible_inventory).all.vars.ansible_user == "ops"
    )
    error_message = "The inventory vars must carry the registration address, API endpoint, SANs, CIDRs and admin user."
  }

  assert {
    condition = (
      keys(yamldecode(output.ansible_inventory).all.children.k8s_cluster.children.rke2_servers.hosts) ==
      ["reference-server-1", "reference-server-2", "reference-server-3"] &&
      keys(yamldecode(output.ansible_inventory).all.children.k8s_cluster.children.rke2_agents.hosts) ==
      ["reference-agent-1", "reference-agent-2"]
    )
    error_message = "The inventory must list every server under rke2_servers and every agent under rke2_agents."
  }

  assert {
    condition = (
      yamldecode(output.ansible_inventory).all.children.k8s_cluster.children.rke2_servers.hosts["reference-server-2"].rke2_node_ip == "10.20.0.11" &&
      yamldecode(output.ansible_inventory).all.children.k8s_cluster.children.rke2_agents.hosts["reference-agent-1"].rke2_node_ip == "10.20.0.20" &&
      yamldecode(output.ansible_inventory).all.children.k8s_cluster.children.rke2_servers.hosts["reference-server-1"].ansible_host == "203.0.113.10"
    )
    error_message = "Inventory hosts must carry the public address as ansible_host and the private address as rke2_node_ip."
  }
}

run "private_api_single_server" {
  command = apply

  variables {
    server_count         = 1
    agent_count          = 0
    load_balancer_public = false
  }

  assert {
    condition     = length(hcloud_server.server) == 1 && length(hcloud_server.agent) == 0
    error_message = "server_count and agent_count must drive the node counts."
  }

  assert {
    condition     = !hcloud_load_balancer_network.api.enable_public_interface
    error_message = "load_balancer_public = false must disable the public interface."
  }

  assert {
    condition = (
      yamldecode(output.ansible_inventory).all.vars.rke2_api_endpoint == "10.20.0.254" &&
      yamldecode(output.ansible_inventory).all.vars.rke2_tls_san_extra == ["10.20.0.254"] &&
      yamldecode(output.ansible_inventory).all.children.k8s_cluster.children.rke2_agents.hosts == {}
    )
    error_message = "A private API must render the private address as endpoint and an empty agents group."
  }
}

run "rejects_ssh_from_anywhere" {
  command = plan

  variables {
    admin_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_cidrs]
}

run "rejects_even_server_count" {
  command = plan

  variables {
    server_count = 2
  }

  expect_failures = [var.server_count]
}

run "rejects_rsa_key" {
  command = plan

  variables {
    ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC test@example.com"
  }

  expect_failures = [var.ssh_public_key]
}
