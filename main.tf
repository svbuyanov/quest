terraform {
  backend "s3" {
    
    bucket = "terraformtfsbuyanov"
    region = "us-east-1"
    key = "s3-backup/tfstate"
  }
}
  
################Specify access details############
provider "aws" {
  region = "us-east-1"
  
}
############# Create a VPC ######################
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "Quest VPC"
  }
}
############## Create an internet gateway################
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Quest VPC IG"
  }
}

##################### Declare the data source################
data "aws_availability_zones" "available" {
}

############### Create a subnet#############################
resource "aws_subnet" "web_subnet_az" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "Quest Public Subnet AZ${count.index} - ${data.aws_availability_zones.available.names[count.index]}"
  }
  depends_on = [aws_internet_gateway.gw]
}

################# Grant public access on Internet Gateway######################
resource "aws_route_table" "r" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "Quest Public Route Table"
  }
}

############### Associate the public subnets with the route table##############
resource "aws_route_table_association" "web_subnets_assotiations" {
  count = 2

  subnet_id      = aws_subnet.web_subnet_az[count.index].id
  route_table_id = aws_route_table.r.id
}
###################Create Security Group##########
resource "aws_security_group" "nodejs_Server" {
  name        = "Web Server Traffic"
  description = "Allow all inbound http traffic"
  vpc_id      = aws_vpc.main.id

  # HTTP access from anywhere
  dynamic "ingress" {
   for_each = ["80", "443", "3000","22"]

    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
 

############# EC2 instances creation#########
data "aws_availability_zones" "for_web"{}
data "aws_ami" "amazon-linux-2" {
  owners = ["amazon"]
  most_recent = true
 filter {
    name = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}

resource "aws_instance" "web_server" {
  count = 1
  ami           = data.aws_ami.amazon-linux-2.id
  instance_type = "t2.micro"
  key_name      = "N.Virginia"
  monitoring    = true
  subnet_id     = aws_subnet.web_subnet_az[count.index].id
  # Our Security group to allow inbound HTTP and SSH access
  vpc_security_group_ids = [aws_security_group.nodejs_Server.id]
  tags = {
    Name        = "Quest Server ${count.index}"
    Terraform   = "true"
  }
  user_data = <<-EOF
              #!bin/bash
	#install nessesary package		  
        sudo yum update –y
        sudo yum install git -y
			  sudo yum update -y
        sudo amazon-linux-extras install docker
        sudo service docker start
        sudo usermod -a -G docker ec2-user
	#create directory and deploy nodejs 		  
			  mkdir /app
              chmod 755 /app
              cd /app
              git clone https://github.com/rearc/quest.git
              curl -sL https://rpm.nodesource.com/setup_6.x | sudo -E bash -
              sudo yum install nodejs --enablerepo=nodesource -y
              node --version > nodeVersion.txt
              cd /app/quest
              npm install
              npm start
	             EOF
			  
}

############ Public ip assig EC2 intances##############
resource "aws_eip" "web_server_eip" {
  count = 1

  vpc        = true
  instance   = aws_instance.web_server[count.index].id
  depends_on = [aws_internet_gateway.gw]
}
############ Create certificate for LoadBalancer ##############
resource "tls_self_signed_cert" "example" {
  key_algorithm   = "RSA"
  private_key_pem = tls_private_key.test.private_key_pem

  subject {
    common_name  = "server.com"
    organization = "ACME Examples, Inc"
  }

  validity_period_hours = 12

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "cert" {
  private_key      = tls_private_key.test.private_key_pem
  certificate_body = tls_self_signed_cert.example.cert_pem
}
resource "tls_private_key" "test" {
  algorithm = "RSA"
}

############ Create a new load balancer#################
resource "aws_lb" "web_servers_lb" {
  name               = "web-servers-lb"
  internal           = false
  load_balancer_type = "application"

  subnets         = aws_subnet.web_subnet_az.*.id
  security_groups = [aws_security_group.nodejs_Server.id]

  tags = {
    Name = "web-servers-elb"
  }
}

resource "aws_lb_target_group" "webserver_target_group" {
  name     = "WebserverTargetGroup"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.web_servers_lb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webserver_target_group.arn
  }
}
resource "aws_lb_listener" "front_end_2" {
  load_balancer_arn = aws_lb.web_servers_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
resource "aws_lb_target_group_attachment" "alb_instance_attachement" {
  count = 1

  target_group_arn = aws_lb_target_group.webserver_target_group.arn
  target_id        = aws_instance.web_server[count.index].id
  port             = 3000
}
