# Stage 1 — Server-proxy hello-world Lambda

**Goal:** One Lambda function returning a hello-world payload, called from the
Flask app on EC2 using SigV4-signed requests. No browser-direct calls yet, no
API Gateway yet. Pure server-to-server.

```
Browser ─► nginx ─► Flask /api/hello ─(SigV4)─► Lambda Function URL ─► Lambda ─► JSON
```

## Decisions

### D1.1 — Lambda Function URL (not API Gateway) for Stage 1

A **Function URL** is a built-in HTTPS endpoint AWS attaches directly to a
Lambda function. One terraform resource, one DNS name, no separate gateway
service to configure.

**Why this for Stage 1:** the goal is to learn the Lambda + IAM + SigV4 +
boto3 + terraform loop without API Gateway as a confounding variable.
Function URLs were introduced in 2022 specifically to remove the "do I really
need API Gateway just to call my Lambda over HTTPS?" friction.

**Tradeoff:** Function URLs don't have request transformation, usage plans,
caching, multi-stage deployments, custom domains (without CloudFront), or
JWT authorizers. We'll feel the absence of the JWT authorizer in Stage 2 —
that's exactly the moment we add API Gateway.

### D1.2 — `AuthType = AWS_IAM` (not `NONE`)

`AWS_IAM` means: every request must carry a valid SigV4 signature, AND the
signing IAM identity must hold `lambda:InvokeFunctionUrl` permission on this
specific function ARN. `NONE` would make the URL open to the public internet.

**Why this:** auth from day one. The signing identity will be the EC2
instance role (`apps-ec2`), so no static AWS keys live anywhere — credentials
are short-lived and rotated by AWS automatically.

This is **server-identity** auth, not user-identity auth. The Lambda receives
no information about which Sastry Apps user triggered the call unless Flask
explicitly forwards it (which we'll do via a custom header in the body or via
`X-User`-style headers in the signed request).

### D1.3 — EC2 instance profile, not static IAM user keys

Flask gets credentials from `169.254.169.254` (the EC2 metadata service)
automatically via boto3's default credential chain. No `AWS_ACCESS_KEY_ID`
env var, no `~/.aws/credentials` file on the box.

**Why this:** the credentials are temporary (rotated every few hours by AWS),
scoped to exactly what the role allows, and there's no secret to leak in a
backup or git history. This is the AWS-recommended pattern for any code
running on EC2.

### D1.4 — Terraform state in S3, locked natively

State lives in `s3://ksastry-tf-state/lambda-hw/terraform.tfstate`. Locking
uses S3's native conditional-write feature (`use_lockfile = true`,
terraform ≥ 1.10), so no DynamoDB lock table is needed.

