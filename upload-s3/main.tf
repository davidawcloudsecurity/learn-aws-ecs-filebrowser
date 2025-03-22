# Configure the AWS provider
provider "aws" {
  region = "us-east-1" # Change to your preferred region
}

# VPC with a single public subnet
resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "filebrowser-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.1.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "filebrowser-public-subnet"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "filebrowser-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "filebrowser-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# S3 Bucket for Filebrowser storage
resource "aws_s3_bucket" "filebrowser_storage" {
  bucket = "my-filebrowser-bucket-${random_string.suffix.result}" # Unique bucket name
  tags = {
    Name = "filebrowser-storage"
  }
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# ECR Repository for Filebrowser image
resource "aws_ecr_repository" "filebrowser" {
  name                 = "filebrowser"
  image_tag_mutability = "MUTABLE"
  force_delete = true  # This will allow deletion even when the repository contains images
}

# ECS Cluster
resource "aws_ecs_cluster" "filebrowser_cluster" {
  name = "filebrowser-cluster"
}

# CloudWatch Log Group for Filebrowser logs
resource "aws_cloudwatch_log_group" "filebrowser_logs" {
  name              = "/ecs/filebrowser"
  retention_in_days = 7
}

# ECS Task Definition for Filebrowser
resource "aws_ecs_task_definition" "filebrowser_task" {
  family                   = "filebrowser-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256" # 0.25 vCPU
  memory                   = "512" # 512 MB
  task_role_arn = aws_iam_role.ecs_execution_role.arn  # Add this line
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "filebrowser"
      image = "${aws_ecr_repository.filebrowser.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      environment = [
        {
          name  = "FB_STORAGE",
          value = "s3://:@us-east-1/${aws_s3_bucket.filebrowser_storage.bucket}"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.filebrowser_logs.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "filebrowser"
        }
      }
    }
  ])

  # depends_on = [null_resource.push_filebrowser_image]
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Add S3 permissions to the ECS execution role
resource "aws_iam_role_policy" "ecs_s3_access" {
  name   = "ecs_s3_access"
  role   = aws_iam_role.ecs_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:PutObjectAcl"
        ]
        Resource = [
          "${aws_s3_bucket.filebrowser_storage.arn}",
          "${aws_s3_bucket.filebrowser_storage.arn}/*"
        ]
      }
    ]
  })
}

# Security Group for Fargate Service
resource "aws_security_group" "filebrowser_sg" {
  vpc_id = aws_vpc.main.id
  name   = "filebrowser-sg"
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Public access (adjust for security if needed)
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Service with Fargate
resource "aws_ecs_service" "filebrowser_service" {
  name            = "filebrowser-service"
  cluster         = aws_ecs_cluster.filebrowser_cluster.id
  task_definition = aws_ecs_task_definition.filebrowser_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.filebrowser_sg.id]
    assign_public_ip = true
  }

  depends_on = [aws_ecs_task_definition.filebrowser_task]
}

resource "null_resource" "push_filebrowser_image" {
  depends_on = [
    aws_ecr_repository.filebrowser,
    aws_s3_bucket.filebrowser_storage,
    aws_ecs_cluster.filebrowser_cluster
  ]
  provisioner "local-exec" {
    command = <<EOT
      # Clean up and use /tmp
      rm -rf /tmp/filebrowser-build || true
      mkdir -p /tmp/filebrowser-build
      cd /tmp/filebrowser-build
      
      # Create Dockerfile
      cat > Dockerfile << 'EOF'
FROM filebrowser/filebrowser:latest

USER root

RUN apk add --no-cache s3fs-fuse fuse ca-certificates bash
RUN mkdir -p /srv/s3bucket
ENV S3_BUCKET=\${aws_s3_bucket.filebrowser_storage.bucket}

RUN echo '#!/bin/bash' > /entrypoint.sh && \
    echo 'set -e' >> /entrypoint.sh && \
    echo 'echo "Mounting S3 bucket: \$S3_BUCKET"' >> /entrypoint.sh && \
    echo 'S3_OPTIONS="\$${S3_OPTIONS:-""}"' >> /entrypoint.sh && \
    echo 's3fs "\$S3_BUCKET" /srv/s3bucket -o iam_role=auto -o allow_other -o umask=0022 -o dbglevel=info \$S3_OPTIONS' >> /entrypoint.sh && \
    echo 'echo "S3 bucket mounted at /srv/s3bucket using IAM role"' >> /entrypoint.sh && \
    echo 'export FB_ROOT=/srv/s3bucket' >> /entrypoint.sh && \
    echo 'exec /filebrowser' >> /entrypoint.sh

RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF
      
      # Authenticate Docker to ECR
      while true; do
        aws ecr get-login-password --region ${data.aws_region.current.name} | docker login --username AWS --password-stdin ${aws_ecr_repository.filebrowser.repository_url}
        if [ $? -eq 0 ]; then break; else echo "Retrying login..."; sleep 5; fi
      done
      
      # Pull, build, tag, push
      docker pull filebrowser/filebrowser:latest || true
      docker build -t filebrowser-s3:latest .
      docker tag filebrowser-s3:latest ${aws_ecr_repository.filebrowser.repository_url}:latest
      docker push ${aws_ecr_repository.filebrowser.repository_url}:latest
      
      # Clean up
      cd .. && rm -rf /tmp/filebrowser-build
    EOT
  }
}

data "aws_region" "current" {}

# Outputs
output "ecr_repository_url" {
  value = aws_ecr_repository.filebrowser.repository_url
}

output "s3_bucket_name" {
  value = aws_s3_bucket.filebrowser_storage.bucket
}

output "filebrowser_public_ip" {
  value = "After deployment, check the ECS service tasks in the AWS Console for the public IP."
}
