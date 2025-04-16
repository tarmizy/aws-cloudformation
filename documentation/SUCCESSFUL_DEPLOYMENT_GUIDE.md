# Panduan Step-by-Step Deployment yang Berhasil

## Persiapan Awal

### 1. Setup Repository

```bash
# Clone repository
git clone <repository-url>
cd aws-cloudformation

# Checkout ke commit yang berhasil (opsional)
git checkout 31499d7
```

### 2. Setup AWS Resources

```bash
# Set environment variables
export AWS_REGION=ap-southeast-1
export ENVIRONMENT=staging
export STACK_NAME=web-app
```

## Step-by-Step Deployment

### 1. Create ECR Repository

```bash
# Create ECR repository
aws ecr create-repository \
  --repository-name web-app \
  --region $AWS_REGION
```

### 2. Setup IAM Roles

```bash
# 1. Hapus roles yang mungkin sudah ada (opsional, jika deployment sebelumnya gagal)
aws iam delete-role --role-name staging-web-app-execution-role || true
aws iam delete-role --role-name staging-web-app-task-role || true

# 2. Tunggu beberapa detik untuk propagasi
sleep 10

# 3. Buat roles baru jika diperlukan
aws iam create-role \
  --role-name staging-web-app-task-role \
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

aws iam attach-role-policy \
  --role-name staging-web-app-task-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
```

### 3. Build dan Push Docker Image

```bash
# Login ke ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin 617692575193.dkr.ecr.$AWS_REGION.amazonaws.com

# Build image
docker build -t web-app .

# Tag image
docker tag web-app:latest 617692575193.dkr.ecr.$AWS_REGION.amazonaws.com/web-app:staging

# Push image
docker push 617692575193.dkr.ecr.$AWS_REGION.amazonaws.com/web-app:staging
```

### 4. Deploy CloudFormation Stack

```bash
# 1. Hapus stack yang mungkin gagal sebelumnya
aws cloudformation delete-stack --stack-name web-app --region ap-southeast-1
aws cloudformation wait stack-delete-complete --stack-name web-app --region ap-southeast-1

# 2. Deploy stack baru
aws cloudformation create-stack \
  --stack-name web-app \
  --template-body file://template.yaml \
  --parameters \
    ParameterKey=Environment,ParameterValue=staging \
    ParameterKey=ContainerImage,ParameterValue=617692575193.dkr.ecr.ap-southeast-1.amazonaws.com/web-app:staging \
    ParameterKey=ContainerPort,ParameterValue=80 \
    ParameterKey=HealthCheckPath,ParameterValue=/ \
  --capabilities CAPABILITY_NAMED_IAM \
  --region ap-southeast-1

# 3. Monitor stack creation
watch -n 10 'aws cloudformation describe-stack-events \
  --stack-name web-app \
  --query "StackEvents[0].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
  --output table \
  --region ap-southeast-1'

# 4. Jika terjadi ROLLBACK, cek error dengan:
aws cloudformation describe-stack-events \
  --stack-name web-app \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
  --region ap-southeast-1
```

### 5. Update ECS Service

```bash
# 1. Cek nama cluster yang tersedia
aws ecs list-clusters --region ap-southeast-1

# Expected output:
# {
#     "clusterArns": [
#         "arn:aws:ecs:ap-southeast-1:YOUR_ACCOUNT_ID:cluster/staging-web-app-cluster"
#     ]
# }

# 2. Cek services yang ada di cluster
aws ecs list-services \
  --cluster staging-web-app-cluster \
  --region ap-southeast-1

# Expected output:
# {
#     "serviceArns": [
#         "arn:aws:ecs:ap-southeast-1:YOUR_ACCOUNT_ID:service/staging-web-app-cluster/staging-web-app"
#     ]
# }

# 3. Update service dengan task definition baru
aws ecs update-service \
  --cluster staging-web-app-cluster \
  --service staging-web-app \
  --task-definition web-app-staging \
  --region ap-southeast-1

# 4. Monitor status deployment
aws ecs describe-services \
  --cluster staging-web-app-cluster \
  --services staging-web-app \
  --region ap-southeast-1

# Cek status di bagian deployments[].rolloutState:
# - "IN_PROGRESS": Deployment sedang berjalan
# - "COMPLETED": Deployment berhasil
# - "FAILED": Deployment gagal

# Jika deployment gagal, cek events[] untuk detail error
```

