resource "aws_budgets_budget" "this" {
  name         = var.budget_name
  budget_type  = "COST"
  limit_amount = tostring(var.hard_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = var.warning_usd
    threshold_type             = "ABSOLUTE_VALUE"
    subscriber_email_addresses = var.notification_email_addresses
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = var.critical_usd
    threshold_type             = "ABSOLUTE_VALUE"
    subscriber_email_addresses = var.notification_email_addresses
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = var.hard_usd
    threshold_type             = "ABSOLUTE_VALUE"
    subscriber_email_addresses = var.notification_email_addresses
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = var.critical_usd
    threshold_type             = "ABSOLUTE_VALUE"
    subscriber_email_addresses = var.notification_email_addresses
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = var.hard_usd
    threshold_type             = "ABSOLUTE_VALUE"
    subscriber_email_addresses = var.notification_email_addresses
  }

  lifecycle {
    precondition {
      condition     = var.warning_usd > 0 && var.warning_usd < var.critical_usd && var.critical_usd < var.hard_usd
      error_message = "Budget thresholds must be positive and ordered warning < critical < hard."
    }
  }
}
