# Panduan Lengkap Deployment Web App di AWS

## Tahap 1: Setup IAM Roles

### 1.1 Buat Execution Role untuk ECS
```bash
# 1. Buat role
aws iam create-role \
  --role-name staging-web-app-execution-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# 2. Attach managed policy untuk ECS task execution
aws iam attach-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# 3. Tambahkan policy untuk ECR dan CloudWatch Logs
aws iam put-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-name ECRandCloudWatchPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        "Resource": "*"
      }
    ]
  }'
```

### 1.2 Buat Role untuk GitHub Actions
```bash
# 1. Buat role
aws iam create-role \
  --role-name github-actions-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::617692575193:oidc-provider/token.actions.githubusercontent.com"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
          },
          "StringLike": {
            "token.actions.githubusercontent.com:sub": "repo:tarmizy/aws-cloudformation:*"
          }
        }
      }
    ]
  }'

# 2. Tambahkan policy untuk akses ke ECR, ECS, dan IAM
aws iam put-role-policy \
  --role-name github-actions-role \
  --policy-name GitHubActionsPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
          "iam:GetRole",
          "iam:PassRole"
        ],
        "Resource": "*"
      }
    ]
  }'
```

## Tahap 2: Setup GitHub Actions

### 2.1 Tambahkan Secret di GitHub
1. Buka repository GitHub
2. Pergi ke Settings > Secrets and variables > Actions
3. Klik "New repository secret"
4. Tambahkan secret:
   - Name: `AWS_ROLE_ARN`
   - Value: `arn:aws:iam::617692575193:role/github-actions-role`

### 2.2 Buat Workflow File
```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [ main ]
    paths-ignore:
      - '**.md'
      - '.gitignore'
      - 'LICENSE'

env:
  AWS_REGION: ap-southeast-1
  ECR_REPOSITORY: web-app
  ECS_CLUSTER: staging-web-app-cluster
  ECS_SERVICE: staging-web-app
  STACK_NAME: web-app
  ENVIRONMENT: staging

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
    - name: Checkout code
      uses: actions/checkout@v3

    - name: Configure AWS credentials
      uses: aws-actions/configure-aws-credentials@v2
      with:
        role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
        aws-region: ${{ env.AWS_REGION }}

    - name: Login to Amazon ECR
      id: login-ecr
      uses: aws-actions/amazon-ecr-login@v1

    - name: Build and push image to ECR
      id: build-image
      env:
        ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
        IMAGE_TAG: ${{ env.ENVIRONMENT }}-${{ github.sha }}
      run: |
        docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
        docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
        echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

    - name: Update ECS Service
      run: |
        TASK_DEF=$(aws ecs describe-task-definition \
          --task-definition staging-web-app \
          --query 'taskDefinition' \
          --output json)
        
        EXECUTION_ROLE_ARN=$(aws iam get-role \
          --role-name staging-web-app-execution-role \
          --query 'Role.Arn' \
          --output text)

        echo "Creating new task definition using image: ${{ steps.build-image.outputs.image }}"
        NEW_TASK_DEF=$(echo $TASK_DEF | jq \
          --arg IMAGE "${{ steps.build-image.outputs.image }}" \
          --arg EXEC_ROLE "$EXECUTION_ROLE_ARN" \
          '.containerDefinitions[0].image = $IMAGE | .executionRoleArn = $EXEC_ROLE')

        NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
          --family staging-web-app \
          --requires-compatibilities FARGATE \
          --network-mode awsvpc \
          --cpu 512 \
          --memory 1024 \
          --execution-role-arn $EXECUTION_ROLE_ARN \
          --task-role-arn $EXECUTION_ROLE_ARN \
          --container-definitions "[{
            \"name\": \"web-app\",
            \"image\": \"${{ steps.build-image.outputs.image }}\",
            \"portMappings\": [{
              \"containerPort\": 80,
              \"hostPort\": 80,
              \"protocol\": \"tcp\"
            }],
            \"essential\": true,
            \"logConfiguration\": {
              \"logDriver\": \"awslogs\",
              \"options\": {
                \"awslogs-group\": \"/ecs/staging-web-app\",
                \"awslogs-region\": \"${{ env.AWS_REGION }}\",
                \"awslogs-stream-prefix\": \"ecs\"
              }
            }
          }]" \
          --query 'taskDefinition.taskDefinitionArn' \
          --output text)

        echo "Updating ECS service..."
        aws ecs update-service \
          --cluster $ECS_CLUSTER \
          --service $ECS_SERVICE \
          --task-definition $NEW_TASK_DEF_ARN \
          --force-new-deployment
```

