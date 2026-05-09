# Stage 6 — Asynchronous queuing with SQS

**Goal:** Demonstrate the producer/consumer / async pattern that
underpins most "do work later" features in real systems. Add a
durable, decoupled audit log of clicks: every click triggers an SQS
message; a separate consumer Lambda picks it up and writes a permanent
audit record to a separate table. User-facing latency unchanged.

```
                                                ┌─► RDS user_visits
                                                │   (Stage 3 — sync,
                                                │    in user's request path)
   Browser ──► API Gateway ──► click-handler ───┤
                                  Lambda        │
                                                │
                                                └─► SQS click-audit-queue
                                                         │
                                                         │ (Lambda event
                                                         │  source mapping)
                                                         ▼
                                                audit-consumer Lambda
                                                         │
                                                         ▼
                                                RDS click_audit
                                                (Stage 6 — async)
                                                         │
                                                         └─► DLQ on
                                                             repeated
                                                             failure
```

The user-facing call returns immediately after the upsert + SQS-send
(both fast). The audit-consumer runs whenever AWS hands it a batch of
messages — usually within seconds of the click.

## What this stage adds, conceptually

- **At-least-once delivery semantics** — SQS may deliver a message
  twice; the consumer must be idempotent.
- **Visibility timeout** — when the consumer pulls a message, it
  becomes invisible to other consumers for a configurable window. If
  the consumer succeeds, it deletes the message; if not, it becomes
  visible again after the timeout (next consumer retries).
- **Dead-letter queue (DLQ)** — after N failed deliveries, the
  message moves to a separate queue for inspection. Stops infinite
  retry loops.
- **Lambda event source mapping** — AWS auto-polls SQS and triggers
  Lambda with a batch of messages. Lambda runtime gets `event.Records[]`
  with each message; we never write polling code.
- **Producer/consumer decoupling** — the producer doesn't know if the
  consumer is healthy. Messages persist in the queue regardless.

## Decisions

### D6.1 — Standard SQS queue (not FIFO)

| | Standard | FIFO |
|---|---|---|
| Delivery | at-least-once | exactly-once with dedupe ID |
| Order | best-effort, mostly in order | strict per group |
| Throughput | nearly unlimited | 300 msgs/s, 3000/s batched |
| Cost | $0.40/M | $0.50/M |

**Choice: Standard.** For audit logs we tolerate occasional duplicate
delivery (consumer dedupes by `request_id`), strict ordering doesn't
matter (audit records are independently meaningful), and the higher
throughput ceiling means we don't have to think about throughput
later. FIFO is the right answer when you have ordered transactions
(e.g., bank ledger), not for our case.

### D6.2 — Visibility timeout 30s, retention 14 days, long-poll wait 20s

- **`visibility_timeout_seconds = 30`** — generous; audit insert
  takes <100ms, but allows for cold starts + retries on transient
  errors. Must be greater than max consumer processing time + safety
  margin.
- **`message_retention_seconds = 1209600` (14 days)** — maximum AWS
  allows. For audit, 14 days lets us debug any incident within a
  reasonable investigation window. Default is 4 days; we extend
  because audit data has more value if recoverable.
- **`receive_wait_time_seconds = 20`** — long polling at the maximum.
  Reduces empty-receive cost and improves consumer latency vs short
  polling (which would return immediately even with no messages).

### D6.3 — Dead-letter queue, max receives 5, 14-day retention

After 5 failed deliveries (consumer raised an exception, timed out, or
returned a partial batch failure), the message moves to a separate
DLQ for human inspection. Five is a reasonable default — allows for
transient blips (network, brief deploy interruption) without giving
up on the message too eagerly.

DLQ retention also 14 days.

