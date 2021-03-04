# Output variables

# EC instances dns public records
output "web_servers_public_dns_records" {
  value = aws_instance.web_server.*.public_dns
}

# Load balancer dns public record
output "loadbalancer_public_dns_records" {
  value = aws_lb.web_servers_lb.dns_name
}

