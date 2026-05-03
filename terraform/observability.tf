# Stage 4 — observability. Per decision doc 0003:
#   - Lambda log group with 15-day retention (D4.2)
#   - One SNS topic for all alarm emails (D4.4)
#   - Two CloudWatch alarms: error rate + throttles (D4.4)
#   - One project dashboard (D4.5)
#
# AWS Budgets cost alarm lives in budgets.tf — different service.
# API Gateway access logs land in chunk D.

# ---------------------------------------------------------------------------
# Lambda log group — explicit terraform management for retention
# ---------------------------------------------------------------------------
# The Lambda runtime auto-creates this log group on first invocation if it
# doesn't exist, so terraform may need to import it. After this resource is
# in place, terraform owns retention; AWS still writes log events into it.
#
# One-time import (run BEFORE first apply that includes this resource):
#   terraform import aws_cloudwatch_log_group.hello /aws/lambda/lambda-hw-hello
#
# If you ever destroy + recreate the Lambda function, this log group can be
# recreated cleanly because nothing else references it.

resource "aws_cloudwatch_log_group" "hello" {
  name = "/aws/lambda/${var.function_name}"
  # AWS CloudWatch Logs supports only specific retention values:
  # 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
  # 1096, 1827, 2192, 2557, 2922, 3288, 3653. We chose 15 in the
  # decision doc; AWS snaps to 14 (closest under), matching the
  # "short, debug-flavored" intent of D4.2.
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# API Gateway access log group — audit-flavored, 60-day retention (D4.2)
# ---------------------------------------------------------------------------
# Separate log group from the Lambda's so we can give each its own retention,
# IAM scope, and Logs Insights queries (D4.3). Each request to the API
# Gateway produces one structured JSON line here, regardless of whether the
# request reached the Lambda — failed JWT auth, 4xx/5xx, etc. all log here.
#
# This log group does NOT exist before terraform creates it, so no import
# step is needed (unlike the Lambda log group which AWS auto-created).

resource "aws_cloudwatch_log_group" "api_gateway_access" {
  name              = "/aws/apigateway/${var.function_name}"
  retention_in_days = 60
}

# ---------------------------------------------------------------------------
# SNS topic — single endpoint for all alarm emails
# ---------------------------------------------------------------------------
# Per D4.4: one topic, one subscription, all alarm fanout from here. If we
# ever want different categories of alarm to go to different addresses, we
# add a topic, not more subscriptions on this one.

resource "aws_sns_topic" "alarms" {
  name = "${var.function_name}-alarms"
}

# Email subscription requires manual confirmation: AWS sends a "Subscription
# Confirmation" email to var.alarm_email; the user must click the
# confirmation link before any alarm emails are actually delivered. Until
# confirmed, alarms still fire (CloudWatch reaches an ALARM state) but the
# SNS publish is dropped.
#
# Confirmation status: aws sns list-subscriptions-by-topic --topic-arn ...
resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------------------
# Alarm 1 — Lambda error rate (persistent, not transient)
# ---------------------------------------------------------------------------
# Errors >= 1 in EACH of 3 consecutive 5-min windows. A single transient
# error self-clears with no email; sustained errors page.
#
# treat_missing_data = "notBreaching": when the Lambda hasn't been invoked,
# the metric has no data points; we treat that as "not in alarm" rather than
# "in alarm" (which would page constantly when traffic is low).

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.function_name}-errors"
  alarm_description   = "Lambda errors persisting across multiple 5-min windows"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.hello.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn] # email when it clears, too
}

# ---------------------------------------------------------------------------
# Alarm 2 — Lambda throttle (any throttle is suspicious at our scale)
# ---------------------------------------------------------------------------
# At our scale (handful of invocations per day), even one throttle indicates
# either a misconfiguration or account-level concurrency cap. Always-page.

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.function_name}-throttles"
  alarm_description   = "Lambda invocation throttled — concurrency limit hit"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.hello.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ---------------------------------------------------------------------------
# Project dashboard
# ---------------------------------------------------------------------------
# Per D4.5: one dashboard, key signals at a glance. Free tier covers up to
# three dashboards across the account, so this costs nothing.

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.function_name}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda invocations / errors / throttles"
          region = var.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", aws_lambda_function.hello.function_name],
            [".", "Errors", ".", "."],
            [".", "Throttles", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda duration p50 / p95 / max (ms)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.hello.function_name, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }],
            ["...", { stat = "Maximum", label = "max" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway requests / 4xx / 5xx"
          region = var.region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.lambda_hw.id, "Stage", aws_apigatewayv2_stage.default.name],
            [".", "4xx", ".", ".", ".", "."],
            [".", "5xx", ".", ".", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway latency p50 / p95 (ms)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", aws_apigatewayv2_api.lambda_hw.id, "Stage", aws_apigatewayv2_stage.default.name, { stat = "p50", label = "p50" }],
            ["...", { stat = "p95", label = "p95" }]
          ]
        }
      }
    ]
  })
}
