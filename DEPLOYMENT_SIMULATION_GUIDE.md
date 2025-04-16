# Panduan Simulasi Deployment dari Awal

## Prasyarat
- AWS CLI terinstal dan terkonfigurasi
- Git terinstal
- GitHub repository yang sudah dibuat
- Docker terinstal (untuk build image)

## Langkah 1: Setup IAM Roles dan Policies

### 1.1 Buat ECS Execution Role

```bash
# 1. Buat execution role
aws iam create-role \
  --role-name staging-web-app-execution-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": ["ecs-tasks.amazonaws.com"]
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# 2. Tambahkan policy untuk execution role
aws iam put-role-policy \
  --role-name staging-web-app-execution-role \
  --policy-name ECSTaskExecutionPolicy \
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

### 1.2 Setup GitHub Actions Role

```bash
# 1. Buat GitHub OIDC provider (jika belum ada)
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" \
  --client-id-list "sts.amazonaws.com"

# 2. Buat GitHub Actions role
aws iam create-role \
  --role-name github-actions-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
                },
                "StringLike": {
                    "token.actions.githubusercontent.com:sub": "repo:GITHUB_USERNAME/REPO_NAME:*"
                }
            }
        }
    ]
}'

# 3. Tambahkan policy untuk GitHub Actions role
aws iam put-role-policy \
  --role-name github-actions-role \
  --policy-name github-actions-policy \
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
                "iam:GetRole"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": [
                "arn:aws:iam::ACCOUNT_ID:role/staging-web-app-execution-role"
            ]
        }
    ]
}'
```

## Langkah 2: Setup Repository

### 2.1 Clone dan Setup Repository

```bash
# 1. Clone repository
git clone https://github.com/YOUR_USERNAME/aws-cloudformation.git
cd aws-cloudformation

# 2. Buat direktori untuk GitHub Actions
mkdir -p .github/workflows
```

### 2.2 Buat GitHub Actions Workflow

Buat file `.github/workflows/deploy.yml`:

```yaml
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

    - name: Set up QEMU
      uses: docker/setup-qemu-action@v2

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v2

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
        docker buildx build \
          --platform linux/arm64,linux/amd64 \
          -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
          -t $ECR_REGISTRY/$ECR_REPOSITORY:$ENVIRONMENT \
          --push \
          .
        echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

    - name: Update ECS Service
      run: |
        echo "Creating new task definition using image: ${{ steps.build-image.outputs.image }}"
        
        # Try to get current task definition, if it exists
        if aws ecs describe-task-definition --task-definition staging-web-app >/dev/null 2>&1; then
          TASK_DEF=$(aws ecs describe-task-definition \
            --task-definition staging-web-app \
            --query 'taskDefinition | {
              family: family,
              taskRoleArn: taskRoleArn,
              executionRoleArn: executionRoleArn,
              networkMode: networkMode,
              containerDefinitions: containerDefinitions,
              requiresCompatibilities: requiresCompatibilities,
              cpu: cpu,
              memory: memory,
              runtimePlatform: runtimePlatform
            }' \
            --output json)

          EXECUTION_ROLE_ARN=$(echo $TASK_DEF | jq -r '.executionRoleArn')
        else
          EXECUTION_ROLE_ARN=$(aws iam get-role --role-name staging-web-app-execution-role --query 'Role.Arn' --output text)
        fi

        TASK_ROLE_ARN=$EXECUTION_ROLE_ARN
        echo "Task Role ARN: $TASK_ROLE_ARN"
        echo "Execution Role ARN: $EXECUTION_ROLE_ARN"

        if [ -z "$TASK_DEF" ]; then
          TASK_DEF='{
            "family": "staging-web-app",
            "networkMode": "awsvpc",
            "requiresCompatibilities": ["FARGATE"],
            "cpu": "512",
            "memory": "1024",
            "runtimePlatform": {
              "cpuArchitecture": "ARM64",
              "operatingSystemFamily": "LINUX"
            },
            "taskRoleArn": "'$TASK_ROLE_ARN'",
            "executionRoleArn": "'$EXECUTION_ROLE_ARN'",
            "containerDefinitions": [
              {
                "name": "web-app",
                "image": "${{ steps.build-image.outputs.image }}",
                "portMappings": [
                  {
                    "containerPort": 80,
                    "hostPort": 80,
                    "protocol": "tcp"
                  }
                ],
                "essential": true,
                "logConfiguration": {
                  "logDriver": "awslogs",
                  "options": {
                    "awslogs-group": "/ecs/staging-web-app",
                    "awslogs-region": "ap-southeast-1",
                    "awslogs-stream-prefix": "ecs"
                  }
                }
              }
            ]
          }'
        fi

        if [[ -n $(echo "$TASK_DEF" | jq -r '.containerDefinitions') ]]; then
          NEW_TASK_DEF=$(echo $TASK_DEF | \
            jq --arg IMAGE "${{ steps.build-image.outputs.image }}" \
               --arg TASK_ROLE "$TASK_ROLE_ARN" \
               --arg EXEC_ROLE "$EXECUTION_ROLE_ARN" \
            '.containerDefinitions[0].image = $IMAGE | .taskRoleArn = $TASK_ROLE | .executionRoleArn = $EXEC_ROLE')
        else
          NEW_TASK_DEF="$TASK_DEF"
        fi

        echo "New task definition:"
        echo "$NEW_TASK_DEF" | jq '.'

        echo "Registering new task definition..."
        NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
          --cli-input-json "$NEW_TASK_DEF" \
          --query 'taskDefinition.taskDefinitionArn' \
          --output text)

        echo "New task definition ARN: $NEW_TASK_DEF_ARN"
        NEW_TASK_DEF_FAMILY=$(echo $NEW_TASK_DEF_ARN | cut -d/ -f2)

        echo "Updating service..."
        aws ecs update-service \
          --cluster $ECS_CLUSTER \
          --service $ECS_SERVICE \
          --task-definition $NEW_TASK_DEF_FAMILY \
          --force-new-deployment

    - name: Monitor deployment
      run: |
        echo "Monitoring deployment progress..."
        
        # Maximum wait time: 5 minutes
        MAX_ATTEMPTS=30
        WAIT_SECONDS=10
        
        for ((i=1; i<=$MAX_ATTEMPTS; i++)); do
          STATUS=$(aws ecs describe-services \
            --cluster $ECS_CLUSTER \
            --services $ECS_SERVICE \
            --query 'services[0].deployments[0].rolloutState' \
            --output text)
            
          echo "Deployment status: $STATUS"
          
          if [ "$STATUS" = "COMPLETED" ]; then
            echo "Deployment successful!"
            exit 0
          elif [ "$STATUS" = "FAILED" ]; then
            echo "Deployment failed!"
            aws ecs describe-services \
              --cluster $ECS_CLUSTER \
              --services $ECS_SERVICE \
              --query 'services[0].deployments[0].rolloutStateReason' \
              --output text
            exit 1
          fi
          
          echo "Waiting for deployment... ($i/$MAX_ATTEMPTS)"
          sleep $WAIT_SECONDS
        done
        
        echo "Deployment timed out!"
        exit 1
