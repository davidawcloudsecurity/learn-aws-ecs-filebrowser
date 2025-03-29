# Configure the AWS provider
provider "aws" {
  region = var.region
}

variable region {
  default = "us-east-1" # Change to your preferred region
}

# VPC with a single public subnet
resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"  # Private IP range for your VPC
  enable_dns_support   = true              # Enable DNS resolution in the VPC
  enable_dns_hostnames = true              # Enable DNS hostnames in the VPC
  tags = {
    Name = "filebrowser-vpc"
  }
}

# Public subnet where resources will be deployed
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id             # Reference to the VPC created above
  cidr_block              = "192.168.2.0/24"            # Subnet CIDR block within the VPC range
  map_public_ip_on_launch = true                        # Auto-assign public IPs to instances in this subnet
  availability_zone       = "us-east-1a"                # Explicitly set availability zone
  
  tags = {
    Name = "filebrowser-public-subnet"
  }
}

# Internet Gateway to allow internet access from the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id    # Attach to our VPC
  tags = {
    Name = "filebrowser-igw"
  }
}

# Route table for public subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id    # Attach to our VPC
  
  # Route all traffic to the internet gateway
  route {
    cidr_block = "0.0.0.0/0"                # All traffic
    gateway_id = aws_internet_gateway.igw.id # Send to internet gateway
  }
  
  tags = {
    Name = "filebrowser-public-rt"
  }
}

# Associate route table with the public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id       # Our public subnet
  route_table_id = aws_route_table.public.id  # The route table we created
}

# S3 Bucket for Filebrowser storage
resource "aws_s3_bucket" "filebrowser_storage" {
  bucket = "my-filebrowser-bucket-${random_string.suffix.result}" # Generate unique bucket name
  tags = {
    Name = "filebrowser-storage"
  }
}

# Generate random string to make bucket name unique
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# ECR Repository for Filebrowser image
resource "aws_ecr_repository" "filebrowser" {
  name                 = "filebrowser"           # Repository name
  image_tag_mutability = "MUTABLE"               # Allow overwriting tags
  force_delete = true                            # Allow deletion even with images present
}

# IAM Role for EC2 instances
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role"

  # Allow EC2 service to assume this role
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

# IAM Policy for S3 access from EC2
resource "aws_iam_policy" "ec2_policy" {
  name = "ec2_policy"

  # Policy to allow access to S3 bucket
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

# Attach S3 policy to EC2 role
resource "aws_iam_role_policy_attachment" "ec2_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ec2_policy.arn
}

# Attach SSM policy for Systems Manager access
resource "aws_iam_role_policy_attachment" "ssm_policy_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # AWS managed policy
}

# IAM Policy for ECS container instances
resource "aws_iam_policy" "ecs_container_instance_policy" {
  name        = "ECSContainerInstancePolicy"
  description = "Permissions for ECS container instance registration and management"

  # Policy allowing ECS agent operations
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecs:RegisterContainerInstance",
          "ecs:DeregisterContainerInstance",
          "ecs:DiscoverPollEndpoint",
          "ecs:Poll",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
          "ecs:SubmitAttachmentStateChange",
          "ecs:SubmitContainerStateChange",
          "ecs:SubmitTaskStateChange",
          "ecs:CreateCluster"
        ],
        Resource = [
          "*",  # Broad permissions - could be scoped down later
        ]
      }
    ]
  })
}

# Attach ECS container instance policy to EC2 role
resource "aws_iam_role_policy_attachment" "ecs_container_instance_attachment" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ecs_container_instance_policy.arn
}

# Attach AWS-managed ECS role to EC2 role
resource "aws_iam_role_policy_attachment" "ecs_ec2_role" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role" # AWS managed policy
}

# Create instance profile (required for EC2 to assume the role)
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile"
  role = aws_iam_role.ec2_role.name
}

# ECS Cluster for running our containers
resource "aws_ecs_cluster" "filebrowser_cluster" {
  name = "filebrowser-cluster"
}

# CloudWatch Log Group for container logs
resource "aws_cloudwatch_log_group" "filebrowser_logs" {
  name              = "/ecs/filebrowser"
  retention_in_days = 7                  # Keep logs for 7 days
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs_execution_role"
  
  # Allow ECS tasks to assume this role
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

# Attach AWS-managed ECS execution policy to task execution role
resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" # AWS managed policy
}

