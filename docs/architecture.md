# Architecture

## Overview

This project is a secure, event-driven multi-agent AI platform running on Azure Kubernetes Service. It demonstrates enterprise-grade patterns for deploying AI workloads: private networking, zero-trust identity, GitOps deployment, and per-agent cost governance.

## Design principles

**No credentials stored anywhere.** Every agent authenticates to Azure services using workload identity federation. Pods present a Kubernetes ServiceAccount token, Azure AD exchanges it for a short-lived access token, and the service validates it via RBAC. No API keys, no connection strings, no secrets in manifests.

**Private by default.** All Azure services (OpenAI, Key Vault, ACR, Service Bus) are accessible only via private endpoints inside the VNet. NSGs explicitly deny internet egress from the AKS node subnet. NetworkPolicies enforce the same at the pod level.

**Event-driven agents, not HTTP chains.** Agents do not call each other directly. The orchestrator publishes tasks to Service Bus topics; workers pull and process independently. This decoupling means any agent can be scaled, restarted, or replaced without affecting others.

**Infrastructure as code, all the way down.** Every Azure resource is defined in a Terraform module. No portal clicks. `environments/dev/main.tf` is the single source of truth for what exists in dev.

**GitOps deployment.** Flux CD watches `k8s/overlays/dev` in this repo. A commit to that path — including the automated image tag update from CI — triggers reconciliation to the cluster within 2 minutes.

## Component map

```
GitHub Actions
  infra.yml     → Terraform plan/apply for Azure resources
  agents.yml    → Build, scan, push agent images → update k8s overlay → Flux deploys

Azure (private VNet)
  AKS cluster (private API server)
    agents namespace
      orchestrator      ← receives task requests via HTTP
      research-agent    ← pulls from research-tasks Service Bus topic
      analysis-agent    ← pulls from analysis-tasks Service Bus topic
      writer-agent      ← pulls from writer-tasks Service Bus topic
  Azure OpenAI          ← private endpoint, no API key, RBAC only
  Azure Service Bus     ← Premium, private endpoint, topics + subscriptions
  Azure Key Vault       ← private endpoint, RBAC, CSI driver mounts secrets
  Azure Container Registry ← private, Premium, image scanning
```

## Request flow

1. Caller sends `POST /tasks` to the orchestrator with a prompt.
2. Orchestrator calls Azure OpenAI to decompose the prompt into typed sub-tasks.
3. Orchestrator publishes one message per sub-task to the appropriate Service Bus topic, each carrying a shared `correlation_id`.
4. Worker agents receive messages from their topic subscription, process with OpenAI, and publish results to `agent-results` with the same `correlation_id`.
5. Orchestrator's result listener matches incoming results by `correlation_id` and marks the job complete when all expected results arrive.
6. Caller polls `GET /tasks/{job_id}` to retrieve the aggregated results.

## Identity model

Each agent has its own Azure Managed Identity, created by the `keyvault` Terraform module. A federated credential links the identity to a specific Kubernetes ServiceAccount (`system:serviceaccount:agents:sa-<agent-name>`). RBAC assignments are scoped as narrowly as possible:

| Agent | Service Bus | Azure OpenAI | Key Vault |
|---|---|---|---|
| orchestrator | Sender on task topics; Receiver on results | OpenAI User | Secrets User |
| research-agent | Receiver on research-tasks; Sender on results | OpenAI User | Secrets User |
| analysis-agent | Receiver on analysis-tasks; Sender on results | OpenAI User | Secrets User |
| writer-agent | Receiver on writer-tasks; Sender on results | OpenAI User | Secrets User |

## Architecture decision records

### ADR-001: Azure CNI Overlay over Kubenet

Kubenet requires UDRs for pod routing, which adds operational complexity and breaks with `userDefinedRouting` outbound type. CNI Overlay gives pods routable IPs from a dedicated subnet without consuming node subnet addresses, and integrates cleanly with Azure Network Policy for pod-level firewalling.

### ADR-002: Service Bus Premium over Standard

Premium is required for private endpoints. Standard tier has no VNet integration. The cost difference is justified by the security posture — a Standard namespace with a public endpoint would require IP allowlisting and connection strings, both of which are weaker controls than managed identity + private endpoint.

### ADR-003: Separate system and agent node pools

The system pool is tainted `CriticalAddonsOnly=true:NoSchedule` so kube-system pods (CoreDNS, metrics-server, Flux) stay isolated from agent workloads. This prevents a noisy AI workload from starving cluster infrastructure. The agent pool can be drained, resized, or swapped to a different VM SKU without affecting cluster operation.

### ADR-004: Flux CD over Argo CD

Flux is installed as an AKS extension (`microsoft.flux`), which means Microsoft manages the extension lifecycle, upgrade, and support. Argo CD requires a separate Helm install and operational overhead. For a platform where GitOps is infrastructure, not application logic, the managed option is preferable.

### ADR-005: RBAC model over Key Vault access policies

Access policies grant permissions at the vault level — one policy covers all secrets. RBAC assignments can be scoped to individual secrets if needed, integrate with Azure Policy, and appear in the unified Azure RBAC audit log alongside other role assignments. New vaults should always use RBAC.
