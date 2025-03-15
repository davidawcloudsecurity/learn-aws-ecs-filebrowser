# learn-aws-ecs-filebrowser

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