# Add S3 permissions to the ECS execution role
resource "aws_iam_role_policy" "ecs_s3_access" {
  name   = "ecs_s3_access"
  role   = aws_iam_role.ecs_execution_role.id
  
  # Policy to allow S3 access from ECS tasks
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

# ECS Task Definition for Filebrowser
resource "aws_ecs_task_definition" "filebrowser_task" {
  family                   = "filebrowser-task"       # Name for task definition family
  network_mode             = "bridge"                 # Required for EC2 with proper networking
  requires_compatibilities = ["EC2"]                  # Run on EC2 instances, not Fargate
  cpu                      = "256"                    # CPU units allocation
  memory                   = "512"                    # Memory allocation in MB
  task_role_arn            = aws_iam_role.ecs_execution_role.arn  # Role for the task itself
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn  # Role for launching the task

  # Container definitions (JSON format)
  container_definitions = jsonencode([
    {
      name  = "filebrowser"
      image = "${aws_ecr_repository.filebrowser.repository_url}:latest"  # Use our ECR image
      essential = true
      portMappings = [
        {
          containerPort = 80  # Port the container listens on
          hostPort      = 8080  # Port exposed on the host
        }
      ]
      environment = [
        {
          name  = "FB_STORAGE"
          value = "s3://:@us-east-1/${aws_s3_bucket.filebrowser_storage.bucket}"  # S3 storage configuration
        }
      ]
      # Allow privileged mode for FUSE filesystem
      "privileged": true,
      "linuxParameters": {
          "devices": [
              {
                  "hostPath": "/dev/fuse",           # Host FUSE device
                  "containerPath": "/dev/fuse"       # Container FUSE device
              }
          ]
      }
      # CloudWatch logs configuration
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.filebrowser_logs.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "filebrowser"
        }
      }
    }
  ])
}

# Security Group for Filebrowser (firewall rules)
resource "aws_security_group" "filebrowser_sg" {
  vpc_id = aws_vpc.main.id
  name   = "filebrowser-sg"
  
  # Allow incoming traffic on port 8080
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow access from anywhere (not secure for production)
  }

  # Allow incoming traffic on port 8080
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Allow access from anywhere (not secure for production)
  }
  
  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"  # All protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Service with capacity provider
resource "aws_ecs_service" "filebrowser_service" {
  name            = "filebrowser-service"
  cluster         = aws_ecs_cluster.filebrowser_cluster.id
  task_definition = aws_ecs_task_definition.filebrowser_task.arn
  desired_count   = 1                            # Number of tasks to run
  
  # Use capacity provider strategy instead of launch_type
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2_capacity_provider.name
    weight            = 1                        # Full weight to this provider
  }
/* Remove because I'm using bridge from ec2
  # Network configuration for awsvpc mode
  network_configuration {
    subnets          = [aws_subnet.public.id]
    security_groups  = [aws_security_group.filebrowser_sg.id]
    # Note: assign_public_ip is required for fargate launch type
    # assign_public_ip = true
  }
*/
  depends_on = [aws_ecs_task_definition.filebrowser_task]
}

