output "vcn_id" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.this.id
}

output "public_subnet_id" {
  description = "OCID of the public subnet."
  value       = oci_core_subnet.public.id
}

output "nsg_id" {
  description = "OCID of the network security group."
  value       = oci_core_network_security_group.web.id
}

output "instance_id" {
  description = "OCID of the VM."
  value       = oci_core_instance.vm.id
}

output "instance_image_id" {
  description = "OCID of the Ubuntu 24.04 image that was selected."
  value       = local.ubuntu_image_id
}

output "public_ip" {
  description = "Public IP of the VM."
  value       = oci_core_instance.vm.public_ip
}

output "private_ip" {
  description = "Private IP of the VM."
  value       = oci_core_instance.vm.private_ip
}

output "ssh_command" {
  description = "Ready-to-paste SSH command (only works from ssh_allowed_cidr)."
  value       = "ssh ubuntu@${oci_core_instance.vm.public_ip}"
}

output "http_url" {
  description = "URL served by the VM on port 80."
  value       = "http://${oci_core_instance.vm.public_ip}"
}

output "home_region" {
  description = "The tenancy's home region — the only region with Always Free capacity."
  value       = local.home_region
}

output "always_free" {
  description = "Whether this VM falls inside Oracle's Always Free allocation."
  value       = local.is_always_free
}

output "cost_summary" {
  description = "Plain-language note on what this instance costs."
  value       = local.is_always_free ? "Always Free: ${var.instance_ocpus} OCPU / ${var.instance_memory_in_gbs} GB on ${var.instance_shape} in ${var.region}, ${var.boot_volume_size_in_gbs} GB boot volume. No charge, assuming no other A1 instances already consume the tenancy-wide 4 OCPU / 24 GB pool." : "BILLED: ${var.instance_shape} at ${var.instance_ocpus} OCPU / ${var.instance_memory_in_gbs} GB in ${var.region} is outside the Always Free allocation."
}

output "compartment_id" {
  description = "Compartment everything was built in (root compartment if none was set)."
  value       = local.compartment_id
}