The DLQ is the operational signal of "something is consistently
broken in the consumer." Messages there indicate either a bug in the
consumer code, a permanent data problem, or a permanently broken
downstream dependency. Worth alerting on later (deferred to "Open
items").

### D6.4 — Lambda concurrency cap of 5 (max), scales to zero idle

`reserved_concurrent_executions = 5` on the consumer Lambda.

This is a **maximum**, not a minimum. When the queue is empty,
zero containers run. When messages arrive, Lambda spins up containers
on demand, capped at 5 simultaneously.

**Why 5 (not 10 like the click-handler):**

- Audit insert is a smaller, less concurrent workload than user-facing requests.
- Total reserved across both Lambdas: 10 + 5 = 15. Account unreserved pool stays at 985 (out of 1000 default). Plenty of headroom.
- Smaller cap means less risk of audit-side bug overwhelming the database.

**What this is NOT:** provisioned concurrency. That's the paid
feature for keeping containers always-warm; we don't use it. Cold
starts on the audit consumer are fine — async path, user doesn't see
them.

### D6.5 — Event source mapping: batch=10, window=5s

When AWS pulls messages from SQS to feed Lambda:

- **`batch_size = 10`** — up to 10 messages per consumer invocation.
  AWS hands them as `event.Records[]`. Default for SQS event source.
- **`maximum_batching_window_in_seconds = 5`** — wait up to 5 seconds
  collecting messages before invoking, even if batch isn't full. For
  low-volume queues (us, today), this matters: without the window,
  every message would trigger its own invocation. With the window,
  small bursts get batched into a single invocation.

For high-volume queues, `batching_window` rarely matters because
batches fill before the window closes. Setting it doesn't hurt and
helps at low volumes.

**Per-batch failure semantics:** if the consumer raises, **all
messages in the batch are returned to the queue** (visibility timeout
expires, they become visible again). To do per-message failure
handling (where 9/10 messages succeed and 1 fails, only the 1 retries),
the consumer must return a `batchItemFailures` response. We implement
this in chunk E.

### D6.6 — Idempotency via Postgres `ON CONFLICT (request_id) DO NOTHING`

Same pattern as Stage 3's user_visits upsert. Each message has a
`request_id` (the producer's Lambda invocation request ID). The
audit table's primary key is `request_id`. Inserting a duplicate
collides on the PK and the `DO NOTHING` clause silently swallows the
duplicate. No application-level dedup cache, no race conditions.

This works because:
- Producer's request ID is globally unique (UUID-shaped, generated
  by Lambda runtime per invocation).
- Postgres `INSERT ... ON CONFLICT` is atomic.
- Two consumers seeing the same message would both attempt insert;
  one wins, the other no-ops.

**Alternatives considered:**

- DynamoDB / Redis cache for "have I seen this request_id before?"
  Faster than DB roundtrip, but adds infrastructure for a problem
  the DB already solves cleanly.
- SQS FIFO with content-based deduplication. AWS-side dedup with a
  5-minute window. Doesn't help at our scale (FIFO throughput cap)
  and the 5-minute window doesn't cover all edge cases anyway.

### D6.7 — Minimal message payload

```json
{
  "request_id":  "<producer's Lambda request_id>",
  "sub":         "<user's Cognito UUID>",
  "username":    "<email>",
  "clicked_at":  "<ISO8601 timestamp>",
  "source":      "api-gateway-jwt | function-url-iam"
}
```

Five fields, ~250 bytes per message. Well under SQS's 64KB-per-message
included size (above 64KB you pay per extra 64KB chunk).

**Why minimal vs rich:**
- Smaller messages = lower queue cost and faster network
- Forces the consumer to be self-sufficient about what it stores —
  if the audit table needs a field, it goes in this payload, not
  fetched from somewhere else
- The producer doesn't have to anticipate what the consumer will need

If we later want richer data (e.g., the user's role at click time),
we add a field to the payload.

### D6.8 — Producer continues on SQS-send failure (graceful degrade)

If the producer Lambda fails to publish to SQS (transient AWS issue,
IAM blip, throttle), it logs the error and **returns successful
response to the user**. The audit record for that one click is lost.

```python
try:
    sqs.send_message(QueueUrl=..., MessageBody=...)
except Exception as e:
    logger.error("audit_publish_failed", extra={"error": str(e), ...})
    # continue — return to user with the click_count etc.
```

**Why graceful degradation:**
- Audit is supplementary to the user's main flow.
- Failing the user-facing path because of an audit-pipeline blip is
  worse UX than "this one click missed the audit log."
- The CloudWatch log entry preserves enough info to manually
  reconstruct missed audit records if needed.

**Tradeoff:** in regulated environments where audit is legally
mandatory, you'd block on audit completion. Not our case.

Same pattern as Stage 3's "DB upsert fails → return greeting without
counter." Consistent failure-handling philosophy.

### D6.9 — `click_audit` table schema

```sql
CREATE TABLE click_audit (
    request_id    TEXT PRIMARY KEY,
    sub           TEXT NOT NULL,
    username      TEXT NOT NULL,
    clicked_at    TIMESTAMPTZ NOT NULL,
    source        TEXT NOT NULL,
    received_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_click_audit_sub_clicked_at
    ON click_audit (sub, clicked_at DESC);
```

- **`request_id` PK** — idempotency key (D6.6)
- **`clicked_at`** — time the click happened (producer's view)
- **`received_at`** — time the consumer wrote the row (defaults to
  now() at insert). The gap between the two is the queue latency,
  useful for monitoring.
- **Index on (sub, clicked_at DESC)** — for "recent activity by user"
  queries. Probably overkill at our scale but it's the right index
  if we ever want it.

### D6.10 — Separate Postgres user `lambda_hw_audit` for the consumer

Reasons for the separate user:

- **Blast-radius isolation.** If the consumer Lambda is compromised
  or has a bug, the attacker can read/write only `click_audit` —
  not `user_visits` (the source-of-truth click counter).
- **Audit-as-append-only.** The audit user gets only `INSERT` and
  `SELECT` on `click_audit`. No UPDATE, no DELETE. Audit records,
  once written, can't be tampered with by the application code.
- **Separate IAM scope.** Consumer Lambda's IAM role only has
  `rds-db:connect` on `dbuser:.../lambda_hw_audit`, not on
  `dbuser:.../lambda_hw_app`. Even if the IAM role is misused, only
  the audit user is reachable.

The migration creates the user, grants `rds_iam`, grants
`INSERT, SELECT ON click_audit`, no other grants.

The terraform for the consumer's IAM role explicitly scopes
`rds-db:connect` to `dbuser:.../lambda_hw_audit`.

## What we did NOT do (intentionally)

- **No FIFO queue.** Standard with at-least-once is fine for audit.
- **No SNS pub-sub.** SNS is "fanout to many consumers." We have one
  consumer; SQS direct is simpler. SNS would be right if multiple
  apps wanted to hear about clicks.
- **No EventBridge.** Different abstraction (event bus, content-based
  routing). Overkill for one queue with one consumer.
- **No DynamoDB / Redis idempotency cache.** Postgres handles dedup
  natively via primary key + ON CONFLICT.
- **No message encryption at rest with custom KMS key.** Default
  SQS server-side encryption with AWS-managed key is fine.
- **No alarm on DLQ depth yet.** Should add later (a non-empty DLQ
  means messages are stuck). Documented in Open items.
- **No batch-item-failure response in the consumer code.** Will
  add in chunk E — if implemented, partial-batch failures only
  retry the failed messages instead of the whole batch.

## Open items / future revisits

- **DLQ depth alarm.** CloudWatch alarm on
  `AWS/SQS/ApproximateNumberOfMessagesVisible` of the DLQ. Threshold
  ≥1 message → email. Significant signal: "messages are stuck."
- **Audit query interface.** A read-only API or Logs Insights query
  for "show me user X's recent clicks." Not in this stage.
- **Per-message failure handling** in consumer (`batchItemFailures`
  response) — improves throughput when 1 of 10 messages has a
  permanent error.
- **Audit retention beyond 14-day-of-DB-storage.** For compliance,
  audit data eventually moves to S3 + Glacier. Out of scope today.
- **Consumer's connection caching.** Same module-level pattern as
  Stage 3's connection cache (Lever 1). Free win in chunk E.

## Lessons carried forward

- **Async patterns invert the latency story.** Stage 5's "make the
  user wait less" got us to 127ms. Stage 6's "do less in the user's
  request path" is a different tool with the same goal — push work
  out of the synchronous flow entirely. Combined, they're how big
  systems stay fast.
- **Idempotency is mandatory in async systems**, not optional. SQS
  can deliver any message twice. The consumer must always assume
  duplicates exist.
- **Decoupling pays dividends in deploys.** Updating the consumer
  Lambda (new code, new env var) doesn't affect the producer.
  Restart, take down, deploy independently — the queue absorbs the
  consumer's downtime.
- **Per-component IAM identities limit blast radius.** Same lesson
  from Stage 3 (per-tenant DB user). Stage 6 doubles down: separate
  Postgres user for the audit consumer, separate Lambda execution
  role with narrowly-scoped permissions.
- **AWS event source mappings are the "magic" wiring.** No polling
  loop in our code. AWS does it. We just declare "this Lambda
  consumes from this queue" in terraform.

## Lessons learned (from chunks D-E debugging)

### Lesson 1 — VPC Lambdas need VPC endpoints to reach AWS service public APIs

Exactly the gotcha Stage 3's D3.4 documented as "the trigger that
would change this." Stage 6 hit it.

The click-handler Lambda sits in private subnets (Stage 3 D3.7).
When we added a `boto3.client("sqs").send_message()` call, the
Lambda hung for 10 seconds and timed out. The hostname
`sqs.us-east-1.amazonaws.com` resolves to public IPs by default;
private subnets have no route to public internet (no NAT, no IGW
route — by deliberate design).

**Fix:** add an SQS interface VPC endpoint. With `private_dns_enabled
= true`, AWS rewrites DNS resolution at the VPC level so
`sqs.us-east-1.amazonaws.com` resolves to the endpoint's private
IPs (172.31.96.x in our case). The Lambda's boto3 client connects
to those private IPs over the local VPC network. No code change in
the Lambda — entirely a network-layer fix.

**Cost:** ~$14/mo for an interface endpoint across our 2 AZs. Made
toggleable via `var.enable_sqs_vpc_endpoint` in the data-platform
project — same pattern as RDS Proxy. Default off; enable for active
async work; disable to save cost.

**Generalization for any future Lambda:** before adding a
`boto3.client(<service>).<call>()` from a VPC-attached Lambda, ask
whether that service is reachable. Two cases:
- AWS service in the VPC (RDS, Lambda-to-Lambda within VPC,
  ElastiCache): no extra config needed.
- AWS service public API (SQS, Secrets Manager, S3, DynamoDB, etc.):
  need an interface endpoint OR a NAT (for general internet egress).

CloudWatch Logs is the special exception — Lambda runtime ships logs
via an internal channel that bypasses customer VPC routing.

### Lesson 2 — Propagation timing matters; be patient after multi-step changes

After applying:
1. `data-platform` with `enable_sqs_vpc_endpoint=true`
2. `lambda-hw` to update env vars

The Lambda still timed out for several minutes. **Three independent
propagation windows** were stacking:

- **VPC endpoint provisioning:** AWS-published "available" status
  doesn't mean fully usable. ENI creation and DNS propagation across
  AWS's internal infrastructure takes ~2-5 min beyond the apparent
  ready state.
- **Lambda env var refresh:** Lambda function configuration updates
  eventually, but warm containers running before the update keep the
  old env. New invocations get fresh containers with new env, but
  there's a window where you're rolling.
- **boto3 client connection caching:** the Python SQS client created
  at module level may have cached DNS resolutions or connection
  state from a prior failed attempt; takes a fresh container to
  reset.

**Practical guidance after any "platform → tenant → app" toggle
chain:** wait ~5 minutes total before declaring something broken.
We spent significant time debugging what was actually just AWS
catching up.

### Lesson 3 — boto3 default timeouts (60s) are wrong for serverless

Default boto3 client timeouts are `connect_timeout=60s,
read_timeout=60s`. With Lambda's 10s timeout, this means **boto3
never gets a chance to fail with a useful error** — Lambda kills the
process first, you see "Task timed out" with no diagnostic info.

**Pattern for any boto3 client in Lambda:**
```python
from botocore.config import Config

_client = boto3.client(
    "sqs",  # or any service
    region_name=AWS_REGION,
    config=Config(
        connect_timeout=3,
        read_timeout=3,
        retries={"max_attempts": 1},
    ),
)
```

3-second timeout, 1 retry. If something is fundamentally wrong with
network, code fails in ~3-6 seconds with a specific exception
(`EndpointConnectionError`, `ConnectTimeoutError`, etc.) that goes
in CloudWatch logs. Way better debugging signal than a Lambda
timeout.

We learned this debugging chunk E: tightening the SQS client's
timeouts surfaced "endpoint not reachable" errors instead of the
Lambda hanging silently for 10s.

### Lesson 4 — Async consumer cold-start lag is observable

Measured `received_at - clicked_at` on the first click after
deploy: ~22 seconds. That's:
- ~5s SQS batching window
- ~10s consumer cold start (VPC ENI + psycopg init + DB connection)
- ~2-5s residual buffering

After the consumer warmed up, lag dropped to ~5-8 seconds (mostly
the batching window).

**Implication:** for use cases where audit timeliness matters
(real-time fraud detection, security monitoring), the cold-start
lag is a real problem that argues for provisioned concurrency on
the consumer or shorter batching windows. For our use case (audit
log for review later), it's fine.

The lag is observable in CloudWatch Logs Insights via
`@timestamp - clicked_at` calculations on the consumer's
`audit_inserted` events, or in the DB via the `received_at -
clicked_at` column.

### Lesson 5 — Toggleable expensive infrastructure must cascade through dependent code

When `enable_sqs_vpc_endpoint = false`, the click-handler's
`SQS_AUDIT_URL` env var must also be empty — otherwise the producer
will try to call SQS and hang. We wired this via the platform's
`sqs_vpc_endpoint_enabled` output, which lambda-hw consumes
conditionally:

```hcl
SQS_AUDIT_URL = (
  data.terraform_remote_state.data_platform.outputs.sqs_vpc_endpoint_enabled
  ? aws_sqs_queue.click_audit.url
  : ""
)
```

The producer code's `if not SQS_AUDIT_URL: return` short-circuits
when the URL is empty, avoiding the hang.

**Generalization:** when a piece of infrastructure is toggleable for
cost reasons, every downstream component that depends on it must
either (a) be toggled together, or (b) gracefully degrade when it's
absent. Half-toggled state is the worst — components fail in
confusing ways. The cascade-via-output pattern keeps it consistent.