### Common Issues

1. **Cluster Not Found**
   - Error: `ClusterNotFoundException`
   - Solution: Gunakan `aws ecs list-clusters` untuk mendapatkan nama cluster yang benar

2. **Service Not Found**
   - Error: `ServiceNotFoundException`
   - Solution: Gunakan `aws ecs list-services --cluster CLUSTER_NAME` untuk mendapatkan nama service yang benar

3. **Task Definition Error**
   - Error: `Invalid type for parameter taskRoleArn`
   - Solution: 
     - Pastikan task definition memiliki `taskRoleArn` yang valid
     - Lihat [TASK_DEFINITION_GUIDE.md](./TASK_DEFINITION_GUIDE.md) untuk detail konfigurasi

4. **Deployment Stuck**
   - Cek status dengan `describe-services`
   - Review events[] untuk melihat detail error
   - Pastikan task dapat mengakses ECR dan memiliki permission yang cukup

### 6. Verifikasi Deployment

```bash
# Get service URL
SERVICE_URL=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text)

# Test endpoint
curl -v $SERVICE_URL
```

## Troubleshooting

### 1. Task Definition Error
Jika mendapat error `Invalid type for parameter taskRoleArn`:
```bash
# Verifikasi role ARN
aws iam get-role --role-name staging-web-app-task-role
aws iam get-role --role-name staging-web-app-execution-role
```

### 2. Image Push Error
Jika tidak bisa push ke ECR:
```bash
# Re-authenticate dengan ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin 617692575193.dkr.ecr.$AWS_REGION.amazonaws.com
```

### 3. GitHub Actions Error
Jika GitHub Actions gagal:
1. Verifikasi AWS_ROLE_ARN di repository secrets
2. Cek IAM role permissions
3. Verifikasi OIDC provider setup

## Catatan Penting

1. Semua resources dibuat di region `ap-southeast-1`
2. Account ID yang digunakan: `617692575193`
3. Image tag yang digunakan: `staging`
4. VPC dan subnet menggunakan default VPC
5. GitHub Actions workflow hanya trigger pada push ke branch `main`

## Clean Up

Untuk menghapus semua resources:

```bash
# Delete CloudFormation stack
aws cloudformation delete-stack --stack-name web-app

# Delete ECR images
aws ecr batch-delete-image \
  --repository-name web-app \
  --image-ids imageTag=staging

# Delete IAM roles (optional)
aws iam delete-role --role-name staging-web-app-task-role
aws iam delete-role --role-name staging-web-app-execution-role
aws iam delete-role --role-name github-actions-role
```

### 7. Troubleshooting

Jika stack rollback:

1. **IAM Role Conflicts**:
```bash
# List semua role yang ada
aws iam list-roles --query 'Roles[?contains(RoleName, `web-app`) == `true`].RoleName'

# List policies yang terpasang pada role
aws iam list-attached-role-policies --role-name ROLE_NAME

# Detach policy dari role
aws iam detach-role-policy \
  --role-name ROLE_NAME \
  --policy-arn POLICY_ARN

# Hapus role
aws iam delete-role --role-name ROLE_NAME

# Contoh lengkap untuk staging-web-app-execution-role:
aws iam list-attached-role-policies --role-name staging-web-app-execution-role && \
aws iam detach-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy && \
aws iam delete-role --role-name staging-web-app-execution-role
```

2. **VPC Limits**:
```bash
# Cek VPC limits
aws ec2 describe-account-attributes \
  --attribute-names vpc-max-security-groups-per-vpc \
  --region ap-southeast-1
```

3. **ECS Issues**:
```bash
# Cek ECS logs
aws logs describe-log-streams \
  --log-group-name /ecs/staging-web-app \
  --region ap-southeast-1

# Get specific log events
aws logs get-log-events \
  --log-group-name /ecs/staging-web-app \
  --log-stream-name TASK_ID
```

### 7. Setup GitHub Repository Secrets

