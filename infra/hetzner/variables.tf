variable "hcloud_token" {
  description = "Hetzner Cloud API token with read and write access to the target project. Set it through the environment as TF_VAR_hcloud_token; never put it in a tfvars file."
  type        = string
  sensitive   = true
  nullable    = false
}

variable "cluster_name" {
  description = "Cluster name. Prefix for every resource name and value of the cluster label."
  type        = string
  default     = "reference"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a lowercase DNS label of at most 32 characters: a-z, 0-9 and '-', starting with a letter and not ending with '-'."
  }
}

variable "location" {
  description = "Hetzner Cloud location for servers and the load balancer. Must belong to network_zone."
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.location)
    error_message = "location must be one of fsn1, nbg1, hel1, ash, hil, sin."
  }
}

variable "network_zone" {
  description = "Hetzner Cloud network zone of the private subnet. Must contain location."
  type        = string
  default     = "eu-central"

  validation {
    condition = lookup({
      fsn1 = "eu-central"
      nbg1 = "eu-central"
      hel1 = "eu-central"
      ash  = "us-east"
      hil  = "us-west"
      sin  = "ap-southeast"
    }, var.location, "") == var.network_zone
    error_message = "network_zone does not match location: fsn1, nbg1 and hel1 are in eu-central, ash in us-east, hil in us-west, sin in ap-southeast."
  }
}

variable "network_cidr" {
  description = "IPv4 range of the private network. Must be RFC 1918 and must not overlap the RKE2 cluster and service CIDRs."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition = try(anytrue([
      for block in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] :
      tonumber(split("/", var.network_cidr)[1]) >= tonumber(split("/", block)[1]) &&
      cidrhost("${cidrhost(var.network_cidr, 0)}/${split("/", block)[1]}", 0) == cidrhost(block, 0)
    ]) && can(cidrnetmask(var.network_cidr)), false)
    error_message = "network_cidr must be an IPv4 CIDR inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16."
  }
}

variable "subnet_cidr" {
  description = "IPv4 range of the subnet that servers, agents and the load balancer attach to. Must lie inside network_cidr and be a /24 or larger: servers use host 10 onward, agents host 20 onward, the load balancer host 254."
  type        = string
  default     = "10.20.0.0/24"

  validation {
    condition = try(
      can(cidrnetmask(var.subnet_cidr)) &&
      tonumber(split("/", var.subnet_cidr)[1]) <= 24 &&
      tonumber(split("/", var.subnet_cidr)[1]) >= tonumber(split("/", var.network_cidr)[1]) &&
      cidrhost("${cidrhost(var.subnet_cidr, 0)}/${split("/", var.network_cidr)[1]}", 0) == cidrhost(var.network_cidr, 0),
      false
    )
    error_message = "subnet_cidr must be an IPv4 CIDR inside network_cidr with a prefix length of at most /24."
  }
}

variable "server_count" {
  description = "Number of RKE2 server nodes (control plane and embedded etcd). Odd, because an even etcd member count adds no failure tolerance."
  type        = number
  default     = 3

  validation {
    condition     = contains([1, 3, 5], var.server_count)
    error_message = "server_count must be 1, 3 or 5: an odd number between 1 and 5."
  }
}

variable "agent_count" {
  description = "Number of RKE2 agent (worker) nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.agent_count >= 0 && var.agent_count <= 10 && floor(var.agent_count) == var.agent_count
    error_message = "agent_count must be a whole number between 0 and 10."
  }
}

variable "server_type" {
  description = "Hetzner Cloud server type for RKE2 servers (control plane and etcd). RKE2 recommends at least 4 CPU and 8 GB RAM per node."
  type        = string
  default     = "cpx32"

  validation {
    condition     = can(regex("^[a-z]+[0-9]+$", var.server_type))
    error_message = "server_type must be a Hetzner Cloud server type name such as cpx32 or cx33."
  }
}