## Tahap 3: Deploy Infrastructure dengan CloudFormation

### 3.1 Buat CloudFormation Template
```yaml
# template.yml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Web Application Infrastructure'

Parameters:
  Environment:
    Type: String
    Default: staging
    AllowedValues:
      - staging
      - production
    Description: Environment name

Resources:
  # VPC
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub ${AWS::StackName}-vpc

  # Public Subnets
  PublicSubnet1:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Select [0, !GetAZs '']
      CidrBlock: 10.0.1.0/24
      MapPublicIpOnLaunch: true

  PublicSubnet2:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref VPC
      AvailabilityZone: !Select [1, !GetAZs '']
      CidrBlock: 10.0.2.0/24
      MapPublicIpOnLaunch: true

  # Internet Gateway
  InternetGateway:
    Type: AWS::EC2::InternetGateway

  AttachGateway:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway

  # Route Table
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC

  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: AttachGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnet1RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet1
      RouteTableId: !Ref PublicRouteTable

  PublicSubnet2RouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet2
      RouteTableId: !Ref PublicRouteTable

  # Security Groups
  ALBSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for ALB
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          CidrIp: 0.0.0.0/0

  ECSSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for ECS tasks
      VpcId: !Ref VPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 80
          ToPort: 80
          SourceSecurityGroupId: !Ref ALBSecurityGroup

  # Load Balancer
  ApplicationLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Subnets:
        - !Ref PublicSubnet1
        - !Ref PublicSubnet2
      SecurityGroups:
        - !Ref ALBSecurityGroup

  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      HealthCheckPath: /
      HealthCheckIntervalSeconds: 30
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      Port: 80
      Protocol: HTTP
      TargetType: ip
      VpcId: !Ref VPC

  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref TargetGroup
      LoadBalancerArn: !Ref ApplicationLoadBalancer
      Port: 80
      Protocol: HTTP

  # ECS Cluster
  ECSCluster:
    Type: AWS::ECS::Cluster
    Properties:
      ClusterName: !Sub ${AWS::StackName}-${Environment}-cluster

  # ECS Service
  ECSService:
    Type: AWS::ECS::Service
    DependsOn: Listener
    Properties:
      ServiceName: !Sub ${AWS::StackName}-${Environment}
      Cluster: !Ref ECSCluster
      TaskDefinition: !Ref TaskDefinition
      DesiredCount: 1
      LaunchType: FARGATE
      NetworkConfiguration:
        AwsvpcConfiguration:
          AssignPublicIp: ENABLED
          SecurityGroups:
            - !Ref ECSSecurityGroup
          Subnets:
            - !Ref PublicSubnet1
            - !Ref PublicSubnet2
      LoadBalancers:
        - ContainerName: web-app
          ContainerPort: 80
          TargetGroupArn: !Ref TargetGroup

  # Task Definition
  TaskDefinition:
    Type: AWS::ECS::TaskDefinition
    Properties:
      Family: !Sub ${AWS::StackName}-${Environment}
      RequiresCompatibilities:
        - FARGATE
      NetworkMode: awsvpc
      Cpu: 512
      Memory: 1024
      ExecutionRoleArn: !Sub arn:aws:iam::${AWS::AccountId}:role/staging-web-app-execution-role
      TaskRoleArn: !Sub arn:aws:iam::${AWS::AccountId}:role/staging-web-app-execution-role
      ContainerDefinitions:
        - Name: web-app
          Image: !Sub ${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/web-app:${Environment}
          PortMappings:
            - ContainerPort: 80
              Protocol: tcp
          LogConfiguration:
            LogDriver: awslogs
            Options:
              awslogs-group: !Ref LogGroup
              awslogs-region: !Ref AWS::Region
              awslogs-stream-prefix: ecs

  # CloudWatch Logs
  LogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub /ecs/${AWS::StackName}-${Environment}
      RetentionInDays: 30

Outputs:
  ServiceURL:
    Description: URL of the load balancer
    Value: !Sub http://${ApplicationLoadBalancer.DNSName}

  ClusterName:
    Description: Name of the ECS cluster
    Value: !Ref ECSCluster

  ServiceName:
    Description: Name of the ECS service
    Value: !Ref ECSService
```

### 3.2 Deploy Stack
```bash
# Deploy stack
aws cloudformation create-stack \
  --stack-name web-app \
  --template-body file://template.yml \
  --capabilities CAPABILITY_NAMED_IAM

# Monitor deployment
aws cloudformation wait stack-create-complete --stack-name web-app

# Get outputs
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs'
```

## Tahap 4: Verifikasi Deployment

