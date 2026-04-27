"""lambda-hw Stage 1 — hello-world Lambda.

Invoked via a Function URL with AWS_IAM auth. The Flask app on EC2 calls this
URL with a SigV4-signed POST containing a JSON body like:

    {
        "username":     "<gateway X-User header value>",
        "display_name": "<gateway X-User-Display header value>"
    }

The greeting uses display_name (human-readable). Username is forwarded too
but unused today — future stages will use it as a stable identifier for
per-user authorization (e.g., row-level access in the database, or as a
JWT claim once we add API Gateway).

No third-party imports — only stdlib — so packaging stays trivial (plain
ZIP, no Lambda layer, no build step).
"""

import json
import os
import time


def handler(event, context):
    # Function URL invocations put the JSON body in event["body"] as a string.
    body_raw = event.get("body") or "{}"
    try:
        body = json.loads(body_raw)
    except json.JSONDecodeError:
        body = {}

    username = body.get("username")           # reserved for future authz use
    display_name = body.get("display_name", "stranger")

    response = {
        "greeting": f"hello, {display_name}",
        "received_username": username,        # echoed so we can see it arrived
        "stage": 1,
        "lambda": {
            "function_name": context.function_name,
            "request_id": context.aws_request_id,
            "remaining_ms": context.get_remaining_time_in_millis(),
            "region": os.environ.get("AWS_REGION"),
            "memory_mb": context.memory_limit_in_mb,
        },
        "server_time_unix": int(time.time()),
    }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(response),
    }
