# Azure AI Platform

A secure, event-driven multi-agent AI platform on Azure Kubernetes Service. Built to demonstrate enterprise-grade AI infrastructure patterns: private networking, zero-trust identity, GitOps deployment, and operational observability.

## What this is

Four AI agents running as independent microservices on a private AKS cluster, coordinating work through Azure Service Bus:

- **Orchestrator** — receives task requests, decomposes them via GPT-4o, fans work out to specialist agents
- **Research agent** — performs structured research and summarisation
- **Analysis agent** — reasons over findings, identifies patterns, produces recommendations
- **Writer agent** — formats and delivers polished output

No agent calls another directly. All coordination is event-driven via Service Bus topics.

## Key technical decisions

| Decision | Choice | Why |
|---|---|---|
| Auth model | Workload identity federation | No stored credentials anywhere in the platform |
| Network | Private endpoints + NSG deny-all | Zero public surface area for Azure services |
| Secrets | Key Vault CSI driver | Secrets mounted at pod start, rotated without restarts |
| Deployment | Flux CD (GitOps) | Cluster state is always reconciled from Git |
| IaC | Terraform modules | Every resource reproducible, environment parity guaranteed |
| Messaging | Service Bus Premium | Private endpoint, dead-letter queues, duplicate detection |

## Repository structure

```
.
├── .github/
│   └── workflows/
│       ├── infra.yml          # Terraform pipeline (validate → scan → plan → apply)
│       └── agents.yml         # Agent image pipeline (build → scan → push → deploy)
├── agents/
│   ├── orchestrator/          # FastAPI + Azure OpenAI + Service Bus
│   ├── research-agent/
│   ├── analysis-agent/
│   └── writer-agent/
├── docs/
│   └── architecture.md        # Design decisions and ADRs
├── infra/
│   ├── modules/
│   │   ├── networking/        # VNet, subnets, NSGs, private DNS zones
│   │   ├── aks/               # Private cluster, node pools, Flux, workload identity
│   │   ├── keyvault/          # Vault, managed identities, federated credentials
│   │   ├── openai/            # Azure OpenAI, GPT-4o + embeddings, private endpoint
│   │   ├── servicebus/        # Premium namespace, topics, subscriptions, RBAC
│   │   └── monitoring/        # Alerts, cost budget, saved queries
│   └── environments/
│       └── dev/               # Dev entrypoint — calls all modules
└── k8s/
    ├── base/                  # Namespace, ServiceAccounts, Deployments, NetworkPolicies
    ├── overlays/dev/          # Kustomize dev overlay (image tags updated by CI)
    └── flux/                  # GitRepository + Kustomization for Flux CD
```

## Prerequisites

- Azure subscription with Owner or Contributor + User Access Administrator
- Azure CLI: `az login`
- Terraform >= 1.7
- kubectl
- Azure OpenAI quota in your target region (`eastus2` recommended)

## Getting started

### 1. Bootstrap Terraform state storage

```bash
az group create --name rg-tfstate --location eastus2
az storage account create \
  --name sttfstate<your-suffix> \
  --resource-group rg-tfstate \
  --sku Standard_LRS \
  --allow-blob-public-access false

az storage container create \
  --name tfstate \
  --account-name sttfstate<your-suffix>
```

Uncomment and fill in the `backend "azurerm"` block in `infra/environments/dev/main.tf`.

### 2. Fill in your values

```bash
# Your AAD object ID (for Key Vault Secrets Officer)
az ad signed-in-user show --query id -o tsv

# Edit infra/environments/dev/terraform.tfvars
admin_principal_id = "<your-object-id>"
alert_email        = "you@example.com"
```

### 3. Deploy infrastructure

```bash
cd infra/environments/dev
terraform init
terraform plan
terraform apply
```

### 4. Populate ServiceAccount annotations

```bash
# Get the managed identity client IDs Terraform created
terraform output -json agent_identity_client_ids
```

Update the `azure.workload.identity/client-id` annotations in `k8s/base/namespace.yaml` and `k8s/base/secret-provider-classes.yaml` with the values from the output.

### 5. Configure GitHub Actions secrets

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | Service principal or managed identity client ID for CI |
| `AZURE_TENANT_ID` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `az account show --query id -o tsv` |
| `TF_STATE_RG` | `rg-tfstate` |
| `TF_STATE_SA` | `sttfstate<your-suffix>` |
| `ADMIN_PRINCIPAL_ID` | Your AAD object ID |
| `ALERT_EMAIL` | Your email address |

### 6. Bootstrap Flux

```bash
az aks get-credentials --resource-group rg-aiplatform-dev --name aks-aiplatform-dev

# Create GitHub token secret for Flux
kubectl create secret generic flux-github-token \
  --namespace flux-system \
  --from-literal=username=git \
  --from-literal=password=<your-github-pat>

# Apply Flux manifests
kubectl apply -f k8s/flux/gitrepository.yaml
kubectl apply -f k8s/flux/kustomization-agents.yaml
```

### 7. Submit a test task

```bash
# Port-forward to the orchestrator
kubectl port-forward svc/orchestrator 8080:80 -n agents

# Submit a task
curl -X POST http://localhost:8080/tasks \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Analyse the impact of rising interest rates on commercial real estate"}'

# Poll for results (use the job_id from the response)
curl http://localhost:8080/tasks/<job-id>
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full design, component map, request flow, identity model, and architecture decision records.
