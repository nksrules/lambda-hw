# Stage 6 chunk D — audit consumer Lambda.
#
# A second Lambda function in this project. Pulled by AWS from the
# click-audit SQS queue via event source mapping; its job is to write
# each click event into the click_audit table.
#
# Chunk D scope: the infrastructure (Lambda + IAM + VPC config + log
# group + event source mapping) with a stub handler that just logs.
# Chunk E replaces the stub with real DB-insert code.
#
# The consumer is structurally similar to the click-handler (Stage 3)
# but with different IAM scope:
#   - DB user: lambda_hw_audit (not lambda_hw_app)
#   - SQS perms: receive/delete from click-audit (not send)
#   - Smaller concurrency cap: 5 (not 10)
#
# Reuses without change:
#   - psycopg layer (aws_lambda_layer_version.psycopg from lambda_layer.tf)
#   - Platform networking (subnets, marker SG via remote_state)
#   - Same arm64 architecture, JSON log format, env-var pattern

# ---------------------------------------------------------------------------
# Package the consumer code
# ---------------------------------------------------------------------------

data "archive_file" "audit_consumer_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/audit_consumer"
  output_path = "${path.module}/build/audit-consumer.zip"
}

# ---------------------------------------------------------------------------
# Execution role + standard policy attachments
# ---------------------------------------------------------------------------

resource "aws_iam_role" "audit_consumer_exec" {
  name = "lambda-hw-audit-consumer-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Basic execution role: write to CloudWatch Logs
resource "aws_iam_role_policy_attachment" "audit_consumer_logs" {
  role       = aws_iam_role.audit_consumer_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC access: manage ENIs in our private subnets
resource "aws_iam_role_policy_attachment" "audit_consumer_vpc" {
  role       = aws_iam_role.audit_consumer_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ---------------------------------------------------------------------------
# IAM: rds-db:connect scoped to the audit-only Postgres user
# ---------------------------------------------------------------------------
# Per D6.10 — separate from the click-handler's lambda_hw_app user.
# Even if this consumer is compromised, it can read/write only
# click_audit, not user_visits.

resource "aws_iam_role_policy" "audit_consumer_rds_connect" {
  name = "rds-db-connect-as-lambda-hw-audit"
  role = aws_iam_role.audit_consumer_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "rds-db:connect"
      Resource = format(
        "arn:aws:rds-db:%s:%s:dbuser:%s/lambda_hw_audit",
        var.region,
        data.aws_caller_identity.current.account_id,
        data.terraform_remote_state.data_platform.outputs.rds_resource_id,
      )
    }]
  })
}

# ---------------------------------------------------------------------------
# IAM: SQS permissions scoped to the click-audit queue only
# ---------------------------------------------------------------------------
# AWS provides a managed policy `AWSLambdaSQSQueueExecutionRole` that
# grants these actions on ALL SQS queues in the account. We use an
# inline policy scoped to one queue ARN — narrower blast radius if
# the role were ever misused.

resource "aws_iam_role_policy" "audit_consumer_sqs_consume" {
  name = "sqs-consume-click-audit"
  role = aws_iam_role.audit_consumer_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = aws_sqs_queue.click_audit.arn
    }]
  })
}

# ---------------------------------------------------------------------------
# Per-Lambda security group (Stage 3 D3.7 pattern)
# ---------------------------------------------------------------------------
# No rules of its own; the marker SG (tenant-db-client, attached below)
# is what grants DB access. Per-Lambda SG is here for any future
# per-Lambda outbound rules.

resource "aws_security_group" "audit_consumer" {
  name        = "lambda-hw-audit-consumer-sg"
  description = "Per-Lambda SG for the audit consumer; rules-empty today."
  vpc_id      = data.terraform_remote_state.data_platform.outputs.vpc_id

  tags = {
    Name = "lambda-hw-audit-consumer-sg"
  }
}

# ---------------------------------------------------------------------------
# CloudWatch log group with retention (matching click-handler at 14d)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "audit_consumer" {
  name              = "/aws/lambda/lambda-hw-audit-consumer"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# The Lambda function itself
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "audit_consumer" {
  function_name = "lambda-hw-audit-consumer"
  role          = aws_iam_role.audit_consumer_exec.arn
  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "lambda_function.handler"

  filename         = data.archive_file.audit_consumer_zip.output_path
  source_code_hash = data.archive_file.audit_consumer_zip.output_base64sha256

  timeout     = 30 # generous; visibility timeout on the queue is also 30
  memory_size = 256

  # Stage 6 D6.4 — concurrency cap. Scales to zero when idle (this is
  # a maximum, not a minimum).
  reserved_concurrent_executions = 5

  layers = [aws_lambda_layer_version.psycopg.arn]

  vpc_config {
    subnet_ids = values(data.terraform_remote_state.data_platform.outputs.private_subnet_ids)
    security_group_ids = [
      aws_security_group.audit_consumer.id,
      data.terraform_remote_state.data_platform.outputs.tenant_db_client_sg_id,
    ]
  }

  environment {
    variables = {
      DB_ENDPOINT = data.terraform_remote_state.data_platform.outputs.db_endpoint
      DB_NAME     = "lambda_hw"
      DB_USER     = "lambda_hw_audit"
    }
  }

  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }

  # Don't try to invoke the function before its log group exists;
  # otherwise Lambda creates the log group automatically (without our
  # retention setting) and terraform's later attempt to create it
  # collides.
  depends_on = [aws_cloudwatch_log_group.audit_consumer]
}

# ---------------------------------------------------------------------------
# Event source mapping: SQS click-audit → audit-consumer Lambda
# ---------------------------------------------------------------------------
# This is the "magic wiring." AWS Lambda service polls the queue (with
# long polling — 20s wait), accumulates messages into batches per the
# settings below, and invokes the consumer with each batch.
#
# We don't write any polling code; AWS does it.
#
# Per D6.5: batch_size 10, batching_window 5s.
#
# function_response_types = ["ReportBatchItemFailures"] enables the
# partial-batch-failure protocol. The consumer can return
# `{"batchItemFailures": [{"itemIdentifier": "<messageId>"}, ...]}` to
# tell AWS "delete the successful ones, retry only these specific
# message IDs." Without this setting, any exception fails the WHOLE
# batch and all messages return to the queue.

resource "aws_lambda_event_source_mapping" "audit_consumer" {
  event_source_arn = aws_sqs_queue.click_audit.arn
  function_name    = aws_lambda_function.audit_consumer.arn

  batch_size                         = 10
  maximum_batching_window_in_seconds = 5

  function_response_types = ["ReportBatchItemFailures"]
}
