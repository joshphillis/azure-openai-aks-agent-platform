# modules/networking

Creates the private VNet foundation for the Azure AI Platform.

## What this module provisions

| Resource | Purpose |
|---|---|
| Virtual Network | Private address space for all platform workloads |
| `snet-aks-nodes` | AKS node pool NICs |
| `snet-aks-pods` | AKS pod overlay (Azure CNI) |
| `snet-private-endpoints` | NICs for Key Vault, ACR, OpenAI, Service Bus PEs |
| NSG: aks-nodes | Deny internet egress; allow Azure services + DNS |
| NSG: private-endpoints | Allow inbound from AKS nodes only |
| Private DNS zone: Key Vault | `privatelink.vaultcore.azure.net` |
| Private DNS zone: ACR | `privatelink.azurecr.io` |
| Private DNS zone: OpenAI | `privatelink.openai.azure.com` |
| Private DNS zone: Service Bus | `privatelink.servicebus.windows.net` |
| VNet links (x4) | Bind each DNS zone to the VNet for internal resolution |

## Design decisions

**No public IPs on workloads.** The NSG on the AKS node subnet explicitly denies
internet egress. Agents reach Azure services exclusively via private endpoints,
which resolve to RFC 1918 addresses through the private DNS zones.

**Separate subnets for nodes and pods.** Using Azure CNI Overlay means pods get
IPs from `snet-aks-pods`, keeping the node subnet small and predictable for NSG
rules and private endpoint planning.

**DNS zones live here, not in each service module.** Centralising the zones in
networking means there's one place to audit all private DNS configuration. Each
service module receives the zone ID as an input and registers its A record there.

## Usage

```hcl
module "networking" {
  source = "../../modules/networking"

  name                   = "aiplatform"
  environment            = "dev"
  location               = "eastus2"
  resource_group_name    = azurerm_resource_group.main.name
  vnet_address_space     = "10.0.0.0/16"
  aks_nodes_cidr         = "10.0.1.0/24"
  aks_pods_cidr          = "10.0.2.0/23"
  private_endpoints_cidr = "10.0.4.0/27"
  tags                   = local.common_tags
}
```

## Outputs consumed by other modules

| Output | Consumed by |
|---|---|
| `vnet_id` | aks, monitoring |
| `aks_nodes_subnet_id` | aks |
| `private_endpoints_subnet_id` | openai, keyvault, acr, servicebus |
| `dns_zone_id_keyvault` | keyvault |
| `dns_zone_id_acr` | acr |
| `dns_zone_id_openai` | openai |
| `dns_zone_id_servicebus` | servicebus |
