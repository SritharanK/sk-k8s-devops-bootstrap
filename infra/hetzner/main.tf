locals {
  common_labels = merge(var.labels, {
    cluster = var.cluster_name
  })

  # Ordered name lists; the inventory renders hosts in this order.
  server_names = [for i in range(var.server_count) : format("%s-server-%d", var.cluster_name, i + 1)]
  agent_names  = [for i in range(var.agent_count) : format("%s-agent-%d", var.cluster_name, i + 1)]

  # Fixed private addresses keep the inventory, the RKE2 node IPs and the
  # load balancer address stable across re-applies and node replacements.
  servers = {
    for i, name in local.server_names : name => {
      private_ip = cidrhost(var.subnet_cidr, 10 + i)
    }
  }

  agents = {
    for i, name in local.agent_names : name => {
      private_ip = cidrhost(var.subnet_cidr, 20 + i)
    }
  }

  load_balancer_private_ip = cidrhost(var.subnet_cidr, 254)

  # RKE2 defaults: cluster-cidr 10.42.0.0/16 and service-cidr 10.43.0.0/16.
  # Two ranges overlap when one of them contains the other's first address.
  rke2_default_cidrs = "10.42.0.0/15"
  network_overlaps_rke2_defaults = (
    cidrhost("${cidrhost(local.rke2_default_cidrs, 0)}/${split("/", var.network_cidr)[1]}", 0) == cidrhost(var.network_cidr, 0) ||
    cidrhost("${cidrhost(var.network_cidr, 0)}/${split("/", local.rke2_default_cidrs)[1]}", 0) == cidrhost(local.rke2_default_cidrs, 0)
  )

  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_username = var.admin_username
    ssh_public_key = var.ssh_public_key
  })
}

# A warning, not an error: the rke2 role may set other cluster and service CIDRs.
check "network_vs_rke2_defaults" {
  assert {
    condition     = !local.network_overlaps_rke2_defaults
    error_message = "network_cidr ${var.network_cidr} overlaps the RKE2 default cluster and service CIDRs (10.42.0.0/16, 10.43.0.0/16). Pick another range or change the RKE2 CIDRs."
  }
}

# -----------------------------------------------------------------------------
# Private network
# -----------------------------------------------------------------------------
resource "hcloud_network" "this" {
  name     = var.cluster_name
  ip_range = var.network_cidr
  labels   = local.common_labels
}

# Subnet type "server" is deprecated by Hetzner and equivalent to "cloud".
resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_cidr
}

# -----------------------------------------------------------------------------
# Access
# -----------------------------------------------------------------------------
resource "hcloud_ssh_key" "admin" {
  name       = "${var.cluster_name}-admin"
  public_key = var.ssh_public_key
  labels     = local.common_labels
}

# Hetzner Cloud Firewalls filter the public interfaces only. Traffic inside
# the private network, including load balancer to node traffic, is not
# filtered here; the host nftables rules from the Ansible firewall role cover
# the cluster ports. Inbound traffic that matches no rule is dropped; outbound
# traffic is allowed because this firewall defines no outbound rule.
resource "hcloud_firewall" "nodes" {
  name   = "${var.cluster_name}-nodes"
  labels = local.common_labels

  rule {
    description = "SSH from admin networks"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
  }

  rule {
    description = "ICMP for path MTU discovery and diagnostics"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

# Spread places every server on a different physical host, so one host
# failure costs at most one etcd member.
resource "hcloud_placement_group" "servers" {
  name   = "${var.cluster_name}-servers"
  type   = "spread"
  labels = merge(local.common_labels, { role = "server" })
}

# -----------------------------------------------------------------------------
# Nodes
# -----------------------------------------------------------------------------
resource "hcloud_server" "server" {
  for_each = local.servers

  name               = each.key
  server_type        = var.server_type
  image              = var.image
  location           = var.location
  placement_group_id = hcloud_placement_group.servers.id
  firewall_ids       = [hcloud_firewall.nodes.id]
  ssh_keys           = [hcloud_ssh_key.admin.id]
  user_data          = local.cloud_init
  labels             = merge(local.common_labels, { role = "server" })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # subnet_id references the subnet, so the server waits for it; no
  # explicit depends_on is needed.
  network {
    subnet_id = hcloud_network_subnet.nodes.id
    ip        = each.value.private_ip
    # Empty list avoids a detach and re-attach of the network on every apply
    # (terraform-provider-hcloud issue 650).
    alias_ips = []
  }

  # user_data, ssh_keys and image only take effect at creation, and the
  # provider replaces the server when they change. Ignoring them keeps a
  # cloud-init tweak, a rotated admin key or a new default image from
  # destroying a running etcd member. Roll such changes out node by node with
  # "tofu apply -replace=...".
  lifecycle {
    ignore_changes = [user_data, ssh_keys, image]
  }
}

resource "hcloud_server" "agent" {
  for_each = local.agents

  name         = each.key
  server_type  = var.agent_type
  image        = var.image
  location     = var.location
  firewall_ids = [hcloud_firewall.nodes.id]
  ssh_keys     = [hcloud_ssh_key.admin.id]
  user_data    = local.cloud_init
  labels       = merge(local.common_labels, { role = "agent" })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  network {
    subnet_id = hcloud_network_subnet.nodes.id
    ip        = each.value.private_ip
    alias_ips = []
  }

  # Same reasoning as for the servers.
  lifecycle {
    ignore_changes = [user_data, ssh_keys, image]
  }
}

# -----------------------------------------------------------------------------
# Fixed registration address: layer 4 load balancer in front of the servers
# -----------------------------------------------------------------------------
resource "hcloud_load_balancer" "api" {
  name               = "${var.cluster_name}-api"
  load_balancer_type = var.load_balancer_type
  location           = var.location
  labels             = merge(local.common_labels, { role = "api" })
}

# Disabling the public interface requires the load balancer to be attached to
# a network and every target to use its private IP.
resource "hcloud_load_balancer_network" "api" {
  load_balancer_id        = hcloud_load_balancer.api.id
  subnet_id               = hcloud_network_subnet.nodes.id
  ip                      = local.load_balancer_private_ip
  enable_public_interface = var.load_balancer_public
}

resource "hcloud_load_balancer_target" "server" {
  for_each = local.servers

  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = hcloud_server.server[each.key].id
  use_private_ip   = true

  # Private IP targets only work once the load balancer is in the network;
  # nothing in this resource references the attachment, so order it here.
  depends_on = [hcloud_load_balancer_network.api]
}

resource "hcloud_load_balancer_service" "kube_api" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "rke2_supervisor" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 9345
  destination_port = 9345

  health_check {
    protocol = "tcp"
    port     = 9345
    interval = 10
    timeout  = 5
    retries  = 3
  }
}
