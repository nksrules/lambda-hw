# Stage 3 — Add per-user state via the shared data platform

**Goal:** Make the Lambda *stateful* — give it a per-user click counter
backed by Postgres. The feature is intentionally trivial; the
architecture work is the point. By the end of Stage 3, lambda-hw is
the first tenant of the gateway's shared data platform, and the
patterns we establish here become the template for every future
DB-backed app behind this gateway.

**Read first:** [`~/gateway/docs/decisions/0001-data-platform.md`](../../../gateway/docs/decisions/0001-data-platform.md).
That doc describes the platform infrastructure (VPC, RDS, optional
RDS Proxy, master credentials, security group hierarchy) that this
stage *consumes*. The decisions in *this* doc are about what
lambda-hw, as a tenant, builds on top of that.

## What's tenant-owned vs platform-owned

The split, summarized (full version in the gateway doc):

| Concern | Lives in | Notes |
|---|---|---|
| VPC, subnets, security group base hierarchy | gateway/data-platform | Shared by all tenants |
| RDS instance, RDS Proxy (optional) | gateway/data-platform | One physical Postgres, many logical databases |
| Lambda code + Lambda execution role | **lambda-hw/terraform** | Per-app |
| App's database (`lambda_hw`) + Postgres user (`lambda_hw_app`) | **lambda-hw/migrations/** SQL | Created via SQL, not terraform |
| App's security group + tenant-db-client SG attachment | **lambda-hw/terraform** | Per-app |
| `rds-db:connect` IAM permission scoped to `lambda_hw_app` | **lambda-hw/terraform** | Per-app |
| psycopg Lambda layer | **lambda-hw/terraform** | App's choice; could share later |

Lambda-hw never directly references RDS infrastructure resources —
it consumes them through the platform's published outputs (DB endpoint,
VPC ID, subnet IDs, security group IDs).

## Architecture

```
   API Gateway / Function URL                                     ┌─ default VPC vpc-807652fa, 172.31.0.0/16 ───┐
            │                                                     │                                              │
            ▼                                                     │   Existing public subnets (slim, apps EC2s) │
        Lambda (lambda-hw-hello)                                  │     us-east-1b: 172.31.16.0/20             │
            │ attached to private subnets via VPC config         │                                              │
            │ uses tenant-db-client marker SG                    │   ── data-platform private subnets ──        │
            │                                                    │     us-east-1a: 172.31.96.0/24              │
            │ at runtime:                                        │     us-east-1b: 172.31.97.0/24              │
            │   1. boto3.client("rds").generate_db_auth_token()  │       │                                      │
            │   2. psycopg.connect(host=DB_ENDPOINT, ...)        │       ▼                                      │
            │                                                    │     RDS Proxy (optional) ──► RDS Postgres   │
            ▼                                                    │       (toggleable per platform variable)     │
        ┌─ DB_ENDPOINT ─────────────────────────────────┐        │                                              │
        │ value = either the Proxy endpoint OR          │        └──────────────────────────────────────────────┘
        │   the RDS direct endpoint, depending on       │
        │   platform's enable_rds_proxy variable.       │
        │ Lambda is unaware which.                      │
        └────────────────────────────────────────────────┘

         Postgres-side, after migration runs from `slim`:
           database lambda_hw    (created, owned by lambda_hw_app)
             ├── user_visits     (the only table in Stage 3)
             └── (future tables added by future migrations)
           user lambda_hw_app    (granted rds_iam, granted on lambda_hw)
```

## Decisions

### D3.1 — App database `lambda_hw`, app user `lambda_hw_app` with `rds_iam`

Inside the shared RDS instance, lambda-hw gets its own logical
Postgres database (`lambda_hw`) and its own Postgres user
(`lambda_hw_app`). Created via SQL migration, not terraform — see
D3.6.

**Why a separate database (not just a separate schema):** Postgres
isolates databases harder than schemas. A user can be granted
permissions only on its own database, and `\connect` (or the JDBC
URL) selects which database to operate against. With one shared
database and per-tenant schemas, we'd be one `GRANT` typo away from
cross-tenant access. Different databases are also a hard wall against
"app A's transactions affect app B's lock contention."

