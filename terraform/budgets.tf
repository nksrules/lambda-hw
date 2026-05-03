# Stage 4 — AWS Budgets cost alarm (separate AWS service from CloudWatch).
#
# Per D4.4: $5/month threshold, with notifications at 80% (forecasted) and
# 100% (actual). The forecasted one is the canary: AWS predicts your
# spending trajectory based on the month-to-date pace and emails when the
# forecast crosses 80%. The actual one is the breaker: emails when actual
# month-to-date crosses 100%.
#
# Scope: this budget watches the WHOLE account, not just lambda-hw
# resources. Reason: scoping by tag requires "cost-allocation tags" to be
# manually activated in the Billing console, which is an account-wide
# step we'd rather not assume. At our actual cost (<$2/month observed),
# a $5 account-wide budget is effectively a project budget.
#
# When we have multiple projects sharing this account, switch to a tag-
# scoped budget (cost_filter on Project=lambda-hw, etc.) and add per-app
# budgets for each.

resource "aws_budgets_budget" "monthly" {
  name         = "monthly-aws-cost"
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 80% FORECASTED — AWS predicts where the bill will land at month-end
  # given the current pace, and emails when that prediction crosses
  # the threshold. Best early warning of unusual spend.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alarm_email]
  }

  # 100% ACTUAL — month-to-date spend has crossed the threshold.
  # Definitive trigger; a real "look at this now" event.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alarm_email]
  }
}
