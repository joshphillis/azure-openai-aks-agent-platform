# modules/keyvault

Private Key Vault with workload identity federation for all agent pods.

## What this module provisions

| Resource | Purpose |
|---|---|
| Key Vault | Private, RBAC-authorized, purge-protected secret store |
| Private endpoint | Vault accessible only from inside the VNet |
| DNS registration | A record in `privatelink.vaultcore.azure.net` |
| Managed identity × N | One per agent — no shared identity, least privilege |
| Federated credential × N | Links each identity to a Kubernetes ServiceAccount |
| Role: Secrets User × N | Agents can read secrets, never write |
| Role: Secrets Officer | CI/CD pipeline identity can write secrets |
| Diagnostic setting | AuditEvent logs → Log Analytics |

## Design decisions

**RBAC model, not access policies.** The legacy access policy model grants
permissions at the vault level — one policy covers all secrets. RBAC lets you
assign roles at the individual secret scope if needed, and integrates with
Azure Policy and Defender for Cloud. Always use RBAC for new vaults.

**One managed identity per agent.** If all agents shared one identity and it
were compromised, every secret in the vault would be exposed. Separate identities
mean the blast radius of any single compromise is limited to that agent's secrets.

**Federated credentials, not client secrets.** The workload identity federation
flow: the pod presents its Kubernetes ServiceAccount token → Azure AD exchanges it
for a short-lived access token → pod calls Key Vault. No passwords, no certificates,
no rotation required. The link is: federated credential subject must match
`system:serviceaccount:<namespace>:<service-account-name>` exactly.

**Purge protection enabled.** Once enabled this cannot be disabled. Soft-deleted
vaults and secrets cannot be permanently purged until the retention period expires.
This protects against accidental or malicious deletion.

## Usage

```hcl
module "keyvault" {
  source = "../../modules/keyvault"

  name                        = "aiplatform"
  environment                 = "dev"
  location                    = "eastus2"
  resource_group_name         = azurerm_resource_group.main.name
  private_endpoints_subnet_id = module.networking.private_endpoints_subnet_id
  dns_zone_id_keyvault        = module.networking.dns_zone_id_keyvault
  aks_oidc_issuer_url         = module.aks.oidc_issuer_url
  log_analytics_workspace_id  = module.aks.log_analytics_workspace_id
  admin_principal_id          = "<your-aad-object-id>"

  agent_names = ["orchestrator", "research-agent", "analysis-agent", "writer-agent"]
  tags        = local.common_tags
}
```

## Kubernetes ServiceAccount annotation

After apply, annotate each agent's ServiceAccount with its client ID:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sa-orchestrator
  namespace: agents
  annotations:
    azure.workload.identity/client-id: "<orchestrator-client-id>"
```

The client IDs are available from the `agent_identity_client_ids` output:

```bash
terraform output -json agent_identity_client_ids
```

## Populating secrets (after apply)

```bash
# OpenAI endpoint and deployment name — agents read these at runtime
az keyvault secret set \
  --vault-name kv-aiplatform-dev \
  --name openai-endpoint \
  --value "https://<your-aoai-resource>.openai.azure.com/"

az keyvault secret set \
  --vault-name kv-aiplatform-dev \
  --name openai-deployment \
  --value "gpt-4o"

az keyvault secret set \
  --vault-name kv-aiplatform-dev \
  --name servicebus-namespace \
  --value "<your-servicebus-namespace>.servicebus.windows.net"
```