1. Go to repository Settings > Secrets and variables > Actions
2. Add new repository secret:
   - Name: `AWS_ROLE_ARN`
   - Value: Output dari `$ROLE_ARN` di langkah sebelumnya

### 8. Trigger Deployment

1. Update aplikasi (contoh: index.html):
```html
<h1 class="fw-bolder">Hello World To The Test</h1>
```

2. Commit dan push perubahan:
```bash
git add .
git commit -m "Update content"
git push origin main
```

3. Monitor deployment:
   - Buka GitHub repository
   - Klik tab "Actions"
   - Lihat workflow run terbaru

### 9. Verifikasi Deployment

```bash
# Get service URL
SERVICE_URL=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text)

# Test endpoint
curl -v $SERVICE_URL
```

## Deployment Process

### 1. Infrastructure Deployment (CloudFormation)

#### Stack Creation
```bash
# Deploy infrastructure
aws cloudformation create-stack \
  --stack-name web-app \
  --template-body file://template.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=Environment,ParameterValue=staging
```

#### Monitor Deployment Progress
```bash
# Check stack status
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].StackStatus'

# View recent events
aws cloudformation describe-stack-events \
  --stack-name web-app \
  --query 'StackEvents[0:5]'
```

#### Verify Resources
After successful deployment, verify:
1. VPC and networking components
2. Security groups
3. Load balancer and target group
4. ECS cluster and service
5. CloudWatch log group

### 2. Application Deployment (GitHub Actions)

#### Prerequisites
1. GitHub repository configured with:
   - AWS role ARN in secrets
   - Workflow file in place
   - Dockerfile and application code

#### Monitor Deployment
1. GitHub Actions:
   - Check workflow runs in Actions tab
   - Monitor build and push steps
   - Verify ECR image upload

2. ECS Service:
```bash
# Check service status
aws ecs describe-services \
  --cluster staging-web-app-cluster \
  --services staging-web-app

# View running tasks
aws ecs list-tasks \
  --cluster staging-web-app-cluster \
  --service-name staging-web-app

# Check container logs
aws logs get-log-events \
  --log-group-name /ecs/staging-web-app \
  --log-stream-name TASK_ID
```

3. Load Balancer:
```bash
# Get service URL
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text
```

## Verification Checklist

### Infrastructure
- [ ] VPC and subnets created
- [ ] Security groups configured
- [ ] Load balancer accessible
- [ ] Target group healthy
- [ ] ECS cluster running
- [ ] Service stable

### Application
- [ ] Container image built and pushed
- [ ] Tasks running
- [ ] Health checks passing
- [ ] Logs showing normal operation
- [ ] Application accessible via ALB

## Troubleshooting

### Common Issues

1. **Task Definition**
   - Check execution role permissions
   - Verify container configuration
   - Validate memory and CPU settings

2. **Service Deployment**
   - Monitor service events
   - Check task placement
   - Verify network configuration

3. **Application Health**
   - Review container logs
   - Check target group health
   - Verify security group rules

### Resolution Steps

1. **Task Won't Start**
```bash
# Check service events
aws ecs describe-services \
  --cluster staging-web-app-cluster \
  --services staging-web-app \
  --query 'services[0].events'

# View stopped tasks
aws ecs describe-tasks \
  --cluster staging-web-app-cluster \
  --tasks TASK_ID
```

2. **Health Check Failures**
```bash
# View target health
aws elbv2 describe-target-health \
  --target-group-arn TARGET_GROUP_ARN

# Check container logs
aws logs get-log-events \
  --log-group-name /ecs/staging-web-app \
  --log-stream-name TASK_ID
```

## Rollback Procedure

### Infrastructure Rollback
```bash
# Revert to previous stack version
aws cloudformation update-stack \
  --stack-name web-app \
  --template-body file://previous-template.yml \
  --capabilities CAPABILITY_NAMED_IAM
```

### Application Rollback
1. Update task definition to previous version
2. Update service to use previous task definition
```bash
aws ecs update-service \
  --cluster staging-web-app-cluster \
  --service staging-web-app \
  --task-definition PREVIOUS_TASK_DEF \
  --force-new-deployment
```