**Alternatives:** local state (lost if laptop dies, can't share); S3 + DynamoDB
(older pattern, still common, more moving parts). Native S3 locking is the
modern recommendation as of late 2024.

### D1.5 — Inline ZIP packaging via `archive_file`

Terraform's `data "archive_file"` block zips the `lambda/hello/` directory at
plan time and uploads it as the function payload. No separate build step, no
S3 artifact bucket.

**Why this:** the Lambda has no third-party dependencies (it imports `json`,
`os`, `time` — all stdlib). When we add boto3 *inside* the Lambda in a later
stage, we'll either use a Lambda layer or switch to a build step. Today,
inline is honest and minimal.

### D1.6 — Python 3.12 runtime

The current "long-term" supported Python on Lambda. Python 3.13 also works
but is newer; 3.12 is the safer default. Matters for: stdlib version,
performance, end-of-support timeline.

### D1.7 — Region: `us-east-1`

Matches the gateway's existing AWS resources. Lambda → EC2 calls stay in the
same region (lower latency, no cross-region data transfer charges).

### D1.8 — User identity passed in the request body

Flask reads `X-User` from the gateway, includes the username in the JSON body
of the call to Lambda. Lambda echoes it back as part of the greeting.

**Why not as a signed header:** SigV4 *can* sign custom headers, but the
Lambda Function URL receives them as `event.headers` regardless of whether
they were signed. Putting it in the body is simpler for Stage 1 and makes the
data flow obvious.

**Trust note:** the username is *not* cryptographically bound to the user.
Anything signed by the EC2 instance role is implicitly trusted; if Flask is
compromised it could send any username it wants. This is fine for Stage 1
(only Flask can reach the URL) but it's exactly the gap that JWT closes in
Stage 2 — the JWT will be signed by the auth service and contain the user
identity, and Lambda will be able to verify the user without trusting Flask.

## What we did NOT do (intentionally)

- **No API Gateway.** Stage 2.
- **No JWT.** Stage 2.
- **No CORS on the Function URL.** Browser doesn't call it directly in Stage 1,
  so no CORS preflight to worry about.
- **No CloudWatch dashboards.** Stage 4 covers observability.
- **No VPC for the Lambda.** Default networking. Once we add RDS in Stage 3
  we'll move into a VPC and feel that complexity.

## Open items / future revisits

- **Cold starts.** Stage 1 is too small to feel them, but a fresh container
  spin-up adds ~200–500ms for Python. Worth measuring in Stage 4.
- **Logging.** We'll get default CloudWatch logs for free. Stage 4 makes them
  structured and queryable.
- **Cost.** Free tier covers 1M Lambda requests/mo. We will not approach this.
- **Terraform run as root user.** CloudTrail shows the AWS root user issued
  the API calls during `terraform apply`. AWS strongly recommends never using
  root for routine work. Action item: create a dedicated IAM user (or SSO
  role) with terraform-only permissions, configure it in `~/.aws/credentials`,
  and stop using root.

## Lessons learned (debugging the first deploy)

The first attempt to invoke the Function URL returned 403 AccessDeniedException
for hours despite seemingly correct policies. The actual fixes:

### Lesson 1 — Function URLs require a resource-based policy entry

`aws_lambda_function_url` does NOT automatically grant invoke permission. You
must add `aws_lambda_permission` with `function_url_auth_type = "AWS_IAM"` to
attach a statement to the function's resource policy. Without it: 403, even
when the IAM identity policy on the caller is fully correct, and even though
the IAM simulator reports `allowed` (the simulator only evaluates identity
policies, not resource policies). Counter-intuitive because for direct
`lambda:InvokeFunction` API calls, an identity policy is sufficient in the
same account.

### Lesson 2 — Canonical resource-policy pattern is `Principal: "*"` with auth-type condition

When we initially specified `Principal = arn:aws:iam::ACCT:role/apps-ec2-role`
in the resource policy with the `lambda:FunctionUrlAuthType=AWS_IAM` condition,
we still got 403. Switching to the canonical pattern below resolved it:

```json
{
  "Effect": "Allow",
  "Principal": "*",
  "Action": "lambda:InvokeFunctionUrl",
  "Condition": {"StringEquals": {"lambda:FunctionUrlAuthType": "AWS_IAM"}}
}
```

The IAM identity-based policy on the caller's role still does the actual
restriction. The resource policy just opens the door to "any IAM principal."
This is the form AWS publishes in their docs and it's what we should use by
default. (Whether `Principal: <role-arn>` *should* work and we hit a state
quirk is unclear — `terraform destroy && apply` with the new pattern fixed
it for us, so we didn't isolate further.)

### Lesson 3 — Function URL random IDs change on every recreate

After `terraform destroy && apply`, the Function URL gets a new random ID
(e.g. `ubugzm…` → `qu4l2do5e…`). The `LAMBDA_HELLO_URL` in `/opt/apps/.env`
must be updated and Flask restarted. Any diagnostic scripts that hardcode the
URL must also be updated, or they'll silently hit a non-existent endpoint
that returns its own 403.

### Lesson 4 — Diagnostic value of invoking via different code paths

When `lambda:InvokeFunctionUrl` (URL path) was failing but `lambda:InvokeFunction`
(AWS API path) succeeded, that ruled out function/role/network problems and
narrowed the hunt to the URL-specific authorization layer. Always have a way
to test the same Lambda through a different invocation channel before
assuming the function itself is broken.
