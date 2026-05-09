# Stage 6 chunk C — SQS queue for click-audit events.
#
# Two queues: the main click-audit queue and a dead-letter queue (DLQ)
# for messages that fail repeatedly. Plus an IAM grant on the
# click-handler Lambda's role to publish to the main queue.
#
# The consumer Lambda (chunk D) gets its own IAM grants to RECEIVE
# from the main queue and SEND to nothing. Producer/consumer are
# strictly separated by IAM permissions.

# ---------------------------------------------------------------------------
# Dead-letter queue
# ---------------------------------------------------------------------------
# Receives messages that have been delivered to consumers max_receive_count
# times without successful processing. Operators inspect / replay /
# investigate from here.
#
# 14-day retention (max AWS allows). A non-empty DLQ is the operational
# signal that something is consistently broken in the consumer; we'll
# add an alarm on its depth in a future iteration.

resource "aws_sqs_queue" "click_audit_dlq" {
  name = "${var.function_name}-click-audit-dlq"

  message_retention_seconds = 1209600 # 14 days

  tags = {
    Purpose = "Dead-letter for click_audit messages that failed max_receive_count times"
  }
}

# ---------------------------------------------------------------------------
# Main queue — where the click-handler publishes audit events
# ---------------------------------------------------------------------------
# Standard queue (D6.1): at-least-once delivery, best-effort ordering.
# Consumer must dedupe — done via Postgres ON CONFLICT (request_id).
#
# Redrive policy: after 5 failed delivery attempts (consumer raised an
# exception or timed out before deleting the message), the message
# moves to the DLQ.

resource "aws_sqs_queue" "click_audit" {
  name = "${var.function_name}-click-audit"

  visibility_timeout_seconds = 30      # D6.2 — generous; consumer takes <100ms typically
  message_retention_seconds  = 1209600 # 14 days
  receive_wait_time_seconds  = 20      # long polling — saves cost, lowers latency

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.click_audit_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Purpose = "Click audit events queued for async insert into click_audit table"
  }
}

# ---------------------------------------------------------------------------
# Producer IAM grant — click-handler Lambda's role gets SQS:SendMessage
# ---------------------------------------------------------------------------
# Scoped to the SPECIFIC queue ARN. Even if the Lambda role were
# compromised, the attacker can only enqueue to this one queue, not
# spam other queues in the account.

resource "aws_iam_role_policy" "hello_sqs_send" {
  name = "sqs-send-to-click-audit"
  role = aws_iam_role.hello_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.click_audit.arn
    }]
  })
}