variable "agent_type" {
  description = "Hetzner Cloud server type for RKE2 agents."
  type        = string
  default     = "cpx32"

  validation {
    condition     = can(regex("^[a-z]+[0-9]+$", var.agent_type))
    error_message = "agent_type must be a Hetzner Cloud server type name such as cpx32 or cx33."
  }
}

variable "image" {
  description = "Hetzner Cloud system image for all nodes. Limited to the distributions the Ansible roles support."
  type        = string
  default     = "ubuntu-24.04"

  validation {
    condition     = contains(["ubuntu-24.04", "debian-12", "debian-13", "rocky-9"], var.image)
    error_message = "image must be one of ubuntu-24.04, debian-12, debian-13, rocky-9."
  }
}

variable "ssh_public_key" {
  description = "OpenSSH ed25519 public key (one line) for the admin user. Also registered as Hetzner Cloud SSH key so the API does not generate a root password."
  type        = string

  validation {
    condition     = can(regex("^ssh-ed25519 AAAA[0-9A-Za-z+/]+={0,3}( [^\\r\\n]*)?$", var.ssh_public_key))
    error_message = "ssh_public_key must be a single-line OpenSSH ed25519 public key starting with 'ssh-ed25519 '."
  }
}

variable "admin_username" {
  description = "Login created by cloud-init with the SSH key and passwordless sudo. Ansible connects as this user."
  type        = string
  default     = "ops"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.admin_username)) && var.admin_username != "root"
    error_message = "admin_username must be a lowercase Linux user name of at most 32 characters and must not be root."
  }
}

variable "admin_cidrs" {
  description = "Networks allowed to reach SSH (22/tcp) on the nodes' public interfaces. Also rendered into the inventory as firewall_ssh_cidrs and firewall_api_cidrs."
  type        = list(string)
  nullable    = false

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR."
  }

  validation {
    condition     = alltrue([for cidr in var.admin_cidrs : try(cidrhost(cidr, 0) == split("/", cidr)[0], false)])
    error_message = "Every admin_cidrs entry must be an IPv4 or IPv6 CIDR written with its network address (no host bits set), for example 203.0.113.0/24 or 203.0.113.10/32."
  }

  validation {
    condition     = var.allow_ssh_from_anywhere || alltrue([for cidr in var.admin_cidrs : try(split("/", cidr)[1] != "0", true)])
    error_message = "admin_cidrs contains 0.0.0.0/0 or ::/0. Restrict it to your admin networks, or set allow_ssh_from_anywhere = true to accept SSH from the whole internet."
  }
}

variable "allow_ssh_from_anywhere" {
  description = "Permit 0.0.0.0/0 or ::/0 in admin_cidrs. Keep false outside short-lived labs."
  type        = bool
  default     = false
}

variable "load_balancer_type" {
  description = "Hetzner Cloud load balancer type in front of the RKE2 servers."
  type        = string
  default     = "lb11"

  validation {
    condition     = contains(["lb11", "lb21", "lb31"], var.load_balancer_type)
    error_message = "load_balancer_type must be one of lb11, lb21, lb31."
  }
}

variable "load_balancer_public" {
  description = <<-EOT
    Enable the load balancer's public interface. When true, the Kubernetes API
    (6443/tcp) and the RKE2 supervisor (9345/tcp) listen on the load balancer's
    public IPv4 and IPv6 for any source: Hetzner Cloud Firewalls apply to
    servers only, not to load balancers, and the nodes receive these
    connections from the load balancer's private address, so the host firewall
    cannot filter by client address either. Both ports then rely on their own
    authentication. When false, both services are reachable only inside the
    private network; reach the API over a VPN or an SSH tunnel.
  EOT
  type        = bool
  default     = true
}

variable "labels" {
  description = "Extra Hetzner Cloud labels for every resource. The keys cluster and role are set by this configuration and win on conflict."
  type        = map(string)
  default     = {}
}
