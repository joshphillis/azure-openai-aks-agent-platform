###############################################################################
# modules/servicebus/main.tf
#
# Azure Service Bus for the AI Platform multi-agent event backbone:
#   - Premium tier namespace (required for private endpoints + VNet)
#   - Private endpoint (no public access)
#   - One topic per agent type + a results topic for completed work
#   - Subscriptions with filters so each agent only receives its own messages
#   - Dead-letter queues enabled on all subscriptions
#   - RBAC authorization — managed identity only, no connection strings
#   - Diagnostic logs to Log Analytics
###############################################################################

locals {
  tags = merge(var.tags, {
    module = "servicebus"
  })

  namespace_name = "sb-${var.name}-${var.environment}-${var.suffix}"
}

# ---------------------------------------------------------------------------
# Service Bus namespace — Premium required for private endpoints
# ---------------------------------------------------------------------------

resource "azurerm_servicebus_namespace" "main" {
  name                          = local.namespace_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  sku                           = "Premium"
  capacity                      = 1
  premium_messaging_partitions  = 1
  public_network_access_enabled = false
  local_auth_enabled            = false       # Managed identity only, no connection strings
  tags                          = local.tags
}

# ---------------------------------------------------------------------------
# Private endpoint
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "servicebus" {
  name                = "pe-${local.namespace_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoints_subnet_id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.namespace_name}"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dns-${local.namespace_name}"
    private_dns_zone_ids = [var.dns_zone_id_servicebus]
  }
}

# ---------------------------------------------------------------------------
# Topics — one per agent type, one for results
#
# Flow:
#   orchestrator → publishes to research-tasks, analysis-tasks, writer-tasks
#   agents       → subscribe to their own topic
#   agents       → publish completed work to agent-results
#   orchestrator → subscribes to agent-results, aggregates by correlation ID
# ---------------------------------------------------------------------------

resource "azurerm_servicebus_topic" "topics" {
  for_each = toset(var.topic_names)

  name                          = each.key
  namespace_id                  = azurerm_servicebus_namespace.main.id
  max_message_size_in_kilobytes = 1024     # Minimum for Premium tier
  default_message_ttl           = "PT1H"
  batched_operations_enabled    = true

  # Duplicate detection window — prevents double-processing if publisher retries
  requires_duplicate_detection                = true
  duplicate_detection_history_time_window     = "PT10M"
}

# ---------------------------------------------------------------------------
# Subscriptions
#
# Each agent gets one subscription on its topic.
# The orchestrator gets one subscription on the results topic.
# ---------------------------------------------------------------------------

locals {
  subscriptions = {
    "research-tasks"   = { topic = "research-tasks",   subscriber = "research-agent" }
    "analysis-tasks"   = { topic = "analysis-tasks",   subscriber = "analysis-agent" }
    "writer-tasks"     = { topic = "writer-tasks",     subscriber = "writer-agent" }
    "agent-results"    = { topic = "agent-results",    subscriber = "orchestrator" }
  }
}

resource "azurerm_servicebus_subscription" "subscriptions" {
  for_each = local.subscriptions

  name                                 = "sub-${each.value.subscriber}"
  topic_id                             = azurerm_servicebus_topic.topics[each.value.topic].id
  max_delivery_count                   = 5
  dead_lettering_on_message_expiration = true
  lock_duration                        = "PT2M"
  batched_operations_enabled           = true
}

resource "azurerm_servicebus_subscription" "dead_letter_monitor" {
  for_each = toset(var.topic_names)

  name                                      = "sub-dlq-monitor"
  topic_id                                  = azurerm_servicebus_topic.topics[each.key].id
  max_delivery_count                        = 1
  forward_dead_lettered_messages_to         = null
  lock_duration                             = "PT1M"
  batched_operations_enabled                = true
}

# ---------------------------------------------------------------------------
# RBAC
#
# Orchestrator: Sender on task topics + Receiver on results topic
# Worker agents: Receiver on their own topic + Sender on results topic
# ---------------------------------------------------------------------------

# Orchestrator — send to all task topics
resource "azurerm_role_assignment" "orchestrator_sender" {
  for_each = toset(["research-tasks", "analysis-tasks", "writer-tasks"])

  scope                = "${azurerm_servicebus_namespace.main.id}/topics/${each.key}"
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = var.agent_identity_principal_ids["orchestrator"]
}

# Orchestrator — receive from results topic
resource "azurerm_role_assignment" "orchestrator_receiver" {
  scope                = "${azurerm_servicebus_namespace.main.id}/topics/agent-results"
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = var.agent_identity_principal_ids["orchestrator"]
}

# Worker agents — receive from their own topic
resource "azurerm_role_assignment" "worker_receiver" {
  for_each = {
    "research-agent"  = "research-tasks"
    "analysis-agent"  = "analysis-tasks"
    "writer-agent"    = "writer-tasks"
  }

  scope                = "${azurerm_servicebus_namespace.main.id}/topics/${each.value}"
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = var.agent_identity_principal_ids[each.key]
}

# Worker agents — send to results topic
resource "azurerm_role_assignment" "worker_sender" {
  for_each = toset(["research-agent", "analysis-agent", "writer-agent"])

  scope                = "${azurerm_servicebus_namespace.main.id}/topics/agent-results"
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = var.agent_identity_principal_ids[each.key]
}

# ---------------------------------------------------------------------------
# Store namespace hostname in Key Vault
# Agents resolve this at runtime — no hardcoded hostnames in manifests
# ---------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "servicebus_namespace" {
  name         = "servicebus-namespace"
  value        = "${local.namespace_name}.servicebus.windows.net"
  key_vault_id = var.keyvault_id
  tags         = local.tags
}

# ---------------------------------------------------------------------------
# Diagnostic settings
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "servicebus" {
  name                       = "diag-${local.namespace_name}"
  target_resource_id         = azurerm_servicebus_namespace.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "OperationalLogs" }
  enabled_log { category = "VNetAndIPFilteringLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