```

## Langkah 3: Setup GitHub Repository Secrets

1. Buka repository di GitHub
2. Pergi ke Settings > Secrets and variables > Actions
3. Tambahkan secret baru:
   - Name: `AWS_ROLE_ARN`
   - Value: ARN dari GitHub Actions role (format: `arn:aws:iam::ACCOUNT_ID:role/github-actions-role`)

## Langkah 4: Deploy Aplikasi

### 4.1 Persiapan Aplikasi

1. Pastikan `Dockerfile` sudah ada dan valid
2. Pastikan aplikasi berjalan di port 80 (sesuai dengan task definition)

### 4.2 Trigger Deployment

```bash
# 1. Commit dan push perubahan
git add .
git commit -m "Initial deployment"
git push origin main

# 2. Monitor deployment
- Buka GitHub repository
- Klik tab Actions
- Lihat workflow yang sedang berjalan
```

## Langkah 5: Verifikasi Deployment

### 5.1 Cek Status ECS Service

```bash
# 1. Cek service status
aws ecs describe-services \
  --cluster staging-web-app-cluster \
  --services staging-web-app

# 2. Cek task yang berjalan
aws ecs list-tasks \
  --cluster staging-web-app-cluster \
  --service-name staging-web-app

# 3. Cek logs
aws logs get-log-events \
  --log-group-name /ecs/staging-web-app \
  --log-stream-name TASK_ID_FROM_STEP_2
```

### 5.2 Troubleshooting Umum

1. **IAM Role Issues**
   ```bash
   # Cek execution role
   aws iam get-role --role-name staging-web-app-execution-role
   
   # Cek GitHub Actions role
   aws iam get-role --role-name github-actions-role
   ```

2. **Task Definition Issues**
   ```bash
   # List task definitions
   aws ecs list-task-definitions
   
   # Describe specific task definition
   aws ecs describe-task-definition --task-definition FAMILY_NAME
   ```

3. **Service Issues**
   ```bash
   # Cek service events
   aws ecs describe-services \
     --cluster staging-web-app-cluster \
     --services staging-web-app \
     --query 'services[0].events'
   ```

## Langkah 6: Pemeliharaan

### 6.1 Update Aplikasi

1. Buat perubahan pada kode
2. Commit dan push ke main branch
3. GitHub Actions akan otomatis men-deploy perubahan

### 6.2 Rollback (jika diperlukan)

```bash
# 1. Dapatkan task definition sebelumnya
aws ecs describe-task-definition \
  --task-definition staging-web-app:PREVIOUS_REVISION

# 2. Update service ke versi sebelumnya
aws ecs update-service \
  --cluster staging-web-app-cluster \
  --service staging-web-app \
  --task-definition staging-web-app:PREVIOUS_REVISION
```
