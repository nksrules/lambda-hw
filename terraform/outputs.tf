output "function_url" {
  description = "Lambda Function URL — Flask uses this as the call target."
  value       = aws_lambda_function_url.hello.function_url
}

output "function_name" {
  description = "Lambda function name (for CloudWatch log group lookup)."
  value       = aws_lambda_function.hello.function_name
}

output "function_arn" {
  description = "Lambda function ARN (used in the EC2 invoker policy)."
  value       = aws_lambda_function.hello.arn
}

output "log_group" {
  description = "CloudWatch log group where the Lambda's stdout/stderr lands."
  value       = "/aws/lambda/${aws_lambda_function.hello.function_name}"
}

output "api_gateway_url" {
  description = "Stage 2 browser-direct invoke URL (JWT-authed via API Gateway)."
  value       = "${aws_apigatewayv2_stage.default.invoke_url}/hello"
}
