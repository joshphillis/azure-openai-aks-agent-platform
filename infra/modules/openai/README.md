# modules/openai

Private Azure OpenAI account with GPT-4o and embeddings, accessible only via
managed identity — no API keys anywhere in the platform.

## What this module provisions

| Resource | Purpose |
|---|---|
| Azure OpenAI account | Private, local auth disabled, system-assigned identity |
| GPT-4o deployment | Primary reasoning model for orchestrator + analysis agent |
| text-embedding-3-large | Embedding model for research agent retrieval |
| Private endpoint | Account accessible only from inside the VNet |
| DNS registration | A record in `privatelink.openai.azure.com` |
| RBAC × N | Cognitive Services OpenAI User for each agent identity |
| KV secret: openai-endpoint | Stored at apply time — agents read via CSI driver |
| KV secret: openai-gpt4o-deployment | Deployment name stored in KV |
| KV secret: openai-embeddings-deployment | Deployment name stored in KV |
| Diagnostic setting | Audit + RequestResponse logs → Log Analytics |

## Design decisions

**`local_auth_enabled = false`.** This disables API key authentication at the
account level — even if someone extracted a key from the Azure portal, it would
be rejected. All callers must present a valid Azure AD token. Combined with the
private endpoint, there is no path to the model that doesn't go through both
network controls and identity controls.

**Endpoint and deployment names go into Key Vault.** Agent pods mount these
as environment variables via the CSI secrets store driver. This means no
endpoint URL is hardcoded in a container image or a Kubernetes manifest — if
the endpoint changes, update the secret, restart the pods, done.

**Embeddings alongside GPT-4o.** The research agent needs to embed queries
for vector retrieval. Provisioning both models in the same account keeps the
private endpoint simple — one PE, one DNS record, both models reachable.

**Capacity (TPM) is a variable.** Dev runs at 30K TPM which is enough for
development and portfolio demo. Prod can be raised independently without
changing module code.

## Usage

```hcl
module "openai" {
  source = "../../modules/openai"

  name                        = "aiplatform"
  environment                 = "dev"
  location                    = "eastus2"
  resource_group_name         = azurerm_resource_group.main.name
  private_endpoints_subnet_id = module.networking.private_endpoints_subnet_id
  dns_zone_id_openai          = module.networking.dns_zone_id_openai
  keyvault_id                 = module.keyvault.keyvault_id
  agent_identity_principal_ids = module.keyvault.agent_identity_principal_ids
  log_analytics_workspace_id  = module.aks.log_analytics_workspace_id

  gpt4o_capacity_tpm      = 30
  embeddings_capacity_tpm = 30
  tags                    = local.common_tags
}
```

## Requesting quota before apply

Azure OpenAI capacity requires a quota request in most regions.
Check your current quota:

```bash
az cognitiveservices usage list \
  --location eastus2 \
  --query "[?contains(name.value, 'OpenAI')]" \
  -o table
```

If you need more capacity, request it at:
https://aka.ms/oai/quotaincrease

## How agents call the model (no API key)

```python
from azure.identity import DefaultAzureCredential
from openai import AzureOpenAI

credential = DefaultAzureCredential()
token = credential.get_token("https://cognitiveservices.azure.com/.default")

client = AzureOpenAI(
    azure_endpoint=os.environ["AZURE_OPENAI_ENDPOINT"],  # from KV via CSI
    azure_ad_token=token.token,
    api_version="2024-10-21",
)

response = client.chat.completions.create(
    model=os.environ["AZURE_OPENAI_DEPLOYMENT"],  # from KV via CSI
    messages=[{"role": "user", "content": "Hello"}],
)
```
