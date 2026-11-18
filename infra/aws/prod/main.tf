terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "private_app_az1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "private_app_az2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "us-east-1b"
}

resource "aws_subnet" "private_db_az1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "private_db_az2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.21.0/24"
  availability_zone = "us-east-1b"
}

resource "aws_security_group" "db_sg" {
  name   = "db-private-sg"
  vpc_id = aws_vpc.main.id
}

resource "aws_db_subnet_group" "db_subnets" {
  name       = "enterprise-ai-db-subnets"
  subnet_ids = [aws_subnet.private_db_az1.id, aws_subnet.private_db_az2.id]
}

resource "aws_db_instance" "postgres" {
  identifier                  = "enterprise-ai-postgres"
  engine                      = "postgres"
  engine_version              = "16.3"
  instance_class              = "db.t4g.medium"
  allocated_storage           = 50
  storage_encrypted           = true
  multi_az                    = true
  publicly_accessible         = false
  db_subnet_group_name        = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids      = [aws_security_group.db_sg.id]
  db_name                     = "aiplatform"
  username                    = "ai_admin"
  manage_master_user_password = true
  skip_final_snapshot         = true
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "enterprise-ai-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role" "eks_node_role" {
  name = "enterprise-ai-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_eks_cluster" "main" {
  name     = "enterprise-ai-eks"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids              = [aws_subnet.private_app_az1.id, aws_subnet.private_app_az2.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "ai-platform-workers"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.private_app_az1.id, aws_subnet.private_app_az2.id]
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 6
  }
}

resource "aws_iam_role_policy" "eks_bedrock_access" {
  name = "eks-bedrock-least-privilege"
  role = aws_iam_role.eks_node_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
      }
    ]
  })
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_app_az1.id, aws_subnet.private_app_az2.id]
  private_dns_enabled = true
}

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/eks/enterprise-ai-prod/application"
  retention_in_days = 30
}

resource "aws_cloudwatch_metric_alarm" "db_high_cpu" {
  alarm_name          = "enterprise-ai-rds-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Triggers when production PostgreSQL CPU exceeds 80% for 10 minutes"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }
}
