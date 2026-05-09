# The Lambda function itself, its execution role, and the Function URL.
#
# The package is built at plan time by zipping ../lambda/hello. No external
# dependencies = no build step needed. When that stops being true (e.g., when
# we add a third-party library to the Lambda), we'll switch to a Lambda layer
# or a Docker image.

data "archive_file" "hello_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/hello"
  output_path = "${path.module}/build/hello.zip"
}

# Execution role: the identity the Lambda *itself* runs as.
# (Distinct from the invoker identity, which is whoever calls the Function URL.)
# One exec role per Lambda — name the handle after the function so future
# Lambdas in this project (db_writer, queue_consumer, etc.) get their own.
resource "aws_iam_role" "hello_exec" {
  name = "${var.function_name}-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Standard managed policy: lets the Lambda write to its CloudWatch log group.
# Without this you'd get permission errors trying to log anything.
resource "aws_iam_role_policy_attachment" "hello_logs" {
  role       = aws_iam_role.hello_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "hello" {
  function_name = var.function_name
  role          = aws_iam_role.hello_exec.arn
  runtime       = "python3.12"
  architectures = ["arm64"] # Stage 3 D3.4 — Graviton, matches DB architecture, ~20% cheaper compute
  handler       = "lambda_function.handler"

  filename         = data.archive_file.hello_zip.output_path
  source_code_hash = data.archive_file.hello_zip.output_base64sha256

  # Stage 3 chunk E.1 — Postgres driver layer. Lambda runtime mounts
  # this at /opt/python/, so `import psycopg` resolves at handler time.
  layers = [aws_lambda_layer_version.psycopg.arn]

  # Bumped from 5/128 in Stage 3: DB connection setup adds latency,
  # psycopg in memory adds footprint. Lambda CPU also scales with memory,
  # so 256 MB is faster on the same workload.
  timeout     = 10
  memory_size = 256

  # Stage 5 D5.2 — hard cap on simultaneous invocations. Caps blast
  # radius if traffic spikes (DB connection pool exhaustion, runaway
  # cost). Existing CloudWatch alarm `${function_name}-throttles` from
  # Stage 4 will fire if this is hit. Reserved concurrency also removes
  # capacity from the account-wide unreserved pool (default 1000), so
  # this directly costs 10 invocations of headroom for any future
  # unreserved Lambda in this account.
  reserved_concurrent_executions = 10

  # Stage 3 chunk C — VPC config: place the Lambda in the data-platform's
  # private subnets, with both this app's SG and the platform's
  # tenant-db-client marker SG. The marker is the admission ticket; the
  # platform's RDS-side SG allows ingress from it.
  vpc_config {
    subnet_ids = values(data.terraform_remote_state.data_platform.outputs.private_subnet_ids)
    security_group_ids = [
      aws_security_group.lambda_hw.id,
      data.terraform_remote_state.data_platform.outputs.tenant_db_client_sg_id,
    ]
  }

  # Stage 3 chunk C — env vars consumed by the Lambda code in chunk E.
  # DB_ENDPOINT is sourced from the platform's terraform output and
  # transparently flips between Proxy endpoint and direct RDS endpoint
  # depending on platform's enable_rds_proxy variable. Lambda code
  # connects to whatever this resolves to without knowing which.
  #
  # Stage 6 — SQS_AUDIT_URL is conditional on the platform's SQS VPC
  # endpoint being available. If the endpoint is disabled, the Lambda
  # in private subnets has no route to SQS; calling it would hang
  # until Lambda timeout. We set the env var to empty string in that
  # case, and the producer code's `if not SQS_AUDIT_URL: return`
  # short-circuit handles graceful degradation (audit just skips).
  environment {
    variables = {
      DB_ENDPOINT = data.terraform_remote_state.data_platform.outputs.db_endpoint
      DB_NAME     = "lambda_hw"
      DB_USER     = "lambda_hw_app"
      SQS_AUDIT_URL = (
        data.terraform_remote_state.data_platform.outputs.sqs_vpc_endpoint_enabled
        ? aws_sqs_queue.click_audit.url
        : ""
      )
    }
  }

  # Stage 4: structured JSON logging.
  # When log_format = "JSON", the Lambda runtime turns every log event
  # (including ours via logger.info(..., extra={...})) into a JSON
  # object at the top level: {timestamp, level, message, requestId, ...}
  # plus our extra fields. Logs Insights queries fields directly.
  logging_config {
    log_format            = "JSON"
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }
}

# The HTTPS endpoint attached directly to the function.
# AWS_IAM means: every request must be SigV4-signed AND the signing identity
# must hold lambda:InvokeFunctionUrl on this function ARN.
resource "aws_lambda_function_url" "hello" {
  function_name      = aws_lambda_function.hello.function_name
  authorization_type = "AWS_IAM"
}
