############################
# Placement + image lookup
############################

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Always Free resources exist only in the tenancy's home region. Resolve it so
# the apply can refuse to build billable capacity in a secondary region.
data "oci_identity_tenancy" "this" {
  tenancy_id = var.tenancy_ocid
}

data "oci_identity_regions" "all" {}

# Canonical Ubuntu 24.04, filtered by shape so the right architecture
# (aarch64 for A1.Flex, x86_64 for E-series) is selected automatically.
data "oci_core_images" "ubuntu_2404" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  ubuntu_image_id     = data.oci_core_images.ubuntu_2404.images[0].id

  home_region = one([
    for r in data.oci_identity_regions.all.regions :
    r.name if upper(r.key) == upper(data.oci_identity_tenancy.this.home_region_key)
  ])

  is_always_free = (
    var.instance_shape == "VM.Standard.A1.Flex" &&
    var.instance_ocpus <= 4 &&
    var.instance_memory_in_gbs <= 24 &&
    var.boot_volume_size_in_gbs <= 200 &&
    var.region == local.home_region
  )

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    install_nginx = var.install_nginx
  })
}

############################
# Instance
############################

resource "oci_core_instance" "vm" {
  compartment_id      = local.compartment_id
  availability_domain = local.availability_domain
  display_name        = "${var.project_name}-vm"
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = local.ubuntu_image_id
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id                 = oci_core_subnet.public.id
    assign_public_ip          = true
    assign_private_dns_record = true
    display_name              = "${var.project_name}-vnic"
    hostname_label            = substr("${local.dns_label}vm", 0, 15)
    nsg_ids                   = [oci_core_network_security_group.web.id]
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.cloud_init)
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false
  }

  preserve_boot_volume = false

  lifecycle {
    # Always Free guardrails. Oracle's perpetual free allocation is a tenancy-wide
    # pool of 4 OCPU + 24 GB on VM.Standard.A1.Flex (Ampere ARM) plus 200 GB of
    # total block storage, usable only in the tenancy's home region.
    precondition {
      condition     = !var.enforce_always_free_limits || var.instance_shape == "VM.Standard.A1.Flex"
      error_message = "Always Free covers only VM.Standard.A1.Flex at this size; ${var.instance_shape} is billed. Set enforce_always_free_limits = false to proceed anyway."
    }

    precondition {
      condition     = !var.enforce_always_free_limits || (var.instance_ocpus <= 4 && var.instance_memory_in_gbs <= 24)
      error_message = "Always Free allows at most 4 OCPU and 24 GB of RAM in total across all A1 instances. Requested: ${var.instance_ocpus} OCPU / ${var.instance_memory_in_gbs} GB."
    }

    precondition {
      condition     = !var.enforce_always_free_limits || var.region == local.home_region
      error_message = "Always Free capacity exists only in the tenancy's home region (${local.home_region}); region ${var.region} would be billed."
    }

    precondition {
      condition     = !var.enforce_always_free_limits || var.boot_volume_size_in_gbs <= 200
      error_message = "Always Free includes 200 GB of total block storage. Requested boot volume: ${var.boot_volume_size_in_gbs} GB."
    }
  }
}