# Build and push Filebrowser Docker image using local-exec
resource "null_resource" "push_filebrowser_image" {
  depends_on = [
    aws_ecr_repository.filebrowser,
    aws_s3_bucket.filebrowser_storage,
    aws_ecs_cluster.filebrowser_cluster,
    aws_ecs_task_definition.filebrowser_task
  ]
  
  # This will run on the machine executing Terraform
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
  "port": 80,
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

USER root

RUN apk add --no-cache s3fs-fuse fuse ca-certificates bash
RUN mkdir -p /srv/s3bucket

RUN echo '#!/bin/bash' > /entrypoint.sh && \
    echo 'set -e' >> /entrypoint.sh && \
    echo 'echo "Mounting S3 bucket: ${aws_s3_bucket.filebrowser_storage.bucket}"' >> /entrypoint.sh && \
    echo 's3fs ${aws_s3_bucket.filebrowser_storage.bucket} /srv/s3bucket -o iam_role=auto -o allow_other -o umask=0022 -o dbglevel=info' >> /entrypoint.sh && \
    echo 'echo "S3 bucket mounted at /srv/s3bucket using IAM role"' >> /entrypoint.sh && \
    echo 'export FB_ROOT=/srv/s3bucket' >> /entrypoint.sh && \
    echo 'exec /filebrowser' >> /entrypoint.sh

RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF
      
      # Authenticate Docker to ECR (with retry logic)
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
      
      # Pull the base image (with retry logic)
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
      
      # Build the custom Docker image (with retry logic)
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
      
      # Push the image to ECR (with retry logic)
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

# Load balancer target group
resource "aws_lb_target_group" "ecs_target_group" {
  name     = "ecs-target-group"
  port     = 80                        # Forward traffic on port 80
  protocol = "HTTP"                    # Using HTTP protocol
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"          # Path to check
    interval            = 30           # Check every 30 seconds
    timeout             = 5            # 5 second timeout
    healthy_threshold   = 2            # Number of consecutive successes before healthy
    unhealthy_threshold = 2            # Number of consecutive failures before unhealthy
    matcher             = "200"        # HTTP code indicating healthy
  }
}

# Fetch the latest Amazon Linux 2023 ECS-Optimized AMI from SSM Parameter Store
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# Launch template for ECS instances in Auto Scaling Group
resource "aws_launch_template" "ecs" {
  name = "ecs-launch-template"

  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = "t3.medium"                # Instance type
  
  # IAM instance profile
  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_instance_profile.name
  }

  # Network configuration
  network_interfaces {
    associate_public_ip_address = true                  # Assign public IP
    subnet_id                   = aws_subnet.public.id  # Place in our public subnet
    security_groups             = [aws_security_group.filebrowser_sg.id]
  }

  # User data script to join ECS cluster
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.filebrowser_cluster.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENGINE_AUTH_TYPE=dockercfg" >> /etc/ecs/ecs.config
    EOF
  )

  # Tags for the instance
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ecs-instance"
    }
  }
}

# Auto Scaling Group for ECS instances
resource "aws_autoscaling_group" "ecs" {
  # Use our launch template
  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  vpc_zone_identifier = [aws_subnet.public.id]  # Subnet to launch in

  min_size         = 1    # Minimum instances
  max_size         = 1    # Maximum instances
  desired_capacity = 1    # Desired number of instances

  # Name tag for instances
  tag {
    key                 = "Name"
    value               = "ecs-instance"
    propagate_at_launch = true  # Apply to launched instances
  }
  
  # Tag for ECS to identify managed instances
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true  # Create new instances before destroying old ones
  }
}

# Attach Auto Scaling Group to target group
resource "aws_autoscaling_attachment" "ecs" {
  autoscaling_group_name = aws_autoscaling_group.ecs.name
  lb_target_group_arn   = aws_lb_target_group.ecs_target_group.arn
}

# ECS capacity provider for EC2 instances
resource "aws_ecs_capacity_provider" "ec2_capacity_provider" {
  name = "ec2-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn
    
    # Managed scaling configuration
    managed_scaling {
      maximum_scaling_step_size = 1    # Max instances to scale up by
      minimum_scaling_step_size = 1    # Min instances to scale up by
      status                    = "ENABLED"
      target_capacity           = 100  # Target utilization percentage
    }
  }
  
  depends_on = [aws_ecs_cluster.filebrowser_cluster]
}

# Associate capacity provider with ECS cluster
resource "aws_ecs_cluster_capacity_providers" "filebrowser_cluster" {
  cluster_name = aws_ecs_cluster.filebrowser_cluster.name
  capacity_providers = [aws_ecs_capacity_provider.ec2_capacity_provider.name]
}

# Outputs for important resource information
output "ecr_repository_url" {
  value = aws_ecr_repository.filebrowser.repository_url
}

output "s3_bucket_name" {
  value = aws_s3_bucket.filebrowser_storage.bucket
}

output "filebrowser_public_ip" {
  value = "After deployment, check the ECS service tasks in the AWS Console for the public IP."
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.ecs.name
}

output "capacity_provider_name" {
  value = aws_ecs_capacity_provider.ec2_capacity_provider.name
}
