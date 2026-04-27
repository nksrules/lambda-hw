"""lambda-hw — learning project for AWS Lambda behind the Sastry Apps gateway.

Stage 1: Flask shim plus /api/hello, which SigV4-signs a POST to a Lambda
Function URL and returns the response. Credentials come from the EC2 instance
profile (no static keys).
"""

import json
import logging
import os

import boto3
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)
log = logging.getLogger(__name__)

STANDALONE = os.environ.get("STANDALONE", "").lower() in ("1", "true", "yes")
LAMBDA_HELLO_URL = os.environ.get("LAMBDA_HELLO_URL")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# One boto3 session per process. Credentials are looked up lazily through
# boto3's standard chain: env vars → ~/.aws/credentials → instance profile.
_boto_session = boto3.Session()


def get_user():
    """Read user identity from gateway headers, or fake it in standalone mode."""
    if STANDALONE:
        return {
            "user_id": "0",
            "username": "local",
            "display_name": "Local User",
            "role": "admin",
        }
    return {
        "user_id": request.headers.get("X-User-Id"),
        "username": request.headers.get("X-User"),
        "display_name": request.headers.get("X-User-Display"),
        "role": request.headers.get("X-User-Role"),
    }


def call_lambda_hello(username: str, display_name: str) -> dict:
    """SigV4-sign a POST to the hello Lambda Function URL and return its JSON.

    The body is signed *and* sent — SigV4 hashes the body into the signature,
    so what we sign and what we send must be byte-identical.

    We forward BOTH username and display_name. The Lambda only uses
    display_name for the greeting today, but later stages will use username
    as a stable identifier for per-user authorization / data scoping.
    """
    if not LAMBDA_HELLO_URL:
        raise RuntimeError("LAMBDA_HELLO_URL env var is not set")

    body = json.dumps({
        "username": username,
        "display_name": display_name,
    })

    aws_req = AWSRequest(
        method="POST",
        url=LAMBDA_HELLO_URL,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    # "lambda" is the AWS service name in the signing scope.
    SigV4Auth(_boto_session.get_credentials(), "lambda", AWS_REGION).add_auth(aws_req)

    # Send the same bytes we signed; the Authorization header is now populated.
    resp = requests.post(
        LAMBDA_HELLO_URL,
        data=body,
        headers=dict(aws_req.headers),
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


# --- Routes ---


@app.route("/")
def index():
    user = get_user()
    log.info("lambda-hw index viewed by %s", user["username"])
    return render_template("index.html", user=user, standalone=STANDALONE, stage=1)


@app.route("/api/hello")
def api_hello():
    """Round-trip a request through the Lambda Function URL."""
    user = get_user()
    try:
        result = call_lambda_hello(user["username"], user["display_name"])
        log.info("lambda hello round-tripped for %s", user["username"])
        return jsonify(result)
    except Exception as e:
        log.exception("Lambda call failed")
        return jsonify({"error": str(e), "type": type(e).__name__}), 500


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    STANDALONE = True
    app.run(debug=True, port=5050)
