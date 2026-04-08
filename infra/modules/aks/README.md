# modules/aks

Private AKS cluster with workload identity, Flux CD, and Defender for Containers.

## What this module provisions

| Resource | Purpose |
|---|---|
| User-assigned managed identity | Cluster identity for NIC/NSG management and ACR pull |
| AKS cluster (private) | No public API server endpoint |
| System node pool | Runs kube-system only; tainted CriticalAddonsOnly |
| Agent node pool | Runs AI agent workloads; autoscales min→max; tainted workload=ai-agents |
| Log Analytics workspace | Container Insights + Defender logs |
| Flux CD extension | GitOps controller; reconciles from GitHub |

## Design decisions

**Private cluster.** The Kubernetes API server has no public endpoint. Access requires
either being inside the VNet or using an Azure Bastion / jump host. This is the
enterprise standard for any cluster running sensitive workloads.

**Two node pools.** The system pool is tainted `CriticalAddonsOnly=true:NoSchedule`
so kube-system pods (CoreDNS, metrics-server, etc.) stay isolated from agent pods.
The agents pool is tainted `workload=ai-agents:NoSchedule` so only explicitly
tolerated Deployments land there. Each pool can be resized or replaced independently.

**Workload identity over pod-managed identity (AAD Pod Identity).** OIDC + workload
identity is the current Microsoft-recommended approach. Pods acquire short-lived
federated tokens rather than using node-level MSI. No stored credentials anywhere.

**`local_account_disabled = true`.** Forces all cluster access through Azure AD.
There is no `kubeconfig` with a static password — authentication is always a
short-lived AAD token.

**`outbound_type = userDefinedRouting`.** Nodes have no public IP and no NAT gateway.
All egress is controlled at the NSG level (see modules/networking). This ensures
the DenyInternetOutbound NSG rule is the actual enforcement point, not just advisory.

## Usage

```hcl
module "aks" {
  source = "../../modules/aks"

  name                = "aiplatform"
  environment         = "dev"
  location            = "eastus2"
  resource_group_name = azurerm_resource_group.main.name

  aks_nodes_subnet_id = module.networking.aks_nodes_subnet_id
  aks_pods_subnet_id  = module.networking.aks_pods_subnet_id
  acr_id              = azurerm_container_registry.main.id

  kubernetes_version  = "1.29"
  system_node_count   = 2
  agent_min_count     = 1
  agent_max_count     = 3

  tags = local.common_tags
}
```

## Get a kubeconfig after apply

```bash
az aks get-credentials \
  --resource-group rg-aiplatform-dev \
  --name aks-aiplatform-dev \
  --overwrite-existing
```

Because `local_account_disabled = true`, this uses your AAD identity.
You must be in the admin group or have an Azure RBAC role on the cluster.

## Node pool taint reference

| Pool | Taint | Effect |
|---|---|---|
| system | `CriticalAddonsOnly=true` | NoSchedule |
| agents | `workload=ai-agents` | NoSchedule |

Agent Deployments must include this toleration:

```yaml
tolerations:
  - key: "workload"
    operator: "Equal"
    value: "ai-agents"
    effect: "NoSchedule"
```
