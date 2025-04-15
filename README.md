# Simple Stack Deployment Guide

## Overview
This guide provides detailed instructions for deploying an NGINX application using AWS CloudFormation with ECS Fargate. The deployment uses existing VPC infrastructure and sets up a fully managed container environment with auto-scaling capabilities.

## Prerequisites
- AWS CLI installed and configured
- Existing VPC with at least two public subnets
- AWS credentials with appropriate permissions
- Basic understanding of AWS services (ECS, CloudFormation, VPC)

## Architecture Components
The stack creates the following AWS resources:
- ECS Cluster
- ECS Service with Fargate launch type
- Application Load Balancer (ALB)
- Target Groups
- Security Groups
- IAM Roles
- CloudWatch Log Groups

## Quick Start
1. **Verify VPC and Subnet IDs**
   ```bash
   # List available VPCs
   aws ec2 describe-vpcs
   
   # List subnets in your VPC
   aws ec2 describe-subnets --filters "Name=vpc-id,Values=<your-vpc-id>"
   ```

2. **Deploy the Stack**
   ```bash
   aws cloudformation create-stack \
     --stack-name nginx-stack \
     --template-body file://nginx-stack.yaml \
     --capabilities CAPABILITY_IAM \
     --region ap-southeast-1
   ```

3. **Monitor Deployment**
   ```bash
   # Check stack status
   aws cloudformation describe-stacks --stack-name nginx-stack

   # Monitor stack events
   aws cloudformation describe-stack-events --stack-name nginx-stack
   ```

## Configuration Parameters
- `EnvironmentName`: Environment prefix for resources (default: staging)
- VPC Configuration is hardcoded in the template:
  - VPC ID: vpc-0db6da161162b090c
  - Subnet 1: subnet-06626adcaa27c52df (ap-southeast-1a)
  - Subnet 2: subnet-0273e03ea9c24e42a (ap-southeast-1b)

## Resource Specifications
1. **ECS Task Definition**
   - CPU: 512 (0.5 vCPU)
   - Memory: 1024MB (1GB)
   - Container Image: public.ecr.aws/nginx/nginx:1.24
   - Port Mapping: 80

2. **ECS Service**
   - Desired Count: 2
   - Platform Version: LATEST
   - Deployment Configuration:
     - Maximum Percent: 200
     - Minimum Healthy Percent: 100
     - Circuit Breaker: Enabled with auto-rollback

3. **Load Balancer**
   - Type: Application Load Balancer
   - Listener: HTTP/80
   - Health Check Path: /
   - Health Check Grace Period: 60 seconds

4. **Security Groups**
   - ALB Security Group: Allows inbound HTTP (80)
   - ECS Security Group: Allows inbound from ALB

5. **Logging**
   - CloudWatch Log Group: /ecs/${EnvironmentName}-nginx
   - Retention Period: 30 days

## Updating the Stack
To update existing stack configuration:
```bash
aws cloudformation update-stack \
  --stack-name nginx-stack \
  --template-body file://nginx-stack.yaml \
  --capabilities CAPABILITY_IAM \
  --region ap-southeast-1
```

## Monitoring and Troubleshooting

1. **Check ECS Service Status**
   ```bash
   aws ecs describe-services \
     --cluster prod-nginx-cluster \
     --services prod-nginx
   ```

2. **View Container Logs**
   ```bash
   aws logs get-log-events \
     --log-group-name /ecs/prod-nginx \
     --log-stream-name <log-stream-name>
   ```

3. **Check Target Health**
   ```bash
   aws elbv2 describe-target-health \
     --target-group-arn <target-group-arn>
   ```

## Cleanup
To delete the stack and all associated resources:
```bash
aws cloudformation delete-stack \
  --stack-name nginx-stack \
  --region ap-southeast-1

# Verify deletion
aws cloudformation describe-stacks \
  --stack-name nginx-stack \
  --region ap-southeast-1
```

## Security Considerations
1. The ALB is internet-facing but only accepts HTTP traffic on port 80
2. ECS tasks run in private subnets with outbound internet access
3. Security groups follow the principle of least privilege
4. IAM roles use minimal required permissions

## Best Practices
1. Always verify resource configurations before deployment
2. Monitor CloudWatch logs for application issues
3. Use parameter store for sensitive configurations
4. Implement HTTPS for production environments
5. Regular security patches and updates

## Troubleshooting Common Issues
1. **Task Failed to Start**
   - Check CloudWatch logs
   - Verify security group configurations
   - Ensure VPC has internet connectivity

2. **Health Checks Failing**
   - Verify application is running on port 80
   - Check security group allows ALB traffic
   - Review health check settings

3. **Stack Creation Fails**
   - Check IAM permissions
   - Verify VPC/subnet configurations
   - Review CloudFormation events for specific errors

## Support
For issues and questions:
1. Check CloudFormation events
2. Review ECS service events
3. Analyze CloudWatch logs
4. Verify security group configurations

## License
This project is licensed under the MIT License - see the LICENSE file for details.
