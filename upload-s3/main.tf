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

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM Policy for EC2 Role
resource "aws_iam_policy" "ec2_policy" {
  name = "ec2_policy"

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

# Attach the policies to the role
resource "aws_iam_role_policy_attachment" "ec2_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
/*
# Create instance profile
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile"
  role = aws_iam_role.ec2_role.name
}
*/
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
  requires_compatibilities = ["EC2"]
  cpu                      = "256" # Adjust as needed for EC2
  memory                   = "512" # Adjust as needed for EC2
  task_role_arn            = aws_iam_role.ecs_execution_role.arn
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
          name  = "FB_STORAGE"
          value = "s3://:@us-east-1/${aws_s3_bucket.filebrowser_storage.bucket}"
        }
      ]
      "privileged": true,
      "linuxParameters": {
          "devices": [
              {
                  "hostPath": "/dev/fuse",
                  "containerPath": "/dev/fuse"
              }
          ]
      }
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
  launch_type     = "EC2"

  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.filebrowser_sg.id]
    # assign_public_ip = true
  }

  depends_on = [aws_ecs_task_definition.filebrowser_task]
}

# Local-exec to build and push Filebrowser image with S3 config
resource "null_resource" "push_filebrowser_image" {
  depends_on = [
    aws_ecr_repository.filebrowser,
    aws_s3_bucket.filebrowser_storage,
    aws_ecs_cluster.filebrowser_cluster,
    aws_ecs_task_definition.filebrowser_task
  ]
  provisioner "local-exec" {
    command = <<EOT
      # Clean up any previous build directory
      sudo chown $(whoami) . /home
      rm -rf /home/filebrowser-build || true
      mkdir -p /home/filebrowser-build
      cd /home/filebrowser-build
      
      # Create Filebrowser config file for S3
      cat > filebrowser.json << 'EOF'
{
  "port": 8080,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "name": "FB_STORAGE",
  "value": "s3://${aws_s3_bucket.filebrowser_storage.bucket}"
}
EOF
      
      # Create Dockerfile with S3 config
      cat > Dockerfile << 'EOF'
FROM filebrowser/filebrowser:latest
COPY filebrowser.json /.filebrowser.json
ENTRYPOINT ["/filebrowser", "--address", "0.0.0.0"]
EOF
      
      # Authenticate Docker to ECR
      while true; do
        aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${aws_ecr_repository.filebrowser.repository_url}
        if [ $? -eq 0 ]; then
          echo "Docker login successful"
          break
        else
          echo "Docker login failed, retrying in 5 seconds..."
          sleep 5
        fi
      done
      
      # Pull the base image
      while true; do
        docker pull filebrowser/filebrowser:latest
        if [ $? -eq 0 ]; then
          echo "Docker pull successful"
          break
        else
          echo "Docker pull failed, retrying in 5 seconds..."
          sleep 5
        fi
      done
      
      # Build the custom Docker image
      while true; do
        docker build -t filebrowser-s3:latest .
        if [ $? -eq 0 ]; then
          echo "Docker build successful"
          break
        else
          echo "Docker build failed, retrying in 5 seconds..."
          sleep 5
        fi
      done
      
      # Tag the image for ECR
      docker tag filebrowser-s3:latest ${aws_ecr_repository.filebrowser.repository_url}:latest
      
      # Push the image to ECR
      while true; do
        docker push ${aws_ecr_repository.filebrowser.repository_url}:latest
        if [ $? -eq 0 ]; then
          echo "Docker push successful"
          break
        else
          echo "Docker push failed, retrying in 5 seconds..."
          sleep 5
        fi
      done
      
      # Clean up
      cd .. && rm -rf /home/filebrowser-build
    EOT
  }
}

resource "aws_lb_target_group" "ecs_target_group" {
  name     = "ecs-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_launch_template" "ecs" {
  name = "ecs-launch-template"

  image_id      = "ami-0c55b159cbfafe1f0" # Amazon ECS-optimized AMI ID (update with the latest ECS-optimized AMI)
  instance_type = "t3.micro"
  
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    subnet_id                   = aws_subnet.public.id
    security_groups             = [aws_security_group.filebrowser_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ecs-instance"
    }
  }
}

resource "aws_autoscaling_group" "ecs" {
  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  vpc_zone_identifier = [aws_subnet.public.id]

  min_size         = 1
  max_size         = 2
  desired_capacity = 1
/*
  tags = [
    {
      key                 = "Name"
      value               = "ecs-instance"
      propagate_at_launch = true
    }
  ]
*/
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_attachment" "ecs" {
  autoscaling_group_name = aws_autoscaling_group.ecs.name
  lb_target_group_arn   = aws_lb_target_group.ecs_target_group.arn
}

resource "aws_ecs_cluster_capacity_providers" "filebrowser_cluster" {
  cluster_name = aws_ecs_cluster.filebrowser_cluster.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT", "EC2"]

  default_capacity_provider_strategy {
    capacity_provider = "EC2"
    weight            = 1
  }
}

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
