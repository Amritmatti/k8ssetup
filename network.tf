############################
# VCN ("VPC")
############################

resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${var.project_name}-vcn"
  dns_label      = local.dns_label
}

############################
# Internet gateway + routing
############################

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.project_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.project_name}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

############################
# Security list on the subnet
#
# Deliberately minimal: egress only. All ingress filtering lives in the NSG
# below. (OCI unions security-list and NSG rules, so leaving ingress empty
# here means the NSG is the single source of truth for what gets in.)
############################

resource "oci_core_security_list" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.project_name}-public-sl"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }
}

############################
# Public subnet
############################

resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.public_subnet_cidr
  display_name               = "${var.project_name}-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
}

############################
# Network security group ("security group")
############################

resource "oci_core_network_security_group" "web" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.project_name}-web-nsg"
}

# --- Ingress: HTTP open to the world -------------------------------------
resource "oci_core_network_security_group_security_rule" "http" {
  network_security_group_id = oci_core_network_security_group.web.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "HTTP from anywhere"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

# --- Ingress: HTTPS open to the world ------------------------------------
resource "oci_core_network_security_group_security_rule" "https" {
  network_security_group_id = oci_core_network_security_group.web.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "HTTPS from anywhere"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

# --- Ingress: SSH restricted to one CIDR ---------------------------------
resource "oci_core_network_security_group_security_rule" "ssh" {
  network_security_group_id = oci_core_network_security_group.web.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.ssh_allowed_cidr
  source_type               = "CIDR_BLOCK"
  description               = "SSH from ${var.ssh_allowed_cidr} only"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# --- Ingress: ICMP path-MTU discovery (keeps TCP from black-holing) ------
resource "oci_core_network_security_group_security_rule" "icmp_pmtud" {
  network_security_group_id = oci_core_network_security_group.web.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Destination unreachable / fragmentation needed"

  icmp_options {
    type = 3
    code = 4
  }
}

# --- Egress: allow all ----------------------------------------------------
resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.web.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "All outbound"
}
