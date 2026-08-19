locals {
  default_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "opentofu"
    Repository  = "rahulyadev/platform-infrastructure"
  }
}

module "monthly_budget" {
  source = "../../modules/monthly_budget"

  budget_name                  = "${var.project_name}-${var.environment}-monthly-cost"
  notification_email_addresses = var.notification_email_addresses
  warning_usd                  = var.warning_usd
  critical_usd                 = var.critical_usd
  hard_usd                     = var.hard_usd
}
