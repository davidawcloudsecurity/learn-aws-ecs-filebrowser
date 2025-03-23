# learn-aws-ecs-filebrowser
https://github.com/filebrowser/filebrowser/tree/master

### Use s3 as a mnt for linux
https://github.com/s3fs-fuse/s3fs-fuse

## https://developer.hashicorp.com/terraform/install
Install if running at cloudshell
```ruby
alias k=kubectl; alias tf="terraform"; alias tfa="terraform apply --auto-approve"; alias tfd="terraform destroy --auto-approve"; alias tfm="terraform init; terraform fmt; terraform validate; terraform plan"; sudo yum install -y yum-utils shadow-utils; sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo; sudo yum -y install terraform; terraform init
```
### How to Use This

1. **Set Up Terraform**:
   - Install Terraform: [Terraform Installation Guide](https://www.terraform.io/downloads.html)
   - Configure AWS CLI with your credentials: `aws configure`

2. **Deploy the Infrastructure**:
   - Save the script as `main.tf`.
   - Run:
     ```bash
     terraform init
     terraform plan
     terraform apply
     ```
   - Type `yes` when prompted to confirm.

3. **Build and Push the Filebrowser Image**:
   - After `terraform apply`, note the `ecr_repository_url` output.
   - Build the Filebrowser Docker image locally:
     ```bash
     docker build -t filebrowser https://github.com/filebrowser/filebrowser.git
     ```
   - Tag and push it to ECR (replace `<ecr_url>` with the output):
     ```bash
     aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ecr_url>
     docker tag filebrowser:latest <ecr_url>:latest
     docker push <ecr_url>:latest
     ```
     To clean up Docker images and containers, you can use the following commands:

1. To remove all stopped containers:
```sh
docker container prune
```

2. To remove all unused images:
```sh
docker image prune -a
```

3. To remove all unused volumes:
```sh
docker volume prune
```

4. To remove all unused networks:
```sh
docker network prune
```

If you want to remove everything (containers, images, volumes, and networks) that is not currently used, you can run:
```sh
docker system prune -a
```

Note: Using `docker system prune -a` will remove all unused images, containers, volumes, and networks. Be cautious when using this command, as it will delete a lot of data that might still be needed.

### Working ECS cluster with ECS optimized EC2
```
# Define the AWS provider and region
provider "aws" {
  region = "us-east-1"  # Adjust to your desired AWS region
}

# Variables for subnet IDs and security group IDs
variable "subnet_ids" {
  type        = list(string)
  description = "List of subnet IDs for the Auto Scaling group"
}

variable "security_group_ids" {
  type        = list(string)
  description = "List of existing security group IDs to associate with the ECS instances"
}

# Create the ECS cluster
resource "aws_ecs_cluster" "main" {
  name = "my-ecs-cluster"
}

# IAM role for ECS instances
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs_instance_role"

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

# Attach the ECS instance policy to the role
resource "aws_iam_role_policy_attachment" "ecs_instance_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Create an instance profile for the IAM role
resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs_instance_profile"
  role = aws_iam_role.ecs_instance_role.name
}

# Fetch the latest Amazon Linux 2023 ECS-Optimized AMI from SSM Parameter Store
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# Launch template for ECS instances
resource "aws_launch_template" "ecs_instances" {
  name_prefix   = "ecs-instances-"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = "t3.medium"  # Adjust instance type as needed

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true  # Set to false if using private subnets
    security_groups             = var.security_group_ids
  }

  # User data to configure the ECS agent to join the cluster
  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
              EOF
  )
}

# Auto Scaling group for ECS instances
resource "aws_autoscaling_group" "ecs_instances" {
  launch_template {
    id      = aws_launch_template.ecs_instances.id
    version = "$Latest"
  }

  min_size         = 1
  max_size         = 3
  desired_capacity = 1

  vpc_zone_identifier = var.subnet_ids

  tag {
    key                 = "Name"
    value               = "ecs-instance"
    propagate_at_launch = true
  }
}
```
