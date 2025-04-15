# CloudFormation Template Guide

## Overview

Template CloudFormation ini mendefinisikan infrastruktur AWS untuk menjalankan aplikasi web di ECS Fargate dengan load balancer.

## Architecture Diagram

```mermaid
graph TD
    ALB[Application Load Balancer] --> TG[Target Group]
    TG --> ECS[ECS Service]
    ECS --> TASK[ECS Tasks]
    TASK --> ECR[ECR Repository]
    TASK --> CW[CloudWatch Logs]
    VPC[VPC] --> SUBNET1[Public Subnet 1]
    VPC --> SUBNET2[Public Subnet 2]
    SUBNET1 --> ALB
    SUBNET2 --> ALB
    SUBNET1 --> TASK
    SUBNET2 --> TASK
```

## Template Structure

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: ECS Fargate stack with ALB

Parameters:
  # Network Configuration
  VpcId:
    Type: AWS::EC2::VPC::Id
  SubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
  
  # Application Configuration
  ServiceName:
    Type: String
    Default: staging-web-app
  ContainerPort:
    Type: Number
    Default: 80

Resources:
  # Security Groups
  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ALB Security Group
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0

  ECSSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: ECS Tasks Security Group
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: !Ref ContainerPort
          ToPort: !Ref ContainerPort
          SourceSecurityGroupId: !Ref ALBSecurityGroup

  # Load Balancer
  ApplicationLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Scheme: internet-facing
      LoadBalancerAttributes:
        - Key: idle_timeout.timeout_seconds
          Value: '60'
      SecurityGroups:
        - !Ref ALBSecurityGroup
      Subnets: !Ref SubnetIds

  # Target Group
  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      HealthCheckIntervalSeconds: 30
      HealthCheckPath: /
      HealthCheckProtocol: HTTP
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      TargetType: ip
      Port: !Ref ContainerPort
      Protocol: HTTP
      UnhealthyThresholdCount: 5
      VpcId: !Ref VpcId

  # Listener
  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      DefaultActions:
        - TargetGroupArn: !Ref TargetGroup
          Type: forward
      LoadBalancerArn: !Ref ApplicationLoadBalancer
      Port: 80
      Protocol: HTTP

  # ECS Cluster
  ECSCluster:
    Type: AWS::ECS::Cluster
    Properties:
      ClusterName: !Ref ServiceName
      ClusterSettings:
        - Name: containerInsights
          Value: enabled

  # ECS Service
  ECSService:
    Type: AWS::ECS::Service
    Properties:
      Cluster: !Ref ECSCluster
      DesiredCount: 2
      LaunchType: FARGATE
      TaskDefinition: !Ref TaskDefinition
      ServiceName: !Ref ServiceName
      NetworkConfiguration:
        AwsvpcConfiguration:
          AssignPublicIp: ENABLED
          SecurityGroups:
            - !Ref ECSSecurityGroup
          Subnets: !Ref SubnetIds
      LoadBalancers:
        - ContainerName: web-app
          ContainerPort: !Ref ContainerPort
          TargetGroupArn: !Ref TargetGroup

Outputs:
  ServiceURL:
    Description: URL of the load balancer
    Value: !Sub http://${ApplicationLoadBalancer.DNSName}
  ServiceARN:
    Description: ARN of the ECS service
    Value: !Ref ECSService
  ClusterARN:
    Description: ARN of the ECS cluster
    Value: !Ref ECSCluster
```

## Key Components

### 1. Network Configuration
- VPC dan Subnet selection
- Security Groups untuk ALB dan ECS tasks
- Public subnets untuk internet-facing ALB

### 2. Load Balancer Setup
- Application Load Balancer
- Target Group dengan health checks
- HTTP Listener pada port 80

### 3. ECS Configuration
- ECS Cluster dengan Container Insights
- Fargate Service dengan desired count 2
- Task Definition dengan container configuration

## Deployment Steps

### 1. Validasi Template

```bash
# Validasi syntax template
aws cloudformation validate-template \
  --template-body file://template.yaml \
  --region REGION
```

### 2. Create Stack

```bash
# Deploy stack baru
aws cloudformation create-stack \
  --stack-name web-app \
  --template-body file://template.yaml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxx \
    ParameterKey=SubnetIds,ParameterValue=subnet-xxxxx\\,subnet-yyyyy \
  --capabilities CAPABILITY_IAM \
  --region REGION
```

### 3. Update Stack

```bash
# Update existing stack
aws cloudformation update-stack \
  --stack-name web-app \
  --template-body file://template.yaml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxx \
    ParameterKey=SubnetIds,ParameterValue=subnet-xxxxx\\,subnet-yyyyy \
  --capabilities CAPABILITY_IAM \
  --region REGION
```

### 4. Monitor Stack

```bash
# Monitor stack events
aws cloudformation describe-stack-events \
  --stack-name web-app \
  --region REGION

# Get stack outputs
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs' \
  --region REGION
```

## Parameter Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| VpcId | ID of the VPC | Required |
| SubnetIds | List of subnet IDs | Required |
| ServiceName | Name of the ECS service | staging-web-app |
| ContainerPort | Container port | 80 |

## Best Practices

### 1. Security
- Use security groups to restrict access
- Enable Container Insights for monitoring
- Configure proper health checks
- Use private subnets when possible

### 2. High Availability
- Deploy across multiple AZs
- Use multiple tasks for redundancy
- Configure proper health check thresholds

### 3. Monitoring
- Enable Container Insights
- Set up CloudWatch alarms
- Monitor service metrics

### 4. Cost Optimization
- Use Fargate Spot for non-critical workloads
- Right-size task resources
- Monitor and adjust capacity

## Troubleshooting

### 1. Stack Creation Fails
- Check VPC/Subnet configuration
- Verify IAM permissions
- Review CloudFormation events

### 2. Service Won't Start
- Check security group rules
- Verify subnet configuration
- Review task definition

### 3. Health Checks Failing
- Verify application is responding
- Check security group rules
- Review health check settings

## Related Documentation

- [TASK_DEFINITION_GUIDE.md](./TASK_DEFINITION_GUIDE.md) - ECS Task Definition configuration
- [GITHUB_ACTIONS_GUIDE.md](./GITHUB_ACTIONS_GUIDE.md) - CI/CD pipeline
- [role-aws/](../role-aws/) - IAM roles and policies

## Updates and Maintenance

1. **Version Control**
   - Keep template in version control
   - Document all changes
   - Use change sets for updates

2. **Testing**
   - Test in development environment
   - Use change sets to preview changes
   - Validate template before deployment

3. **Backup and Recovery**
   - Keep template backups
   - Document rollback procedures
   - Test recovery processes
