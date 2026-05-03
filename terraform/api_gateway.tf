# Stage 2 — API Gateway HTTP API in front of the same Lambda, with a JWT
# authorizer that validates tokens minted by our gateway's auth-service.
#
# Path:
#   Browser ──(JWT in Authorization header)──► API Gateway ──► Lambda
#
# API Gateway's JWT authorizer fetches the OIDC discovery document at
# `<issuer>/.well-known/openid-configuration`, follows the jwks_uri to
# get the public key, and validates: signature, expiry (exp), issuer
# (iss), and audience (aud). If anything fails → 401, Lambda never runs.
#
# This stage runs side-by-side with Stage 1 (Function URL + IAM auth).
# The same Lambda serves both; it distinguishes the invocation path by
# whether the event carries `requestContext.authorizer.jwt.claims`.

# ---------------------------------------------------------------------------
# HTTP API + CORS
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "lambda_hw" {
  name          = "${var.function_name}-api"
  protocol_type = "HTTP"
  description   = "Browser-direct front door for lambda-hw, JWT-authed via the gateway's auth-service."

  # CORS — restrictive. Only the gateway's own pages can call this from a
  # browser. Server-side callers (curl, iOS) ignore CORS, so this only
  # affects the browser-direct path.
  cors_configuration {
    allow_origins = ["https://apps.ksastry.com"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Authorization", "Content-Type"]
    max_age       = 300
    # allow_credentials defaults to false — we use Bearer tokens, not cookies.
  }
}

# ---------------------------------------------------------------------------
# JWT authorizer
# ---------------------------------------------------------------------------

# Configuration:
#   - identity_sources: where the token comes from on the incoming request.
#     `$request.header.Authorization` is the standard "Bearer <token>" header.
#   - issuer: must match our `iss` claim. API Gateway fetches
#     <issuer>/.well-known/openid-configuration to find the JWKS URI.
#   - audience: must match our `aud` claim. List form per AWS API; we
#     have one entry today, can grow if a token ever needs to work for
#     multiple audiences (rare).

resource "aws_apigatewayv2_authorizer" "gateway_jwt" {
  api_id           = aws_apigatewayv2_api.lambda_hw.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "gateway-jwt"

  jwt_configuration {
    audience = ["lambda-hw"]
    issuer   = "https://apps.ksastry.com/auth"
  }
}

# ---------------------------------------------------------------------------
# Lambda integration + route
# ---------------------------------------------------------------------------

# AWS_PROXY = pass the request through to the Lambda mostly verbatim,
# parsed as the HTTP API v2.0 event shape. The Lambda receives:
#   - event.body                  : request body as a string
#   - event.headers               : request headers
#   - event.requestContext.authorizer.jwt.claims : verified JWT claims
#   - event.requestContext.authorizer.jwt.scopes : (unused for us)
resource "aws_apigatewayv2_integration" "hello" {
  api_id                 = aws_apigatewayv2_api.lambda_hw.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.hello.arn
  payload_format_version = "2.0"
}

# Route: incoming `POST /hello` is dispatched to the Lambda integration,
# but only after the JWT authorizer approves the request.
resource "aws_apigatewayv2_route" "hello" {
  api_id             = aws_apigatewayv2_api.lambda_hw.id
  route_key          = "POST /hello"
  target             = "integrations/${aws_apigatewayv2_integration.hello.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.gateway_jwt.id
}

# ---------------------------------------------------------------------------
# Stage (the deployment surface that gets a public URL)
# ---------------------------------------------------------------------------

# `$default` is a special stage that gets the bare URL (no /stage-name
# prefix). `auto_deploy = true` means route changes go live immediately
# instead of needing an explicit deployment resource.
#
# access_log_settings: per-request structured JSON log written to the
# access log group. API Gateway substitutes $context.* fields at request
# time (not at terraform-plan time). The format is a single JSON line per
# request, parseable directly by Logs Insights — no pattern parsing needed.
#
# What's in each log line:
#   - request shape: method, route, status, latency, size, source IP
#   - integration shape: latency Lambda took, status Lambda returned
#   - auth shape: JWT claims if validation succeeded, error if it didn't
#   - error shape: API Gateway-side errors (e.g., bad JWT, throttled)
# When auth fails, $context.error.* is populated and Lambda is never invoked
# — exactly what we want to see in the audit log.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.lambda_hw.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      requestTime        = "$context.requestTime"
      ip                 = "$context.identity.sourceIp"
      httpMethod         = "$context.httpMethod"
      routeKey           = "$context.routeKey"
      status             = "$context.status"
      responseLength     = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
      integrationStatus  = "$context.integrationStatus"
      # JWT-authorizer fields (populated when auth succeeds)
      authorizerStatus = "$context.authorizer.status"
      userSub          = "$context.authorizer.claims.sub"
      username         = "$context.authorizer.claims.username"
      role             = "$context.authorizer.claims.role"
      # Error fields (populated when API Gateway rejects the request)
      authorizerError   = "$context.authorizer.error"
      errorMessage      = "$context.error.message"
      errorResponseType = "$context.error.responseType"
    })
  }
}

# ---------------------------------------------------------------------------
# Allow API Gateway to invoke the Lambda
# ---------------------------------------------------------------------------

# Same dual-gate model as Stage 1: AWS service-to-service invocations
# need a resource-policy entry on the Lambda. source_arn restricts to
# THIS specific API only (no other API Gateway in the account can use it).
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.lambda_hw.execution_arn}/*/*"
}
