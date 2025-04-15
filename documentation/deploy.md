# Web Application Deployment with AWS CloudFormation

This CloudFormation template deploys a containerized web application using AWS ECS Fargate with Application Load Balancer.

## Architecture Overview

The stack creates the following AWS resources:

- **VPC and Networking**:
  - VPC with CIDR 172.31.0.0/16
  - 2 Public Subnets in different Availability Zones
  - Internet Gateway
  - Route Tables and necessary routes

- **Security**:
  - ALB Security Group (allows inbound HTTP traffic)
  - ECS Security Group (allows inbound traffic from ALB)

- **ECS Infrastructure**:
  - ECS Cluster running on Fargate
  - Task Definition configured for ARM64 architecture
  - ECS Service with 2 desired tasks
  - Task Execution IAM Role with ECR access

- **Load Balancer**:
  - Application Load Balancer
  - Target Group with health checks
  - HTTP Listener on port 80

- **Monitoring**:
  - CloudWatch Log Group for container logs

## Prerequisites

1. AWS CLI installed and configured
2. Docker image pushed to Amazon ECR repository
3. Sufficient IAM permissions to create the resources

## Parameters

The template accepts the following parameters:

- `Environment`: Environment name (staging/production)
- `ContainerImage`: ECR Image URI
- `ContainerPort`: Container port (default: 80)
- `HealthCheckPath`: ALB health check path (default: /)

## Deployment Instructions

1. **Create an ECR repository and push your image** (if not already done):
   ```bash
   aws ecr create-repository --repository-name web-app --region ap-southeast-1
   ```

2. **Deploy the stack**:
   ```bash
   aws cloudformation create-stack \
     --stack-name web-app \
     --template-body file://template.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameters \
       ParameterKey=Environment,ParameterValue=staging \
       ParameterKey=ContainerImage,ParameterValue=YOUR_ECR_IMAGE_URI
   ```

3. **Monitor the stack creation**:
   ```bash
   aws cloudformation describe-stacks --stack-name web-app
   ```

## Accessing the Application

Once the stack is created successfully, you can access the application using the LoadBalancer DNS name, which is available in the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text
```

## Updating the Application

To deploy a new version of your application:

1. **Build and Push New Image**:
   ```bash
   # Build new image
   docker build -t web-app:latest .

   # Tag image for ECR
   docker tag web-app:latest 617692575193.dkr.ecr.ap-southeast-1.amazonaws.com/web-app:latest

   # Login to ECR
   aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 617692575193.dkr.ecr.ap-southeast-1.amazonaws.com

   # Push image to ECR
   docker push 617692575193.dkr.ecr.ap-southeast-1.amazonaws.com/web-app:latest
   ```

2. **Update ECS Service**:
   ```bash
   # Register new task definition with updated image
   aws ecs register-task-definition \
     --cli-input-json file://task-definition.json \
     --region ap-southeast-1

   # Update service to use new task definition
   aws ecs update-service \
     --cluster staging-web-app-cluster \
     --service staging-web-app \
     --task-definition staging-web-app:NEW_REVISION \
     --force-new-deployment \
     --region ap-southeast-1

   # Monitor deployment
   aws ecs describe-services \
     --cluster staging-web-app-cluster \
     --services staging-web-app \
     --region ap-southeast-1
   ```

3. **Verify Deployment**:
   ```bash
   # Check running tasks
   aws ecs list-tasks \
     --cluster staging-web-app-cluster \
     --service-name staging-web-app \
     --desired-status RUNNING \
     --region ap-southeast-1

   # View task details to confirm new image
   aws ecs describe-tasks \
     --cluster staging-web-app-cluster \
     --tasks TASK_ARN \
     --region ap-southeast-1

   # Test application
   curl -v http://YOUR_ALB_DNS_NAME
   ```

## Monitoring and Troubleshooting

1. **View Container Logs**:
   ```bash
   aws logs get-log-events \
     --log-group-name /ecs/staging-web-app \
     --log-stream-name ecs/web-app/TASK_ID
   ```

2. **Check Service Status**:
   ```bash
   # View service details
   aws ecs describe-services \
     --cluster staging-web-app-cluster \
     --services staging-web-app \
     --region ap-southeast-1

   # List running tasks
   aws ecs list-tasks \
     --cluster staging-web-app-cluster \
     --service-name staging-web-app \
     --desired-status RUNNING \
     --region ap-southeast-1

   # View task details
   aws ecs describe-tasks \
     --cluster staging-web-app-cluster \
     --tasks TASK_ARN \
     --region ap-southeast-1
   ```

3. **View Load Balancer Status**:
   ```bash
   # Get load balancer details
   aws elbv2 describe-load-balancers \
     --region ap-southeast-1

   # Test the application
   curl -v http://YOUR_ALB_DNS_NAME
   ```

## Cleanup

To delete all resources created by this stack:

```bash
aws cloudformation delete-stack --stack-name web-app
```

## Security Considerations

- The template creates public subnets and an internet-facing ALB
- Security groups are configured to allow only necessary traffic
- ECR repository access is restricted to the ECS task execution role
- Container logs are sent to CloudWatch Logs

## Cost Considerations

This stack includes the following billable resources:
- Application Load Balancer
- ECS Fargate tasks
- CloudWatch Logs
- NAT Gateway (if used)
- Data transfer

## Support

For issues and questions, please create an issue in the repository.
