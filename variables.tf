############################
# Provider / auth
############################

variable "tenancy_ocid" {
  description = "OCID of the tenancy."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the user whose API key is used."
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API signing key uploaded to the user."
  type        = string
}

variable "private_key_path" {
  description = "Path to the API signing private key (.pem) on this machine."
  type        = string
}

variable "region" {
  description = "OCI region identifier, e.g. eu-frankfurt-1."
  type        = string
}

variable "compartment_ocid" {
  description = <<-EOT
    OCID of the compartment to build everything in. Leave unset (null) to use the
    tenancy's root compartment, whose OCID is the tenancy OCID itself — which is
    all a fresh free-tier tenancy has until you create sub-compartments.
    Console path to a real one: Identity & Security -> Compartments -> click it -> Copy OCID.
  EOT
  type        = string
  default     = null
}

locals {
  # Root compartment OCID == tenancy OCID.
  compartment_id = coalesce(var.compartment_ocid, var.tenancy_ocid)

  # DNS and hostname labels must be lowercase alphanumeric, start with a letter,
  # and stay under 15 chars, so project_name is normalised rather than used raw.
  dns_label = substr(lower(replace(var.project_name, "/[^A-Za-z0-9]/", "")), 0, 15)
}

############################
# Naming / placement
############################

variable "project_name" {
  description = "Prefix used for the name of every resource."
  type        = string
  default     = "demo"
}

variable "availability_domain_index" {
  description = "Which availability domain in the region to use (0-based)."
  type        = number
  default     = 0
}

############################
# Network
############################

variable "vcn_cidr" {
  description = "CIDR block of the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block of the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ssh_allowed_cidr" {
  description = "The ONLY CIDR allowed to reach port 22. Use a /32 for a single IP, e.g. 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0)) && var.ssh_allowed_cidr != "0.0.0.0/0"
    error_message = "ssh_allowed_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

############################
# Compute
############################

variable "instance_shape" {
  description = <<-EOT
    Flexible shape for the VM. All of these can do 4 OCPU / 24 GB:
      VM.Standard.A1.Flex  -> Ampere ARM (aarch64), ALWAYS FREE  <- default
      VM.Standard3.Flex    -> Intel Ice Lake (x86_64, paid)
      VM.Standard.E5.Flex  -> AMD EPYC (x86_64, paid)
    The Ubuntu image is looked up per shape, so the architecture follows
    automatically. Only A1.Flex is free of charge.
  EOT
  type        = string
  default     = "VM.Standard.A1.Flex"

  validation {
    condition     = endswith(var.instance_shape, ".Flex")
    error_message = "This config sets ocpus/memory explicitly, so it needs a flexible (.Flex) shape."
  }
}

variable "instance_ocpus" {
  description = "Number of OCPUs."
  type        = number
  default     = 4
}

variable "instance_memory_in_gbs" {
  description = "Memory in GB."
  type        = number
  default     = 24
}

variable "boot_volume_size_in_gbs" {
  description = "Boot volume size in GB (minimum 50)."
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "SSH public key injected into the ubuntu user (contents of e.g. id_rsa.pub)."
  type        = string
}

variable "install_nginx" {
  description = "Install nginx via cloud-init so ports 80/443 answer immediately."
  type        = bool
  default     = true
}

############################
# Always Free guardrails
############################

variable "enforce_always_free_limits" {
  description = <<-EOT
    When true, the apply fails if the requested VM would fall outside Oracle's
    Always Free allocation (VM.Standard.A1.Flex, <= 4 OCPU, <= 24 GB RAM,
    <= 200 GB boot volume, home region only).

    Set to false only if you deliberately want a billable instance.
  EOT
  type        = bool
  default     = true
}
