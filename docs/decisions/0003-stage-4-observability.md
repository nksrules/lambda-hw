# Stage 4 — Logging & observability

**Goal:** Make the production system queryable, measurable, and
self-monitoring — without dumping money into CloudWatch or drowning
ourselves in pager noise. Stages 0-3 produced a working architecture;
this stage adds the instruments so we can answer questions like "is it
slow?", "which user hit which path?", and "is something on fire?"
without SSHing or guessing.

We touch four CloudWatch sub-services:

| Sub-service | What we add |
|---|---|
| **CloudWatch Logs** | Structured JSON in Lambda. Retention on log groups. Separate group for API Gateway access. |
| **CloudWatch Metrics** | Use the built-in Lambda + API Gateway metrics. No custom metrics yet. |
| **CloudWatch Alarms** | Three. Email-notified via one SNS topic. |
| **CloudWatch Dashboards** | One dashboard with the project's key signals. |

Plus AWS Budgets (separate service) for cost-side alerting.

## Decisions

### D4.1 — Structured JSON logging in the Lambda

Replace plain text logs with a JSON-shaped emitter. Each Lambda
invocation produces log events whose body is a single JSON object,
making CloudWatch Logs Insights filter/aggregate queries trivial:

```
fields @timestamp, request_id, invocation_path, latency_ms, status
| filter status >= 400
| stats avg(latency_ms), count() by invocation_path
```

**Standard fields per event:**

| Field | Source | Why |
|---|---|---|
| `request_id` | `context.aws_request_id` | Correlates with API Gateway access logs and CloudWatch entries |
| `invocation_path` | derived in Lambda | `api-gateway-jwt` or `function-url-iam` |
| `username` | from claims or body | For per-user filtering |
| `display_name` | from claims or body | Echo for sanity; not used for filtering |
| `latency_ms` | measured in handler | p50/p95 calculations |
| `status` | response status code | Error filtering |
| `event` | one of `invocation`, `error`, `info` | Categorization |

**No `sub` (full user UUID) in logs by default** — `username` is
sufficient for the kinds of operational queries we'd run. Sub goes in
only when we add stage-3 database tracing.

**Why structured logging over plain text:** Logs Insights treats JSON
fields as first-class. Without it, you parse strings with regex inside
the query — slower, fragile. With it, the query language reads like
SQL.

### D4.2 — Log retention: 14 days Lambda, 60 days API Gateway

By default, log groups retain forever. That's a slow-motion cost leak
and a privacy problem. Our intent:

- **Lambda function logs:** ~2 weeks. Debug-flavored — most useful in
  the days right after a problem; older entries are usually noise.
- **API Gateway access logs:** ~6-7 weeks. Audit/abuse-flavored — useful
  for "who hit this last month?" investigations and slow-burn analysis.

**AWS retention granularity is fixed.** CloudWatch Logs only accepts
specific retention values: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180,
365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653 days.
We initially specified 15 and 45; AWS snaps to the closest values:
**14 (Lambda)** and **60 (API Gateway)**. Both are within an "off by
a few days" tolerance of the original intent.

Different retention values are one reason (of several) why these get
separate log groups — see D4.3.

**Cost comparison at our scale (under 1 GB/month total log volume):**
$0.03/GB-month × 1 GB × 2 months ≈ $0.06. Trivial. The retention is
about hygiene, not cost.

### D4.3 — Separate log groups by source

Convention is one log group per logical service:

| Log group | Source | Created by |
|---|---|---|
| `/aws/lambda/lambda-hw-hello` | Lambda runtime | AWS auto-creates; we add retention via terraform |
| `/aws/apigateway/lambda-hw` | API Gateway access logs | We create explicitly via terraform |

Reasons to separate, not merge:

- Different retention (D4.2)
- Different IAM permissions (admins of one service shouldn't necessarily see the other's logs)
- Different log shapes (Lambda logs are JSON-from-handler; access logs are AWS-emitted JSON with fixed fields)
- Logs Insights queries can span multiple groups when you need cross-group correlation

The Flask app on EC2 stays in journalctl — not CloudWatch. We can
revisit if/when Flask grows back; for now the data path that matters
(API Gateway → Lambda) is fully covered.

### D4.4 — Three alarms, conservative thresholds, one SNS topic

Goal: alarms that almost never fire, fire when something real happens.
Email noise undermines trust in alarms.

