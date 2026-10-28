output "node_ips" {
  description = "Public IP per node, consumed by scripts/bootstrap.sh"
  value       = { for name, n in verda_instance.node : name => n.ip }
}
