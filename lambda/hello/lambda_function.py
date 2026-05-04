"""lambda-hw — hello-world Lambda serving two front doors, with a
per-user click counter (Stage 3).

Stage 1 path: invoked via Function URL with AWS_IAM auth. The Flask app
on EC2 SigV4-signs a POST and includes the user identity in the body.
Identity carried as `username` and `display_name` only — no stable
identifier (`sub`), so this path SKIPS the database. The greeting is
returned without a counter.

Stage 2 path: invoked via API Gateway HTTP API with a JWT authorizer.
API Gateway has already validated the JWT and attached claims to
event.requestContext.authorizer.jwt.claims. Identity includes `sub`
(stable Cognito UUID), so this path DOES update the database — upserts
into user_visits, increments the click count, and returns the count
and first/last-seen timestamps.

Database access uses IAM auth: the Lambda's execution role generates a
short-lived auth token via boto3 (locally — no AWS API call), presents
it to RDS Proxy as the password. No stored DB credentials anywhere.

When the database is unreachable for any reason (network, proxy
maintenance, schema mismatch), the Lambda degrades gracefully —
returns the greeting without `visit` data and logs the error to
CloudWatch. The core "say hello" feature stays alive.

Stage 4 logging: when the function's logging_config.log_format is JSON,
each logger.info(..., extra={...}) call emits a structured log event
with the extras at top level alongside built-in fields like requestId.
"""

import json
import logging
import os
import time

import boto3
import psycopg


logger = logging.getLogger()
logger.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Module-level config and clients
# ---------------------------------------------------------------------------
# These are constructed once per Lambda container. Across warm invocations
# the same Python process handles requests, so caching here amortizes the
# init cost. boto3 client is lightweight to create but not free; pulling
# it out here matters at scale.

DB_ENDPOINT = os.environ.get("DB_ENDPOINT", "")
DB_NAME     = os.environ.get("DB_NAME", "lambda_hw")
DB_USER     = os.environ.get("DB_USER", "lambda_hw_app")
AWS_REGION  = os.environ.get("AWS_REGION", "us-east-1")

_rds_client = boto3.client("rds", region_name=AWS_REGION)


# ---------------------------------------------------------------------------
# Identity extraction (unchanged from Stage 2)
# ---------------------------------------------------------------------------

def _extract_identity(event: dict) -> tuple[str, dict]:
    """Return (invocation_path, identity_dict).

    invocation_path: "api-gateway-jwt" or "function-url-iam".
    identity_dict:   {sub, username, display_name, role}, with None
                     for fields not available on a given path. Stage 3
                     uses sub to decide whether to hit the database.
    """
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


# ---------------------------------------------------------------------------
# Database access — IAM auth + connection-per-invocation upsert
# ---------------------------------------------------------------------------

def _generate_db_auth_token() -> str:
    """Return a 15-minute IAM auth token for connecting to RDS as DB_USER.

    This is a LOCAL operation, despite looking like a boto3 RPC. boto3's
    `generate_db_auth_token` signs a URL with the role's credentials
    (loaded from Lambda's credential cache) and returns the signed string.
    No network call; very fast (~1ms).

    The returned token is the password for the next psycopg.connect call.
    RDS validates the signature against IAM at connection time.
    """
    return _rds_client.generate_db_auth_token(
        DBHostname=DB_ENDPOINT,
        Port=5432,
        DBUsername=DB_USER,
        Region=AWS_REGION,
    )


def _connect_db() -> "psycopg.Connection":
    """Open a fresh psycopg connection. Caller is responsible for closing
    (typically via `with _connect_db() as conn:` block).

    `sslmode="require"` is mandatory for IAM-auth users — RDS rejects
    plain TCP connections from rds_iam-membered users.
    """
    return psycopg.connect(
        host=DB_ENDPOINT,
        port=5432,
        dbname=DB_NAME,
        user=DB_USER,
        password=_generate_db_auth_token(),
        sslmode="require",
    )


def _upsert_visit(sub: str, username: str) -> dict:
    """Increment (or first-create) the user_visits row for this user.

    The single SQL statement is atomic: no race between "check exists"
    and "insert/update". Two concurrent invocations for the same user
    would be linearized by the primary key constraint on `sub`.

    Returns dict with click_count, first_seen, last_seen, db_elapsed_ms.
    """
    t0 = time.perf_counter()
    with _connect_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO user_visits (sub, username, click_count, first_seen, last_seen)
                VALUES (%s, %s, 1, now(), now())
                ON CONFLICT (sub) DO UPDATE
                  SET click_count = user_visits.click_count + 1,
                      username    = EXCLUDED.username,
                      last_seen   = now()
                RETURNING click_count, first_seen, last_seen
                """,
                (sub, username),
            )
            click_count, first_seen, last_seen = cur.fetchone()
        # `with conn:` commits on success and closes the connection here.

    return {
        "click_count":    click_count,
        "first_seen":     first_seen.isoformat(),
        "last_seen":      last_seen.isoformat(),
        "db_elapsed_ms":  int((time.perf_counter() - t0) * 1000),
    }


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event, context):
    t0 = time.perf_counter()

    invocation_path, ident = _extract_identity(event)
    display_name = ident["display_name"] or "stranger"

    # Update the click counter only when we have a stable user identifier.
    # The Function URL path (Flask server-proxy) doesn't carry one. If the
    # DB call fails for any reason, log + continue so the greeting still
    # works — the click counter is a feature, not a hard dependency.
    visit_data = None
    if ident["sub"]:
        try:
            visit_data = _upsert_visit(ident["sub"], ident["username"])
        except Exception as e:
            logger.exception(
                "db_upsert_failed",
                extra={
                    "event":         "db_error",
                    "error_type":    type(e).__name__,
                    "error_message": str(e),
                    "username":      ident["username"],
                },
            )

    response = {
        "greeting": f"hello, {display_name}",
        "invocation_path": invocation_path,
        "received_identity": ident,
        "stage": 3,
        "lambda": {
            "function_name": context.function_name,
            "request_id":    context.aws_request_id,
            "remaining_ms":  context.get_remaining_time_in_millis(),
            "region":        AWS_REGION,
            "memory_mb":     context.memory_limit_in_mb,
        },
        "server_time_unix": int(time.time()),
    }
    if visit_data is not None:
        response["visit"] = visit_data

    out = {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(response),
    }

    # One structured log event per invocation. New fields versus Stage 2:
    #   - db_visited: bool, whether the upsert was attempted-and-succeeded
    #   - click_count: count after upsert, or null
    latency_ms = int((time.perf_counter() - t0) * 1000)
    logger.info(
        "invocation",
        extra={
            "event":           "invocation",
            "invocation_path": invocation_path,
            "username":        ident["username"],
            "display_name":    ident["display_name"],
            "latency_ms":      latency_ms,
            "db_visited":      visit_data is not None,
            "click_count":     visit_data["click_count"] if visit_data else None,
            "status":          out["statusCode"],
        },
    )

    return out