**Why a dedicated Postgres user, not the master:** least privilege.
The master account is for DDL only, used from the bastion. Tenant
Lambdas authenticate as `lambda_hw_app`, which has CONNECT on
`lambda_hw` and CRUD on its tables — nothing else. Compromise of
the Lambda role can't read other apps' data.

**Why `rds_iam` and not a stored password:** see GW.5 in the
gateway doc. Tokens generated locally per-request, no credential to
rotate, no Secrets Manager call needed.

### D3.2 — Lambda execution role gains `rds-db:connect` scoped to `lambda_hw_app`

The IAM policy attached to `lambda-hw-hello-exec` adds:

```hcl
{
  Effect = "Allow"
  Action = "rds-db:connect"
  Resource = "arn:aws:rds-db:us-east-1:<account>:dbuser:<rds-resource-id>/lambda_hw_app"
}
```

The `<rds-resource-id>` is the RDS instance's resource ID (different
from the instance ID; AWS-internal). It comes from the platform's
terraform output (`data_platform.rds_resource_id`).

**This permission is precisely scoped:** "this role can authenticate
to the database as user `lambda_hw_app` and only that user." Even if
the role were misused or compromised, it can't authenticate as
master or as another tenant's user.

### D3.3 — Lambda VPC config: data-platform private subnets, tenant SG with marker

The Lambda's terraform gains:

```hcl
data "aws_subnet" "private_a" {
  filter {
    name   = "tag:Name"
    values = ["data-platform-private-1a"]
  }
}
data "aws_subnet" "private_b" {
  filter {
    name   = "tag:Name"
    values = ["data-platform-private-1b"]
  }
}
data "aws_security_group" "tenant_db_client" {
  filter {
    name   = "tag:Name"
    values = ["tenant-db-client"]
  }
}

resource "aws_security_group" "lambda_hw_lambda" {
  name   = "lambda-hw-lambda-sg"
  vpc_id = "vpc-807652fa"
  # No inbound rules — Lambda doesn't accept connections.
  # Outbound: only to the tenant-db-client marker SG (transitively to RDS Proxy).
}

resource "aws_lambda_function" "hello" {
  # ...existing config...
  vpc_config {
    subnet_ids         = [data.aws_subnet.private_a.id, data.aws_subnet.private_b.id]
    security_group_ids = [aws_security_group.lambda_hw_lambda.id, data.aws_security_group.tenant_db_client.id]
  }
}
```

The Lambda gets *two* SGs: its own (for outbound rules) and the
marker `tenant-db-client` (which is what the platform's RDS-side SGs
allow ingress from). Attaching the marker SG is the admission step —
without it, the Lambda can't reach RDS.

**Cold-start impact of VPC config:** post-2019, Lambda+VPC cold
starts are roughly comparable to non-VPC. Initial ENI creation is
amortized across the function's lifetime. Expect ~50ms extra cold
start, ~0ms warm.

### D3.4 — psycopg layer, arm64

Postgres driver `psycopg[binary]` (Psycopg 3 with statically-linked
libpq) distributed as a Lambda layer.

**Why a layer (vs bundling into function ZIP):**

- **Reuse.** Stage 6's queue-consumer Lambda will use the same
  driver. One build, two Lambdas.
- **Separation.** Function code changes weekly; psycopg version
  changes annually. Different update cadences → different artifacts.
- **Cleaner ZIP.** Lambda function ZIP stays small (just our handler
  code), faster to upload during iteration.

**Architecture: arm64 / Graviton.** This is a flip from the previous
implicit x86_64 default. Reasons:

1. ~20% cheaper Lambda compute. Tiny savings at our scale, but the
   "modern AWS default" alignment is worth the small change.
2. Consistency with the DB (`db.t4g.micro` is also Graviton).
3. PyPI ships `manylinux2014_aarch64` wheels for `psycopg[binary]`,
   so no Docker rebuild needed.

**Build approach:** a `null_resource` provisioner runs
`pip install --platform manylinux2014_aarch64 ...` against the
layer's `requirements.txt`, fetching pre-built wheels into a
`build/python/` dir. An `archive_file` zips that directory.
Re-runs whenever `requirements.txt` changes. No Docker.

**Cold-start impact:** ~50ms extra to unpack the layer. We're
already ~500ms cold; not significant.

### D3.5 — Connection lifecycle: per-invocation, IAM token, idempotent upsert