### 4.1 Cek Status Resources
```bash
# Cek ECS service
aws ecs describe-services \
  --cluster staging-web-app-cluster \
  --services staging-web-app

# Cek running tasks
aws ecs list-tasks \
  --cluster staging-web-app-cluster \
  --service-name staging-web-app

# Cek logs
aws logs get-log-events \
  --log-group-name /ecs/staging-web-app \
  --log-stream-name $(aws ecs list-tasks --cluster staging-web-app-cluster --service-name staging-web-app --query 'taskArns[0]' --output text | cut -d'/' -f3)
```

## Tahap 5: Testing Continuous Deployment

### 5.1 Update Aplikasi
```bash
# 1. Clone repository (jika belum)
git clone https://github.com/[username]/aws-cloudformation.git
cd aws-cloudformation

# 2. Buat branch baru (opsional)
git checkout -b update-brand-name

# 3. Update file (contoh: index.html)
# Update navbar brand dari "Winner to Bejo" menjadi "Winner Bro"

# 4. Commit dan push perubahan
git add index.html
git commit -m "Update brand name to Winner Bro"
git push origin main  # atau nama branch jika menggunakan branch

# 5. Monitor GitHub Actions
- Buka repository di GitHub
- Klik tab "Actions"
- Lihat workflow run terbaru
```

### 5.2 Verifikasi Deployment
```bash
# 1. Tunggu GitHub Actions selesai

# 2. Cek status ECS service
aws ecs describe-services \
  --cluster web-app-staging-cluster \
  --services web-app-staging \
  --query 'services[0].{status:status,desiredCount:desiredCount,runningCount:runningCount,events:events[0:3]}'

# 3. Tunggu service steady state
aws ecs wait services-stable \
  --cluster web-app-staging-cluster \
  --services web-app-staging

# 4. Dapatkan URL aplikasi
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text

# 5. Cek aplikasi di browser
# Buka URL dari langkah 4 di browser dan verifikasi perubahan
```

### 5.3 Troubleshooting Deployment
```bash
# 1. Cek GitHub Actions logs
- Buka workflow run yang gagal
- Expand step yang error
- Baca error message

# 2. Cek ECS events
aws ecs describe-services \
  --cluster web-app-staging-cluster \
  --services web-app-staging \
  --query 'services[0].events[0:5]'

# 3. Cek container logs
# Dapatkan task ID
TASK_ID=$(aws ecs list-tasks \
  --cluster web-app-staging-cluster \
  --service-name web-app-staging \
  --query 'taskArns[0]' \
  --output text | cut -d'/' -f3)

# Lihat logs
aws logs get-log-events \
  --log-group-name /ecs/web-app-staging \
  --log-stream-name ecs/web-app/$TASK_ID

# 4. Cek task status
aws ecs describe-tasks \
  --cluster web-app-staging-cluster \
  --tasks $TASK_ID
```

## Ringkasan Simulasi Deployment

### 1. Setup Awal
- [x] Buat IAM roles (execution role & GitHub Actions role)
- [x] Setup GitHub repository dengan secrets
- [x] Siapkan GitHub Actions workflow

### 2. Deploy Infrastructure
- [x] Deploy CloudFormation stack
- [x] Verifikasi resource creation
- [x] Cek service status

### 3. Deploy Aplikasi
- [x] Push kode ke repository
- [x] Monitor GitHub Actions workflow
- [x] Verifikasi deployment

### 4. Testing
- [x] Update aplikasi (brand name)
- [x] Verifikasi continuous deployment
- [x] Cek perubahan di production

### 5. Maintenance
- [ ] Monitor logs dan metrics
- [ ] Setup alerts (opsional)
- [ ] Backup dan restore strategy (opsional)

## Checklist Deployment Berhasil
- [ ] CloudFormation stack status: CREATE_COMPLETE
- [ ] ECS service status: ACTIVE
- [ ] Task count: desired = running
- [ ] Application accessible via ALB URL
- [ ] GitHub Actions workflow: success
- [ ] Brand name updated: "Winner Bro"
- [ ] No error logs in CloudWatch

## Clean Up (Optional)
```bash
# 1. Delete CloudFormation stack
aws cloudformation delete-stack --stack-name web-app

# 2. Wait for deletion
aws cloudformation wait stack-delete-complete --stack-name web-app

# 3. Delete IAM roles
aws iam detach-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

aws iam delete-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-name ECRandCloudWatchPolicy

aws iam delete-role \
  --role-name staging-web-app-execution-role

# 4. Delete ECR images (optional)
aws ecr batch-delete-image \
  --repository-name web-app \
  --image-ids "$(aws ecr list-images \
    --repository-name web-app \
    --query 'imageIds[*]' \
    --output json)"
```
