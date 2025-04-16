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

### 5. Verifikasi Stack dan ECS Service

```bash
# 1. Cek status stack
aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].StackStatus' \
  --region ap-southeast-1

# Expected output: "CREATE_COMPLETE"

# 2. List ECS clusters
aws ecs list-clusters --region ap-southeast-1

# Expected output:
# {
#     "clusterArns": [
#         "arn:aws:ecs:ap-southeast-1:617692575193:cluster/staging-web-app-cluster"
#     ]
# }

# 3. List services in cluster
aws ecs list-services \
  --cluster staging-web-app-cluster \
  --region ap-southeast-1

# Expected output:
# {
#     "serviceArns": [
#         "arn:aws:ecs:ap-southeast-1:617692575193:service/staging-web-app-cluster/staging-web-app"
#     ]
# }

# 4. Cek service status
aws ecs describe-services \
  --cluster staging-web-app-cluster \
  --services staging-web-app \
  --region ap-southeast-1 \
  --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount,events:events[0:3]}'

# Expected output:
# {
#     "status": "ACTIVE",
#     "runningCount": 2,
#     "desiredCount": 2,
#     "events": [
#         {
#             "message": "(service staging-web-app) has reached a steady state."
#         },
#         {
#             "message": "(service staging-web-app) deployment completed."
#         }
#     ]
# }

# 5. Get dan test service URL
SERVICE_URL=$(aws cloudformation describe-stacks \
  --stack-name web-app \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceURL`].OutputValue' \
  --output text \
  --region ap-southeast-1)

echo "Service URL: $SERVICE_URL"
curl -v $SERVICE_URL
```

### 6. Create and Configure GitHub Actions Role

# First, check if role exists
aws iam get-role --role-name github-actions-role || echo "Role does not exist"

# If role doesn't exist, create trust policy and role
echo '{
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
                    "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_USERNAME/aws-cloudformation:*"
                }
            }
        }
    ]
}' > github-actions-trust-policy.json

aws iam create-role \
  --role-name github-actions-role \
  --assume-role-policy-document file://github-actions-trust-policy.json

# Create and attach policy
echo '{
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
                "cloudformation:*"
            ],
            "Resource": "*"
        }
    ]
}' > github-actions-policy.json

# Attach policy to role
aws iam put-role-policy \
  --role-name github-actions-role \
  --policy-name github-actions-policy \
  --policy-document file://github-actions-policy.json

# Verify policy attachment
aws iam get-role-policy \
  --role-name github-actions-role \
  --policy-name github-actions-policy

# Expected output:
# {
#     "RoleName": "github-actions-role",
#     "PolicyName": "github-actions-policy",
#     "PolicyDocument": {
#         "Version": "2012-10-17",
#         "Statement": [
#             {
#                 "Effect": "Allow",
#                 "Action": [
#                     "ecr:GetAuthorizationToken",
#                     ...
#                     "cloudformation:*"
#                 ],
#                 "Resource": "*"
#             }
#         ]
#     }
# }

# 7. Get role ARN untuk GitHub Secret
ROLE_ARN=$(aws iam get-role \
  --role-name github-actions-role \
  --query 'Role.Arn' \
  --output text)

echo "GitHub Actions Role ARN: $ROLE_ARN"
# Expected output:
# GitHub Actions Role ARN: arn:aws:iam::617692575193:role/github-actions-role

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
  --log-stream-name <log-stream-name> \
  --region ap-southeast-1
