## Architecture Diagram

```mermaid
graph TB
    %% Internet Gateway and VPC
    Internet((Internet)) --> ALB
    subgraph VPC["VPC (ap-southeast-1)"]
        %% Load Balancer
        subgraph PublicSubnets["Public Subnets"]
            ALB["Application Load Balancer<br/>staging-web-app-alb"]
        end

        %% ECS Cluster and Tasks
        subgraph PrivateSubnets["Private Subnets"]
            subgraph ECSCluster["ECS Cluster (staging-web-app-cluster)"]
                Service["ECS Service<br/>staging-web-app"]
                Task1["ECS Task 1<br/>Fargate (ARM64)<br/>CPU: 512, Memory: 1024"]
                Task2["ECS Task 2<br/>Fargate (ARM64)<br/>CPU: 512, Memory: 1024"]
                Service --> Task1
                Service --> Task2
            end
        end

        %% Security Groups
        ALB --> |"Target Group<br/>Port 80"| Service
    end

    %% External Services
    subgraph AWS["AWS Services"]
        ECR["Amazon ECR<br/>web-app repository"]
        CloudWatch["CloudWatch Logs<br/>/ecs/staging-web-app"]
        IAM["IAM Roles<br/>Task Execution Role"]
    end

    %% Connections
    Task1 --> ECR
    Task2 --> ECR
    Task1 --> CloudWatch
    Task2 --> CloudWatch
    Task1 --> IAM
    Task2 --> IAM

    %% Styling
    classDef aws fill:#FF9900,stroke:#232F3E,stroke-width:2px,color:white;
    classDef vpc fill:#F58536,stroke:#232F3E,stroke-width:2px,color:white;
    classDef subnet fill:#4B612C,stroke:#232F3E,stroke-width:2px,color:white;
    classDef service fill:#3B48CC,stroke:#232F3E,stroke-width:2px,color:white;

    class VPC vpc;
    class PublicSubnets,PrivateSubnets subnet;
    class ECR,CloudWatch,IAM aws;
    class ALB,Service,Task1,Task2 service;
```

### Architecture Components

1. **VPC and Networking**
   - VPC in ap-southeast-1 region
   - Public subnets for ALB
   - Private subnets for ECS tasks
   - Internet Gateway for public access

2. **Load Balancer**
   - Application Load Balancer (ALB)
   - Internet-facing
   - Listens on port 80
   - Routes traffic to ECS tasks

3. **ECS Cluster**
   - Cluster Name: staging-web-app-cluster
   - Service Name: staging-web-app
   - 2 Fargate tasks
   - ARM64 architecture
   - Task resources: 512 CPU units, 1024MB memory

4. **Container Infrastructure**
   - ECR repository for container images
   - CloudWatch Logs for container logging
   - IAM roles for task execution

5. **Security**
   - Security groups for ALB and ECS tasks
   - IAM roles with least privilege
   - Private subnets for ECS tasks
