terraform {
  required_version = ">= 0.12"
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "f5cloudsa"

    workspaces {
      name = "terraform-aws-bigip-demo"
    }
  }
}
provider "aws" {
  region     = var.region
  access_key = var.AccessKeyID
  secret_key = var.SecretAccessKey
}

# Create a random id
resource "random_id" "id" {
  byte_length = 2
}

# Create the VPC 
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                 = format("%s-vpc-%s", var.prefix, random_id.id.hex)
  cidr                 = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  azs = var.azs

  public_subnets = [
    for num in range(length(var.azs)) :
    cidrsubnet(var.cidr, 8, num)
  ]

  tags = {
    Name        = format("%s-vpc-%s", var.prefix, random_id.id.hex)
    Terraform   = "true"
    Environment = "dev"
  }
}

module "web_server_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name        = format("%s-web-server-%s", var.prefix, random_id.id.hex)
  description = "Security group for web-server with HTTP ports"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.allowed_app_cidr]
}

module "web_server_secure_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/https-443"

  name        = format("%s-web-server-secure-%s", var.prefix, random_id.id.hex)
  description = "Security group for web-server with HTTPS ports"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.allowed_app_cidr]
}

module "bigip_mgmt_secure_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/https-8443"

  name        = format("%s-bigip-mgmt-%s", var.prefix, random_id.id.hex)
  description = "Security group for BIG-IP MGMT Interface"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.allowed_mgmt_cidr]
}

module "ssh_secure_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/ssh"

  name        = format("%s-ssh-%s", var.prefix, random_id.id.hex)
  description = "Security group for SSH ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = [var.allowed_mgmt_cidr]
}

# Create the demo app
module "nginx-demo-app" {
  source  = "app.terraform.io/f5cloudsa/nginx-demo-app/aws"
  version = "0.1.0"

  prefix = format(
    "%s-%s",
    var.prefix,
    random_id.id.hex
  )
  associate_public_ip_address = true
  ec2_key_name                = var.ec2_key_name
  vpc_security_group_ids = [
    module.web_server_sg.this_security_group_id,
    module.ssh_secure_sg.this_security_group_id
  ]
  vpc_subnet_ids     = module.vpc.public_subnets
  ec2_instance_count = 4
}

# Create the BIG-IP appliances
module "bigip" {
  source  = "app.terraform.io/f5cloudsa/bigip/aws"
  version = "0.1.0"

  prefix = format(
    "%s-bigip-1-nic_with_new_vpc-%s",
    var.prefix,
    random_id.id.hex
  )
  f5_instance_count = length(var.azs)
  ec2_key_name      = var.ec2_key_name
  ec2_private_key   = var.private_key_path
  mgmt_subnet_security_group_ids = [
    module.web_server_sg.this_security_group_id,
    module.web_server_secure_sg.this_security_group_id,
    module.ssh_secure_sg.this_security_group_id,
    module.bigip_mgmt_secure_sg.this_security_group_id
  ]
  vpc_mgmt_subnet_ids = module.vpc.public_subnets
}