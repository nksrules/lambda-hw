# Grant the existing EC2 instance role permission to invoke the Function URL.
#
# Two trust gates have to align for the call to succeed:
#   1. The IAM identity calling the URL must be allowed to call
#      lambda:InvokeFunctionUrl on this specific function ARN. (This file.)
#   2. The function's auth type must accept that identity. (lambda.tf:
#      authorization_type = "AWS_IAM".)
#
# The condition below is defense in depth: it ensures this permission only
# applies when the function URL is configured for AWS_IAM auth. If someone
# later flipped the URL to NONE (public), this grant would no longer attach,
# making the change visible.

data "aws_iam_role" "ec2_invoker" {
  name = var.ec2_invoker_role_name
}

resource "aws_iam_role_policy" "invoke_lambda_hw" {
  name = "invoke-${var.function_name}"
  role = data.aws_iam_role.ec2_invoker.name

  # Empirically, Function URL invocations in this account require BOTH
  # lambda:InvokeFunctionUrl (documented) AND lambda:InvokeFunction
  # (undocumented for this case). Without InvokeFunction, the URL returns
  # 403 AccessDeniedException at runtime — even though AWS docs say only
  # InvokeFunctionUrl is needed for URL invocations. See decision doc 0001
  # for the debugging trail. May be IAM caching; keeping both is safe.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "lambda:InvokeFunctionUrl",
        "lambda:InvokeFunction",
      ]
      Resource = aws_lambda_function.hello.arn
    }]
  })
}

# Function URL invocations require a resource-based policy on the function
# IN ADDITION to the identity-based policy above. The canonical AWS pattern
# uses Principal "*" with the lambda:FunctionUrlAuthType=AWS_IAM condition,
# letting the IAM identity policy do the actual restriction. (Naming a
# specific role principal here was observed not to authorize at runtime.)
resource "aws_lambda_permission" "hello_url_invoke" {
  statement_id           = "AllowAnyIAMPrincipal"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.hello.function_name
  principal              = "*"
  function_url_auth_type = "AWS_IAM"
}
