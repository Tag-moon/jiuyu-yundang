output "instance_id" {
  value = huaweicloud_compute_instance.app.id
}

output "public_ip" {
  value = huaweicloud_vpc_eip.app.address
}

output "private_ip" {
  value = try(huaweicloud_compute_instance.app.network[0].fixed_ip_v4, null)
}

output "security_group_id" {
  value = huaweicloud_networking_secgroup.app.id
}

output "vpc_id" {
  value = huaweicloud_vpc.app.id
}

output "subnet_id" {
  value = huaweicloud_vpc_subnet.app.id
}
