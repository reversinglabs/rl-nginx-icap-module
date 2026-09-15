# Looked up, not managed: see var.elastic_ip_allocation_id (variables.tf)
# for why this must stay a pre-existing, hand-allocated address rather than
# an aws_eip resource.
data "aws_eip" "web" {
  id = var.elastic_ip_allocation_id
}

resource "aws_eip_association" "web" {
  allocation_id = data.aws_eip.web.id
  instance_id   = aws_instance.web.id
}
