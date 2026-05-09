"""Audit consumer — pulls click_audit messages from SQS and inserts
into the click_audit table in Postgres.

Triggered by AWS Lambda event source mapping on the lambda-hw-hello-
click-audit SQS queue. AWS hands us a batch of up to 10 messages per
invocation (D6.5).

Design properties (decision doc 0006):
  - Append-only: this user has only INSERT and SELECT, no UPDATE/DELETE
  - Idempotent: ON CONFLICT (request_id) DO NOTHING swallows duplicate
    deliveries that SQS at-least-once semantics permit
  - Per-message failure handling: returns batchItemFailures so AWS only
    retries the specific messages that failed, not the whole batch
  - Module-level cached connection: same Stage-3 Lever-1 pattern as the
    click-handler, ~3-5ms warm DB time after the first cold-start
  - IAM auth: no stored DB password; tokens generated locally per
    container-lifetime
  - Graceful degradation: any per-message exception is logged and the
    message ID returned in batchItemFailures so AWS retries it. After
    maxReceiveCount=5 retries, AWS moves the message to the DLQ.
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
# Module-level config + cached connection
# ---------------------------------------------------------------------------

DB_ENDPOINT = os.environ.get("DB_ENDPOINT", "")
DB_NAME     = os.environ.get("DB_NAME", "lambda_hw")
DB_USER     = os.environ.get("DB_USER", "lambda_hw_audit")
AWS_REGION  = os.environ.get("AWS_REGION", "us-east-1")

_rds_client = boto3.client("rds", region_name=AWS_REGION)

# Cached at module scope (one container = one process = single-threaded
# in Lambda). Same pattern as click-handler.
_db_conn = None


def _generate_db_auth_token() -> str:
    """Local boto3 operation that signs an RDS auth URL with the role's
    IAM credentials. No network call to AWS at this point. The returned
    token serves as the password for the next psycopg.connect."""
    return _rds_client.generate_db_auth_token(
        DBHostname=DB_ENDPOINT,
        Port=5432,
        DBUsername=DB_USER,
        Region=AWS_REGION,
    )


def _get_db_connection() -> "psycopg.Connection":
    """Return a healthy connection. Validates with SELECT 1; reconnects
    on stale. autocommit=True simplifies transaction state management
    across invocations."""
    global _db_conn

    if _db_conn is not None and not _db_conn.closed:
        try:
            with _db_conn.cursor() as cur:
                cur.execute("SELECT 1")
            return _db_conn
        except psycopg.Error:
            try:
                _db_conn.close()
            except Exception:
                pass
            _db_conn = None

    _db_conn = psycopg.connect(
        host=DB_ENDPOINT,
        port=5432,
        dbname=DB_NAME,
        user=DB_USER,
        password=_generate_db_auth_token(),
        sslmode="require",
        autocommit=True,
    )
    return _db_conn


def _insert_audit(record: dict) -> str:
    """Insert one click_audit row. Idempotent: returns 'inserted' for new
    rows, 'duplicate' for ON CONFLICT no-ops. Idempotency key is
    request_id (the producer Lambda's invocation UUID).

    Caller is expected to have all five fields in record. Missing fields
    raise KeyError, which the handler catches and reports as a per-
    message failure.
    """
    conn = _get_db_connection()
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO click_audit
                (request_id, sub, username, clicked_at, source)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (request_id) DO NOTHING
            """,
            (
                record["request_id"],
                record["sub"],
                record["username"],
                record["clicked_at"],
                record["source"],
            ),
        )
        # rowcount=1 → row was inserted; rowcount=0 → ON CONFLICT no-op
        return "inserted" if cur.rowcount == 1 else "duplicate"


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event, context):
    records = event.get("Records", [])
    failures = []

    t0 = time.perf_counter()

    for r in records:
        message_id = r.get("messageId")
        try:
            body = json.loads(r.get("body", "{}"))
            result = _insert_audit(body)
            logger.info(
                "audit_inserted",
                extra={
                    "event":      "audit_inserted",
                    "message_id": message_id,
                    "request_id": body.get("request_id"),
                    "sub":        body.get("sub"),
                    "username":   body.get("username"),
                    "source":     body.get("source"),
                    "result":     result,  # "inserted" or "duplicate"
                },
            )
        except Exception as e:
            # Log + record the failed message ID so AWS retries only this
            # message, not the whole batch. After maxReceiveCount=5
            # retries, the message moves to the DLQ.
            logger.exception(
                "audit_insert_failed",
                extra={
                    "event":         "audit_insert_failed",
                    "message_id":    message_id,
                    "error_type":    type(e).__name__,
                    "error_message": str(e),
                },
            )
            failures.append({"itemIdentifier": message_id})

    elapsed_ms = int((time.perf_counter() - t0) * 1000)
    logger.info(
        "batch_complete",
        extra={
            "event":         "batch_complete",
            "record_count":  len(records),
            "failure_count": len(failures),
            "elapsed_ms":    elapsed_ms,
        },
    )

    # AWS uses this response to decide which messages to delete and
    # which to return to the queue for retry. Empty list = all
    # successful, all get deleted.
    return {"batchItemFailures": failures}