```python
import boto3, psycopg

# Module-level: cheap to construct, used per invocation.
_rds_client = boto3.client("rds")

def get_db_connection():
    """Open a fresh connection on each invocation. The Proxy (when
    enabled) holds the actual pool; we just attach. When Proxy is
    disabled, this hits RDS directly — slower but functionally same."""
    token = _rds_client.generate_db_auth_token(
        DBHostname=DB_ENDPOINT,
        Port=5432,
        DBUsername="lambda_hw_app",
        Region="us-east-1",
    )
    return psycopg.connect(
        host=DB_ENDPOINT,
        port=5432,
        dbname="lambda_hw",
        user="lambda_hw_app",
        password=token,                                # the IAM auth token
        sslmode="require",
    )

def handler(event, context):
    # ...existing identity extraction...

    with get_db_connection() as conn:
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
                (ident["sub"], ident["username"]),
            )
            click_count, first_seen, last_seen = cur.fetchone()
        conn.commit()

    response = {
        # ...existing fields...
        "click_count": click_count,
        "first_seen": first_seen.isoformat(),
        "last_seen":  last_seen.isoformat(),
    }
```

**Why open a connection per invocation, not cache at module level:**

- Simplest mental model; matches how Lambda containers freeze and
  thaw.
- Connection setup against RDS Proxy is fast (~5-10ms) because the
  Proxy holds the actual long-lived pool to RDS.
- Cached connections can go stale during container freeze; handling
  reconnect logic would be more code than it's worth for the click
  counter.

**Optimization for later:** module-level cached connection with
"validate on use, reconnect on failure" pattern. Worth ~10ms warm-call
latency. Defer until we have a Lambda where that matters.

**Why one Lambda call = one upsert:** idempotent. The `ON CONFLICT`
clause means the same row is updated if the user has been seen,
inserted if not. No race between "check if exists" and "insert" —
the database handles atomicity.

**Why not `sub` column NULL-able:** the Function URL path doesn't
have `sub` (D3 of stage 1; only the JWT path does). Two options:

1. (Chosen) Make `sub` the primary key, only the API Gateway path
   writes to user_visits. The Function URL path returns the greeting
   without DB interaction.
2. Use `username` as primary key. Allows both paths to write.

Going with (1). It demonstrates the better pattern (use the stable
sub, not the mutable username) and is the path users actually go
through in real use. The Function URL path is a learning artifact;
not worth complicating the schema for.

### D3.6 — Schema management: SQL files, applied manually from `slim`

Migrations live in `lambda-hw/migrations/`:

```
migrations/
└── 0001_user_visits.sql     # initial schema for stage 3
```

Each file is idempotent (`CREATE TABLE IF NOT EXISTS`, etc.), self-
contained, and applied in order.

**The first migration creates everything lambda-hw needs in Postgres:**

```sql
-- Run as master user from the bastion
CREATE DATABASE lambda_hw;
\connect lambda_hw

CREATE USER lambda_hw_app;
GRANT rds_iam TO lambda_hw_app;
GRANT CONNECT ON DATABASE lambda_hw TO lambda_hw_app;
GRANT USAGE ON SCHEMA public TO lambda_hw_app;

CREATE TABLE IF NOT EXISTS user_visits (
    sub          TEXT PRIMARY KEY,
    username     TEXT NOT NULL,
    click_count  INTEGER NOT NULL DEFAULT 0,
    first_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen    TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT, UPDATE, DELETE ON user_visits TO lambda_hw_app;
```

**How we run psql against the private RDS:** SSH to `slim`, then
`psql -h <db-endpoint>`. `slim` is in the same VPC; the platform's
RDS-side SG will be configured (in gateway/data-platform) to allow
ingress on 5432 from `slim`'s security group. The master password
comes from Secrets Manager via a one-time fetch.

**No automated migration tooling.** Each new migration is a manual
`psql < migrations/000N_*.sql`. At this scale and team size, the
visibility is worth more than the automation. When schema churn
starts to hurt, switch to Alembic or sqitch.

### D3.7 — `DB_ENDPOINT` flows from platform terraform → /opt/apps/.env → Lambda env

The platform's terraform exposes a `db_endpoint` output (resolves to
Proxy endpoint or direct RDS endpoint depending on
`enable_rds_proxy`). After applying platform terraform:

