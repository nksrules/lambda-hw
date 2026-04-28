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

No third-party imports — only stdlib — so packaging stays trivial.
"""

import json
import os
import time


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
    except json.JSONDecodeError:
        body = {}
    return "function-url-iam", {
        "sub":          None,
        "username":     body.get("username"),
        "display_name": body.get("display_name"),
        "role":         None,
    }


def handler(event, context):
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

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(response),
    }
