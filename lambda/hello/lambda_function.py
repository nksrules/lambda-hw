"""lambda-hw — hello-world Lambda serving two front doors.

Stage 1 path: invoked via Function URL with AWS_IAM auth. The Flask app
on EC2 SigV4-signs a POST and includes the user identity in the body
(because the signing identity is the EC2 role, not the user). We trust
Flask because only Flask can produce a valid SigV4 signature.

Stage 2 path: invoked via API Gateway HTTP API with a JWT authorizer.
API Gateway has already validated the JWT (signature + iss + aud + exp)
and attached the claims to event.requestContext.authorizer.jwt.claims.
We trust the claims because only our auth-service holds the private
signing key.

We distinguish the two at runtime by whether `claims` is present, and
echo back which path was taken so the UI can show the side-by-side
comparison.

Stage 4 logging: when the function's `logging_config.log_format` is set
to JSON in terraform, the Lambda runtime turns each `logger.info(...)`
call into a structured CloudWatch event. The `extra={...}` dict gets
merged in at the top level alongside built-in fields like `requestId`,
`level`, `message`, `timestamp`. That makes Logs Insights queries trivial.

No third-party imports — only stdlib.
"""

import json
import logging
import os
import time


# Module-level logger configuration.
# - level INFO captures the bulk of operational logs but skips DEBUG noise.
# - We attach to the root logger because Lambda's runtime instruments root,
#   not the package logger; using __name__ would still work but root is
#   the documented surface.
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _extract_identity(event: dict) -> tuple[str, dict]:
    """Return (invocation_path, identity_dict).

    invocation_path: "api-gateway-jwt" or "function-url-iam".
    identity_dict:   {sub, username, display_name, role}, with None
                     for fields not available on a given path.
    """
    # API Gateway HTTP API attaches verified claims at this path.
    claims = (
        event.get("requestContext", {})
             .get("authorizer", {})
             .get("jwt", {})
             .get("claims", {})
    )
    if claims:
        return "api-gateway-jwt", {
            "sub":          claims.get("sub"),
            "username":     claims.get("username"),
            "display_name": claims.get("display_name"),
            "role":         claims.get("role"),
        }

    # Otherwise: Function URL / Flask path. Identity in the JSON body.
    body_raw = event.get("body") or "{}"
    try:
        body = json.loads(body_raw)
    except json.JSONDecodeError as e:
        logger.warning(
            "invalid_json_body",
            extra={"event": "invalid_json", "error": str(e)},
        )
        body = {}
    return "function-url-iam", {
        "sub":          None,
        "username":     body.get("username"),
        "display_name": body.get("display_name"),
        "role":         None,
    }


def handler(event, context):
    t0 = time.perf_counter()

    invocation_path, ident = _extract_identity(event)
    display_name = ident["display_name"] or "stranger"

    response = {
        "greeting": f"hello, {display_name}",
        "invocation_path": invocation_path,
        "received_identity": ident,
        "stage": 2,
        "lambda": {
            "function_name": context.function_name,
            "request_id":    context.aws_request_id,
            "remaining_ms":  context.get_remaining_time_in_millis(),
            "region":        os.environ.get("AWS_REGION"),
            "memory_mb":     context.memory_limit_in_mb,
        },
        "server_time_unix": int(time.time()),
    }

    out = {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(response),
    }

    latency_ms = int((time.perf_counter() - t0) * 1000)
    # One structured event per invocation. Goes into CloudWatch Logs as
    # JSON because logging_config.log_format = "JSON" in terraform.
    # Logs Insights queries:
    #   fields @timestamp, invocation_path, latency_ms, status
    #   | filter level = "INFO" and event = "invocation"
    #   | stats avg(latency_ms), count() by invocation_path
    logger.info(
        "invocation",
        extra={
            "event":           "invocation",
            "invocation_path": invocation_path,
            "username":        ident["username"],
            "display_name":    ident["display_name"],
            "latency_ms":      latency_ms,
            "status":          out["statusCode"],
        },
    )

    return out
