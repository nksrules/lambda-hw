"""lambda-hw — learning project for AWS Lambda behind the Sastry Apps gateway.

Stage 0: Flask shim only. No Lambda calls yet. The shim's job is to:
  - Serve the HTML page (templates/index.html) at /app/lambda-hw/
  - Read X-User-* headers passed by the gateway
  - Provide /health for systemd

Later stages will add routes that call AWS Lambda. The shim itself stays small.
"""

import logging
import os

from flask import Flask, render_template, request

app = Flask(__name__)
log = logging.getLogger(__name__)

STANDALONE = os.environ.get("STANDALONE", "").lower() in ("1", "true", "yes")


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


@app.route("/")
def index():
    user = get_user()
    log.info("lambda-hw index viewed by %s", user["username"])
    return render_template("index.html", user=user, standalone=STANDALONE, stage=0)


@app.route("/health")
def health():
    return "ok"


if __name__ == "__main__":
    STANDALONE = True
    app.run(debug=True, port=5050)
