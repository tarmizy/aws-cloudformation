# Panduan Simulasi Deployment Web App di AWS

## Persiapan Awal

### 1. Clone Repository
```bash
# Clone repository
git clone https://github.com/[username]/aws-cloudformation.git
cd aws-cloudformation
```

### 2. Setup AWS CLI
```bash
# Konfigurasi AWS CLI
aws configure
# Masukkan:
# - AWS Access Key ID
# - AWS Secret Access Key
# - Default region: ap-southeast-1
# - Default output format: json
```

## Tahap 1: Setup IAM Roles

### 1.1 Buat Execution Role untuk ECS
```bash
# Buat role
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

# Attach ECS task execution policy
aws iam attach-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Tambah policy untuk ECR dan CloudWatch
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

# Verifikasi role
aws iam get-role \
  --role-name staging-web-app-execution-role
```

### 1.2 Buat Role untuk GitHub Actions
```bash
# Buat role
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

# Tambah permissions
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

# Verifikasi role
aws iam get-role \
  --role-name github-actions-role
```

## Tahap 2: Setup GitHub Repository

### 2.1 Setup GitHub Actions Secret
1. Buka repository di GitHub
2. Pergi ke Settings > Secrets and variables > Actions
3. Klik "New repository secret"
4. Tambahkan secret:
   - Name: `AWS_ROLE_ARN`
   - Value: `arn:aws:iam::617692575193:role/github-actions-role`

### 2.2 Verifikasi Workflow File
1. Pastikan file `.github/workflows/deploy.yml` sudah ada
2. Verifikasi environment variables:
```yaml
env:
  AWS_REGION: ap-southeast-1
  ECR_REPOSITORY: web-app
  ECS_CLUSTER: web-app-staging-cluster
  ECS_SERVICE: web-app-staging
  STACK_NAME: web-app
  ENVIRONMENT: staging
```

## Tahap 3: Deploy Infrastructure

### 3.1 Deploy CloudFormation Stack
```bash
# Deploy stack
aws cloudformation create-stack \
  --stack-name web-app \
  --template-body file://template.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=Environment,ParameterValue=staging && \
echo "\nWaiting for stack to complete..." && \
aws cloudformation wait stack-create-complete --stack-name web-app && \
echo "\nGetting stack outputs..." && \
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs'


# Monitor deployment
aws cloudformation wait stack-create-complete --stack-name web-app

# Verifikasi outputs
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs'
```

### 3.2 Verifikasi Resources
```bash
# Cek ECS cluster
echo "Checking ECS cluster..." && \
aws ecs describe-clusters \
  --clusters web-app-staging-cluster \
  --query 'clusters[0].{status:status,runningTasksCount:runningTasksCount,activeServicesCount:activeServicesCount}' && \
echo "\nChecking ECS service..." && \
aws ecs describe-services \
  --cluster web-app-staging-cluster \
  --services web-app-staging \
  --query 'services[0].{status:status,desiredCount:desiredCount,runningCount:runningCount,events:events[0:3]}'

# Cek ECS service
aws ecs describe-services \
  --cluster web-app-staging-cluster \
  --services web-app-staging

# Cek task definition
aws ecs describe-task-definition \
  --task-definition web-app-staging
```

## Tahap 4: Test Deployment

### 4.1 Update Aplikasi
```bash
# Edit index.html untuk mengubah brand name
# Dari: <a class="navbar-brand" href="index.html">Winner to Bejo</a>
# Ke: <a class="navbar-brand" href="index.html">Winner Bro</a>

# Commit dan push perubahan
git add index.html
git commit -m "Update brand name to Winner Bro"
git push origin main
```

### 4.2 Monitor Deployment
```bash
# Cek GitHub Actions
# Buka repository > Actions tab > Workflow runs

# Monitor ECS service
echo "Monitoring deployment..." && \
for i in {1..5}; do
  echo "\nChecking service status (attempt $i)..." && \
  aws ecs describe-services \
    --cluster web-app-staging-cluster \
    --services web-app-staging \
    --query 'services[0].{status:status,desiredCount:desiredCount,runningCount:runningCount,events:events[0:3]}' && \
  sleep 10
done

# Cek task status
aws ecs describe-tasks \
  --cluster web-app-staging-cluster \
  --tasks $(aws ecs list-tasks \
    --cluster web-app-staging-cluster \
    --service-name web-app-staging \
    --query 'taskArns[0]' \
    --output text)
```

### 4.3 Verifikasi Perubahan
```bash
# Dapatkan URL aplikasi
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text

# Buka URL di browser dan verifikasi perubahan brand name
```

## Troubleshooting

### Common Issues

1. **ClusterNotFoundException**
```bash
# Verifikasi cluster
aws ecs list-clusters
aws ecs describe-clusters --clusters web-app-staging-cluster
```

2. **Task Definition Error**
```bash
# Cek execution role
aws iam get-role --role-name staging-web-app-execution-role

# Cek task definition
aws ecs describe-task-definition --task-definition web-app-staging
```

3. **Service Update Failed**
```bash
# Cek service events
aws ecs describe-services \
  --cluster web-app-staging-cluster \
  --services web-app-staging \
  --query 'services[0].events'

# Cek logs
aws logs get-log-events \
  --log-group-name /ecs/web-app-staging \
  --log-stream-name $(aws ecs list-tasks \
    --cluster web-app-staging-cluster \
    --service-name web-app-staging \
    --query 'taskArns[0]' \
    --output text | cut -d'/' -f3)
```

## Clean Up

### 1. Delete Infrastructure
```bash
# Delete CloudFormation stack
aws cloudformation delete-stack --stack-name web-app
aws cloudformation wait stack-delete-complete --stack-name web-app
```

### 2. Delete IAM Roles
```bash
# Delete execution role
aws iam detach-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

aws iam delete-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-name ECRandCloudWatchPolicy

aws iam delete-role \
  --role-name staging-web-app-execution-role

# Delete GitHub Actions role
aws iam delete-role-policy \
  --role-name github-actions-role \
  --policy-name GitHubActionsPolicy

aws iam delete-role \
  --role-name github-actions-role
```

### 3. Clean Up ECR (Optional)
```bash
# Delete images
aws ecr batch-delete-image \
  --repository-name web-app \
  --image-ids "$(aws ecr list-images \
    --repository-name web-app \
    --query 'imageIds[*]' \
    --output json)"

# Delete repository
aws ecr delete-repository \
  --repository-name web-app \
  --force
