terraform {
  # Spécifie l'utilisation du fournisseur AWS pour l'infrastructure
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  required_version = ">= 1.5.0"
}

provider "aws" {
  # Configuration de la région de déploiement (Paris) et du profil CLI sécurisé
  region  = "eu-west-3"
  profile = "meditrack"
}

provider "aws" {
  # Région obligatoire pour le certificat ACM de CloudFront
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = "meditrack"
}

# 1. CRÉATION DU RÉSEAU (VPC SÉCURISÉ & SOUS-RÉSEAUX)

# Création du réseau virtuel isolé (VPC) pour l'application
resource "aws_vpc" "meditrack_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Sous-réseau public A : héberge une partie du Load Balancer
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.meditrack_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-3a"
}

# Sous-réseau public B : indispensable pour la haute disponibilité du Load Balancer
resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.meditrack_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-3b"
}

# Sous-réseau privé : isole complètement le serveur EC2 d'Internet
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.meditrack_vpc.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "eu-west-3a"
}

# Passerelle Internet pour ouvrir les sous-réseaux publics vers l'extérieur
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.meditrack_vpc.id
}

# Allocation d'une adresse IP fixe (Elastic IP) pour la NAT Gateway
resource "aws_eip" "nat_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
}

# Passerelle NAT : permet au serveur privé de télécharger ses packages sans s'exposer
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_a.id
}

# Tables de routage associant le trafic public vers l'Internet Gateway
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.meditrack_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Tables de routage associant le trafic privé de l'EC2 vers la NAT Gateway
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.meditrack_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "priv" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# 2. SÉCURITÉ RESSOURCE & CHIFFREMENT (PARE-FEU)

# Groupe de sécurité de l'ALB
resource "aws_security_group" "alb_sg" {
  name   = "meditrack-alb-sg"
  vpc_id = aws_vpc.meditrack_vpc.id
}

# Règle d'entrée ALB : autorise le port HTTPS (443) v6 compatible
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  ip_protocol       = "tcp"
  to_port           = 443
}

# Règle de sortie ALB : autorise tout le trafic vers l'extérieur v6 compatible
resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Groupe de sécurité de l'EC2
resource "aws_security_group" "ec2_sg" {
  name   = "meditrack-ec2-sg"
  vpc_id = aws_vpc.meditrack_vpc.id
}

# Règle d'entrée EC2 : autorise uniquement le trafic HTTP (80) provenant du Load Balancer v6 compatible
resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = aws_security_group.ec2_sg.id
  referenced_security_group_id = aws_security_group.alb_sg.id
  from_port                    = 80
  ip_protocol                  = "tcp"
  to_port                      = 80
}

# Règle de sortie EC2 : autorise tout le trafic vers l'extérieur v6 compatible
resource "aws_vpc_security_group_egress_rule" "ec2_all_out" {
  security_group_id = aws_security_group.ec2_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# 3. ÉQUILIBRAGE DE CHARGE (LOAD BALANCER)

# Répartiteur de charge (ALB) pour acheminer le trafic CloudFront de manière fluide
resource "aws_lb" "meditrack_alb" {
  name               = "meditrack-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# Groupe cible liant le Load Balancer au serveur de destination final
resource "aws_lb_target_group" "tg" {
  name        = "meditrack-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.meditrack_vpc.id
  target_type = "instance"

  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = "80"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }
}

# Écouteur forçant l'usage exclusif du protocole HTTP vers l'ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.meditrack_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# 4. PROVISIONNING DE L'INSTANCE SERVEUR EC2 (AVEC SSM ET CHIFFREMENT)

# Rôle IAM autorisant l'accès d'administration à la machine à distance via SSM au lieu de SSH
resource "aws_iam_role" "ssm_role" {
  name = "meditrack-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "meditrack-ec2-instance-profile"
  role = aws_iam_role.ssm_role.name
}

# Provisionnement de la machine virtuelle légère EC2 (Ubuntu) dans le sous-réseau privé

# Recherche de la dernière AMI Ubuntu 22.04 LTS officielle
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_instance" "meditrack_server" {
  ami                  = data.aws_ami.ubuntu_2204.id
  instance_type        = "t3.micro"
  subnet_id            = aws_subnet.private.id
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  vpc_security_group_ids = [
    aws_security_group.ec2_sg.id
  ]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    encrypted             = true
    delete_on_termination = true
  }
}

resource "aws_lb_target_group_attachment" "ec2_attach" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.meditrack_server.id
  port             = 80
}

# 5. DISTRIBUTION CLOUDFRONT (DIFFUSION SÉCURISÉE)

# Mise en place de CloudFront pour distribuer le site rapidement via le protocole HTTPS
resource "aws_cloudfront_distribution" "meditrack_cdn" {
  origin {
    domain_name = aws_lb.meditrack_alb.dns_name
    origin_id   = "ALB-Meditrack"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled         = true
  is_ipv6_enabled = true

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "ALB-Meditrack"
    viewer_protocol_policy = "redirect-to-https" # Redirige automatiquement le HTTP vers HTTPS

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CacheDisabled politique managée AWS obligatoire sur v6
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewerExceptHostHeader politique managée AWS obligatoire sur v6
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# 6. STOCKAGE STATIQUE AMAZON S3 SECURE

# Création du bucket de stockage S3 pour l'hébergement du site statique
resource "aws_s3_bucket" "meditrack_storage" {
  bucket_prefix = "meditrack-secure-data-"
}

# Blocage total et strict de tout accès public sur le stockage S3
resource "aws_s3_bucket_public_access_block" "block_public" {
  bucket = aws_s3_bucket.meditrack_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Chiffrement automatique côté serveur (AES256) pour sécuriser l'ensemble des fichiers déposés
resource "aws_s3_bucket_server_side_encryption_configuration" "s3_encrypt" {
  bucket = aws_s3_bucket.meditrack_storage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
output "cloudfront_domain_name" {
  description = "URL publique de MediTrack via CloudFront"
  value       = "https://${aws_cloudfront_distribution.meditrack_cdn.domain_name}"
}
