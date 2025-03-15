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

# ECR Repository for Filebrowser image
resource "aws_ecr_repository" "filebrowser" {
  name                 = "filebrowser"
  image_tag_mutability = "MUTABLE"
  force_delete = true  # This will allow deletion even when the repository contains images
}

# Local-exec to clone, build, and push Filebrowser image
resource "null_resource" "push_filebrowser_image" {
  depends_on = [aws_ecr_repository.filebrowser]

  provisioner "local-exec" {
    command = <<EOT
      # Clean up any previous build directory
      chown ${whoami}. /home
      rm -rf /home/filebrowser-build || true
      mkdir -p /home/filebrowser-build
      cd /home/filebrowser-build

      # Authenticate Docker to ECR
      aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${aws_ecr_repository.filebrowser.repository_url}
      
      # Build the Docker image using the local context
      docker pull filebrowser/filebrowser:latest
      
      # Tag the image for ECR
      docker tag filebrowser:latest ${aws_ecr_repository.filebrowser.repository_url}:latest
      
      # Push the image to ECR
      docker push ${aws_ecr_repository.filebrowser.repository_url}:latest
      
      # Clean up
      cd .. && rm -rf /home/filebrowser-build
    EOT
  }
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
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "filebrowser"
      image = "${aws_ecr_repository.filebrowser.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.filebrowser_logs.name
          "awslogs-region"        = "us-east-1" # Match your region
          "awslogs-stream-prefix" = "filebrowser"
        }
      }
      command = ["-r", "/srv"] # Default directory for Filebrowser
    }
  ])

  depends_on = [null_resource.push_filebrowser_image]
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

# Security Group for Fargate Service
resource "aws_security_group" "filebrowser_sg" {
  vpc_id = aws_vpc.main.id
  name   = "filebrowser-sg"
  ingress {
    from_port   = 80
    to_port     = 80
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

# Outputs
output "ecr_repository_url" {
  value = aws_ecr_repository.filebrowser.repository_url
}

output "filebrowser_public_ip" {
  value = "After deployment, check the ECS service tasks in the AWS Console for the public IP."
}