| Alarm | Metric | Threshold | Why |
|---|---|---|---|
| **Lambda error rate** | `AWS/Lambda Errors` (Sum, 5min, 3 evaluation periods) | ≥ 1 in each of 3 consecutive 5-min windows | Persistent errors = real problem. Single transient error self-clears, no email. |
| **Lambda throttle** | `AWS/Lambda Throttles` (Sum, 5min, 1 period) | ≥ 1 | Throttles mean account-level concurrency cap or runaway caller. Always want to know. |
| **AWS monthly bill** | AWS Budgets (separate service) | $5/month, notify at 80% and 100% | Defense against runaway costs from a misconfig (logging loop, accidental API spam). |

**Why these three and not more:** false-positive resistance scales
inversely with alarm count. Three alarms that never fire is
informative; ten alarms with one false-positive a week trains you to
ignore them.

**SNS topic single-purpose for alarm emails.** One topic, one email
subscription, one signing identity. Future operators can subscribe
their own emails; if we ever want different alarms to go to different
people, we add topics not subscriptions.

### D4.5 — One CloudWatch dashboard, project-scoped

A single dashboard with the signals worth glancing at:

- **Invocations / minute** (Lambda + API Gateway, side by side)
- **p50 / p95 latency** (Lambda Duration metric)
- **Error rate** (Lambda Errors / Lambda Invocations)
- **API Gateway 4xx and 5xx rates** (separate widgets)
- **Cold starts** (Lambda Init Duration where >0)

Free tier covers up to 3 dashboards; we'll use one. Future apps would
get their own.

### D4.6 — No EMF custom metrics yet

CloudWatch's [Embedded Metric Format](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format.html)
lets you emit metrics by including a special block in your log events;
no separate API call needed. Cheap, expressive, the right pattern when
business questions show up.

We don't add any in Stage 4. Reason: built-in Lambda and API Gateway
metrics cover the operational questions we actually have right now
("is it up", "is it fast", "are there errors"). Adding metrics for
business events ("how many tokens minted per day", "which audience is
most used") is reasonable later when we have specific questions.

The pattern is documented so we recognize the moment it's worth it.

### D4.7 — No X-Ray distributed tracing yet

X-Ray would give end-to-end traces across (browser → API Gateway →
Lambda → RDS → ...). Useful when you have multi-hop service chains and
need to see where time goes.

For Stage 4, we have a single Lambda and no downstream services.
X-Ray's overhead (small, but nonzero) and conceptual surface (segments,
subsegments, instrumentation) outweigh the value.

X-Ray becomes interesting in **Stage 3** (Lambda → RDS Proxy → RDS) and
**Stage 6** (queue producer → SQS → consumer Lambda). Revisit then.

### D4.8 — Logging hygiene: no sensitive payloads

What we DO log: `request_id`, `invocation_path`, `username`,
`display_name`, `latency_ms`, `status`, `event`.

What we deliberately do NOT log:

- The full JWT bytes (would let a logs-reader impersonate a user)
- Request bodies (might contain user-typed PII once Lambdas get richer)
- Response bodies (same reason)
- Cookie or session-token values
- Any AWS credentials

This is a defensive default. The log group is IAM-readable to a
narrower audience than "everyone in the AWS account," but defense in
depth — assume any log line could be exfiltrated and treat it
accordingly.

## What we did NOT do (intentionally)

- **No X-Ray** (D4.7).
- **No EMF custom metrics** (D4.6).
- **No log shipping to S3 / a SIEM / Datadog / Splunk.** All those are
  reasonable downstream additions; not needed for our scale.
- **No CloudWatch Agent on EC2.** Flask logs stay in journalctl. We can
  revisit if/when Flask becomes important.
- **No anomaly-detection alarms.** AWS supports them, they're more
  expensive ($0.30/alarm) and require historical data to baseline. We
  don't need them yet.

## Open items / future revisits

- **EMF custom metrics** when business questions emerge.
- **X-Ray** for Stage 3 and Stage 6.
- **Log retention based on actual usage.** If 15-day Lambda retention
  turns out to be too short during a debugging session, easy to bump.
- **Per-user dashboards or filters** if we ever need per-user latency
  investigation.
- **Alarm cooldown / alarm-to-alarm correlation** if we add more
  alarms and they start cascading.
- **Cost anomaly detection** as a complement to the budget alarm.

## Lessons carried forward from earlier stages

- **AWS service quirks aren't always documented.** Stage 1 taught us
  Function URLs need resource-policy entries; Stage 2 taught us HTTP
  API rejects ES256 and requires OIDC discovery. Stage 4 will probably
  surface a similar surprise; budget time for one.
- **Eventual consistency.** Alarm state changes, metric ingest, log
  group creation all have propagation delays in the seconds-to-minutes
  range.
- **Run terraform as a non-root IAM identity.** Still applies.
- **Decision doc first, code second.** Saves backtracking when we
  realize a decision was implicit but underspecified.
