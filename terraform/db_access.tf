# Stage 3 chunk C — wire the Lambda into the data platform.
#
# This file:
#   1. Reads the data-platform's terraform outputs (VPC, subnets, marker SG,
#      DB endpoint, RDS resource ID).
#   2. Creates the Lambda's own security group (per-app marker; rules-empty
#      today, here for future per-Lambda outbound rules).
#   3. Attaches AWSLambdaVPCAccessExecutionRole — required for any
#      VPC-attached Lambda to manage its own ENIs.
#   4. Attaches an inline policy granting rds-db:connect on the specific
#      Postgres user lambda_hw_app on the platform's RDS instance.
#
# The Lambda function itself (vpc_config, environment, architectures) is
# modified in lambda.tf — those bindings naturally live with the function
# resource.

# ---------------------------------------------------------------------------
# Read data-platform's outputs via remote state
# ---------------------------------------------------------------------------
# Cross-repo / cross-project IaC dependency. lambda-hw can be re-applied
# independently of data-platform (it just reads the snapshot of platform
# state). When platform changes (e.g., enable_rds_proxy flipped), a
# subsequent lambda-hw apply picks up the new db_endpoint automatically.

data "terraform_remote_state" "data_platform" {
  backend = "s3"
  config = {
    bucket = "ksastry-tf-state"
    key    = "gateway-data-platform/terraform.tfstate"
    region = "us-east-1"
  }
}

# Account ID is needed for the rds-db:connect policy resource ARN. The
# data source `aws_caller_identity.current` is already declared in
# iam_invoker.tf (originally added for the Function URL aws:SourceAccount
# condition); we reference that one rather than declaring a second.

# ---------------------------------------------------------------------------
# Lambda's own security group
# ---------------------------------------------------------------------------
# No rules right now — admission to RDS happens via the platform's
# tenant-db-client marker SG (also attached to the Lambda's vpc_config).
# This per-app SG is here for future per-Lambda outbound rules (e.g., when
# a future Lambda needs to reach an additional service).

resource "aws_security_group" "lambda_hw" {
  name        = "${var.function_name}-lambda-sg"
  description = "Per-Lambda SG. Marker for future per-Lambda outbound rules; no rules today."
  vpc_id      = data.terraform_remote_state.data_platform.outputs.vpc_id

  tags = {
    Name = "${var.function_name}-lambda-sg"
  }
}

# ---------------------------------------------------------------------------
# IAM: VPC ENI management permission (required for VPC-attached Lambda)
# ---------------------------------------------------------------------------
# Without this managed policy, Lambda can't create/delete ENIs in your
# subnets and the function fails to deploy with a cryptic error. AWS-
# published; just attach.

resource "aws_iam_role_policy_attachment" "hello_vpc_access" {
  role       = aws_iam_role.hello_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ---------------------------------------------------------------------------
# IAM: rds-db:connect, scoped to one Postgres user on one RDS instance
# ---------------------------------------------------------------------------
# Per D3.2 — narrowly scoped. Even if the Lambda role were compromised,
# the attacker can authenticate to the database ONLY as lambda_hw_app
# (which itself has DB-level permissions only to the lambda_hw database).
#
# The Postgres user lambda_hw_app doesn't exist at apply time — it'll be
# created by chunk D's SQL migration. IAM doesn't validate this; it just
# matches the resource ARN at runtime. Forward-declaring this permission
# means there's no "wait, the IAM is wrong" debugging step in chunk D.

resource "aws_iam_role_policy" "hello_rds_connect" {
  name = "rds-db-connect-as-lambda-hw-app"
  role = aws_iam_role.hello_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "rds-db:connect"
      Resource = format(
        "arn:aws:rds-db:%s:%s:dbuser:%s/lambda_hw_app",
        var.region,
        data.aws_caller_identity.current.account_id,
        data.terraform_remote_state.data_platform.outputs.rds_resource_id,
      )
    }]
  })
}