```bash
DB_ENDPOINT=$(cd ~/gateway/terraform/data-platform && terraform output -raw db_endpoint)
ssh ec2-user@apps.ksastry.com "echo 'DB_ENDPOINT=$DB_ENDPOINT' | sudo tee -a /opt/apps/.env"
ssh ec2-user@apps.ksastry.com "sudo systemctl restart app-lambda-hw"
```

(The Lambda terraform reads the env var into the function via
`environment.variables.DB_ENDPOINT = <data source>` — actually, since
this is Lambda not Flask, it'd be set on the function directly via
terraform. For lambda-hw the relevant approach is: the lambda-hw
terraform has a `data "terraform_remote_state" "data_platform"` block
that reads the platform's state and pipes the endpoint into the Lambda
function's environment variables.)

**Why remote-state data source vs hardcoded string:** if you toggle
the Proxy on/off in platform terraform, the endpoint changes. With
the remote-state data source, the next `terraform apply` in lambda-hw
picks it up automatically. Without it, you'd have to manually update
a hardcoded string somewhere — fragile.

## What we did NOT do (intentionally)

- **No connection pooling at the Lambda level.** RDS Proxy plays
  that role when enabled. When not enabled, the workload is small
  enough that direct connections per invocation work.
- **No module-level connection caching.** Per-invocation. Defer
  until performance warrants.
- **No prepared statement caching.** Per-invocation. Defer.
- **No automated migration framework.** Plain SQL applied manually.
- **No bastion host of our own.** Use existing `slim`.
- **No Secrets Manager use from the Lambda.** IAM auth replaces
  it; no need.
- **No CloudWatch alarms specific to DB ops yet.** Stage 4 has
  Lambda-level alarms; DB-level alarms (slow queries, connection
  exhaustion) are deferred to future revisits if/when meaningful.
- **No row-level security.** App user has full access to its
  database; the security boundary is at the *user* level (lambda_hw_app
  vs other_app_app), not row level.

## Open items / future revisits

- **Disable RDS Proxy when learning is done.** Set
  `enable_rds_proxy = false` in gateway/data-platform/terraform.tfvars
  and apply. Save ~$22/mo. The pattern stays in code; flip back
  whenever traffic justifies it.
- **Module-level connection caching** if cold-start latency on the
  DB-call path becomes a measurable concern.
- **Migration automation** (Alembic/sqitch) when schema churn
  justifies it.
- **DB-level CloudWatch alarms** (slow queries, connection count,
  free storage) when there's enough activity to make them
  informative.
- **Read replica** if the read workload becomes interesting.
- **Customer-managed KMS key for RDS encryption** for compliance.
- **Multi-region failover** strategy.
- **VPC endpoints for AWS service public APIs** if any future
  Lambda needs to call them from inside the private subnets
  (Secrets Manager, S3, etc.). Currently zero such calls.

## Lessons carried forward

- **Decision docs evolve.** This doc was rewritten mid-stage when
  we realized VPC/RDS/Proxy belong in the gateway, not lambda-hw.
  The rewrite cost was small; the cost of getting it wrong and
  living with per-app VPCs forever would have been large.
- **Cross-repo platform-vs-tenant split is reusable.** Same shape
  as Stage 2's auth-service work. Worth turning into a written
  pattern for future apps that consume gateway services.
- **Manage the cost knob explicitly.** RDS Proxy at $22/mo crossed
  our threshold of "real money." Making it a terraform variable
  with `default = false` and turning it on for a learning week
  rather than indefinitely is the right pattern for any expensive
  optional infrastructure.
- **AWS service quirks aren't always documented.** Stage 1 taught
  resource policies; Stage 2 OIDC discovery + ES256; Stage 4
  retention granularity. Stage 3 had its own — see "Lessons learned"
  below.
- **Run terraform as a non-root IAM identity.** Still an open item.
  This is the right stage to finally fix it before we add another
  terraform project.

## Lessons learned (debugging Stage 3 deploys)

### Lesson 1 — RDS Proxy requires per-Postgres-user Secrets Manager auth blocks (even with IAM)

We initially provisioned RDS Proxy thinking IAM auth on the front side
would be enough. It's not. Symptom:

```
FATAL: This RDS proxy has no credentials for the role lambda_hw_app.
```

The Proxy's auth model: clients authenticate to the Proxy with IAM
tokens, but the Proxy needs **its own way** to authenticate to RDS to
maintain the connection pool. That requires a Secrets Manager secret
with stored Postgres credentials, plus an `auth` block on
`aws_db_proxy` referencing it. **Per Postgres user.** Even when
`iam_auth = "REQUIRED"`.

This means adding a tenant Postgres user with Proxy support is
genuinely 3 coordinated changes:

1. `ALTER USER X WITH PASSWORD '<random>'` in Postgres (give the user
   an actual stored password, even though we still want IAM auth on
   the Proxy front side)
2. Create a Secrets Manager secret with that username + password
3. Add a second `auth` block on `aws_db_proxy` referencing the secret

We hit this, decided the Proxy wasn't worth the per-tenant operational
complexity at our scale, and toggled it off. The pattern remains in
code (`var.enable_rds_proxy`) for future re-enable when justified.

**Implication for the decision doc:** RDS Proxy is "right" only when
you have enough concurrency that connection exhaustion is a real risk
*and* the operational cost of maintaining auth blocks per tenant is
absorbed. For ~handful-of-requests-per-day workloads, direct RDS +
connection caching wins.

### Lesson 2 — Cross-project terraform changes don't auto-cascade

When `gateway/terraform/data-platform/` flipped `enable_rds_proxy` from
`true` to `false`, the platform's `db_endpoint` output changed
(Proxy → direct RDS). lambda-hw's terraform reads that via
`terraform_remote_state` data source, but **the change doesn't
propagate to AWS until you explicitly `terraform apply` lambda-hw**.
The Lambda's environment variable kept pointing at the dead Proxy
hostname, with predictable failure.

**Pattern to internalize:** any time gateway/data-platform terraform
changes outputs that lambda-hw consumes, lambda-hw must re-apply.
This is the pull model — tenants pull from platform state on demand,
not pushed at them. CI pipelines automate it; manual workflows need
discipline.

### Lesson 3 — Lambda env var changes don't update warm containers

After `terraform apply` updates a function's env vars, the new values
take effect on **new container starts** — but warm containers
already running may continue with the old values until they shut down
(can be 10-15 min). For our case the proxy hostname change manifested
as confusing intermittency: some invocations failed with stale env,
others succeeded as new containers came online.

**Mental model:** Lambda env vars are baked into the container at
launch, not refreshed mid-life. If you need an instant cycle, force
new containers via `aws lambda update-function-code` or by changing
some other config attribute that triggers replacement.

### Lesson 4 — psycopg arm64 wheels work first-try with `pip --platform`

This one was actually a positive surprise. We worried Docker would be
needed to build psycopg for Lambda's arm64 Linux. PyPI's
`manylinux2014_aarch64` wheels for `psycopg-binary` worked perfectly
with:

```bash
pip install --platform manylinux2014_aarch64 \
    --target build/python --implementation cp --python-version 3.12 \
    --only-binary=:all: --upgrade psycopg[binary]
```

No Docker, no toolchain, layer ZIP came out clean. The terraform
`null_resource` provisioner for it is ~10 lines.

The recipe generalizes for other Python packages with C extensions
(numpy, cryptography, pillow): if PyPI has manylinux wheels for arm64,
this approach works. Falls down only when wheels aren't available
(less common than it used to be).

### Lesson 5 — Connection per invocation is slow; cache at module scope

Our D3.5 chose "connection per invocation" for simplicity. In practice
this costs ~150-200ms per warm invocation (TLS handshake + IAM token
validation + Postgres protocol auth). The actual SQL upsert is
microseconds.

Module-level caching with `try { ping } catch { reconnect }` recovers
most of that latency at the cost of ~10 lines of code and slightly
more careful lifecycle handling. Worth doing when latency starts to
matter; we're shipping the simpler pattern first as a baseline.

Performance breakdown in our actual measurements (warm, post-
deploy):
- API Gateway → Lambda routing + JWT validate: ~10ms
- Lambda invoke + handler: ~5ms
- DB connection setup: ~150-200ms
- SQL upsert itself: ~5ms
- Network round-trip (browser ↔ AWS): ~50ms
- Total: ~250-350ms

With module-level connection caching, total drops to ~100-150ms.
With DynamoDB (different access pattern, no connection model),
~50-80ms is realistic.
