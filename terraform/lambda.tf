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
  handler       = "lambda_function.handler"

  filename         = data.archive_file.hello_zip.output_path
  source_code_hash = data.archive_file.hello_zip.output_base64sha256

  timeout     = 5   # seconds; hello world should be near-instant
  memory_size = 128 # MB; smallest tier
}

# The HTTPS endpoint attached directly to the function.
# AWS_IAM means: every request must be SigV4-signed AND the signing identity
# must hold lambda:InvokeFunctionUrl on this function ARN.
resource "aws_lambda_function_url" "hello" {
  function_name      = aws_lambda_function.hello.function_name
  authorization_type = "AWS_IAM"
}
