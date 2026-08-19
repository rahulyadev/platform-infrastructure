output "budget_name" {
  description = "Created monthly budget name."
  value       = aws_budgets_budget.this.name
}
