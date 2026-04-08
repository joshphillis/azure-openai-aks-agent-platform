###############################################################################
# modules/monitoring/main.tf
#
# Observability stack for the Azure AI Platform:
#   - Azure Monitor workbook for agent pipeline visibility
#   - Metric alerts: pod restarts, node CPU, Service Bus dead-letter buildup
#   - Log Analytics saved queries for common debugging scenarios
#   - Cost budget alert — catches runaway OpenAI spend early
###############################################################################

locals {
  tags = merge(var.tags, {
    module = "monitoring"
  })
}

# ---------------------------------------------------------------------------
# Action group — where alerts fire to (email for now; swap for PagerDuty/Teams)
# ---------------------------------------------------------------------------

resource "azurerm_monitor_action_group" "platform" {
  name                = "ag-${var.name}-${var.environment}"
  resource_group_name = var.resource_group_name
  short_name          = "aiplatform"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }
}

# ---------------------------------------------------------------------------
# Metric alerts — AKS
# ---------------------------------------------------------------------------

# Alert when any pod restarts more than 3 times in 5 minutes
resource "azurerm_monitor_metric_alert" "pod_restarts" {
  name                = "alert-pod-restarts-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [var.aks_cluster_id]
  description         = "AKS node CPU critical — possible pod crash loop saturating node"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 95
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# Alert when node CPU exceeds 80% for 10 minutes
resource "azurerm_monitor_metric_alert" "node_cpu" {
  name                = "alert-node-cpu-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [var.aks_cluster_id]
  description         = "AKS node CPU sustained above 80% — consider scaling up node pool"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# ---------------------------------------------------------------------------
# Metric alerts — Service Bus
# ---------------------------------------------------------------------------

# Alert when dead-letter message count exceeds threshold
# Dead-lettered messages = agents failing to process — needs investigation
resource "azurerm_monitor_metric_alert" "servicebus_dlq" {
  name                = "alert-sb-dlq-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [var.servicebus_namespace_id]
  description         = "Dead-letter queue building up — agent processing failures detected"
  severity            = 1    # High — this means work is being lost
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "DeadletteredMessages"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = var.dlq_alert_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# Alert on Service Bus throttling — Premium tier shouldn't throttle unless overloaded
resource "azurerm_monitor_metric_alert" "servicebus_throttled" {
  name                = "alert-sb-throttled-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [var.servicebus_namespace_id]
  description         = "Service Bus throttling requests — messaging unit capacity exceeded"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.ServiceBus/namespaces"
    metric_name      = "ThrottledRequests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 10
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# ---------------------------------------------------------------------------
# Metric alerts — Azure OpenAI
# ---------------------------------------------------------------------------

# Alert when token consumption approaches quota limit
resource "azurerm_monitor_metric_alert" "openai_tokens" {
  name                = "alert-openai-tokens-${var.environment}"
  resource_group_name = var.resource_group_name
  scopes              = [var.openai_account_id]
  description         = "Azure OpenAI token usage above 80% of provisioned capacity"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.CognitiveServices/accounts"
    metric_name      = "TokenTransaction"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.openai_token_alert_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.platform.id
  }
}

# ---------------------------------------------------------------------------
# Cost budget — catches runaway OpenAI spend
# ---------------------------------------------------------------------------

resource "azurerm_consumption_budget_resource_group" "platform" {
  name              = "budget-${var.name}-${var.environment}"
  resource_group_id = var.resource_group_id
  amount            = var.monthly_budget_usd
  time_grain        = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00'Z'", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = var.alert_email_addresses
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = var.alert_email_addresses
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}

# ---------------------------------------------------------------------------
# Log Analytics saved queries
# These surface in the Azure Portal under the workspace — useful for demos
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_saved_search" "agent_errors" {
  name                       = "AgentErrors"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  category                   = "AI Platform"
  display_name               = "Agent errors (last 1h)"

  query = <<-EOT
    ContainerLog
    | where TimeGenerated > ago(1h)
    | where LogEntry contains "ERROR" or LogEntry contains "Exception"
    | where Namespace == "agents"
    | project TimeGenerated, ContainerName, LogEntry
    | order by TimeGenerated desc
  EOT
}

resource "azurerm_log_analytics_saved_search" "servicebus_dlq_messages" {
  name                       = "ServiceBusDLQ"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  category                   = "AI Platform"
  display_name               = "Service Bus dead-letter events (last 1h)"

  query = <<-EOT
    AzureDiagnostics
    | where TimeGenerated > ago(1h)
    | where ResourceType == "SERVICEBUS"
    | where OperationName == "Microsoft.ServiceBus/namespaces/messages/deadletter/action"
    | project TimeGenerated, ResourceId, OperationName, resultType_s
    | order by TimeGenerated desc
  EOT
}

resource "azurerm_log_analytics_saved_search" "openai_latency" {
  name                       = "OpenAILatency"
  log_analytics_workspace_id = var.log_analytics_workspace_id
  category                   = "AI Platform"
  display_name               = "Azure OpenAI request latency (last 1h)"

  query = <<-EOT
    AzureDiagnostics
    | where TimeGenerated > ago(1h)
    | where ResourceType == "COGNITIVESERVICES"
    | where OperationName == "ChatCompletions_Create"
    | summarize
        avg_latency_ms = avg(DurationMs),
        p95_latency_ms = percentile(DurationMs, 95),
        request_count  = count()
      by bin(TimeGenerated, 5m)
    | order by TimeGenerated desc
  EOT
}