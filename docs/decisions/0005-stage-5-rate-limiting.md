# Stage 5 — Rate limiting

**Goal:** Protect the cost surface, the database, and the user
experience from runaway request patterns. Use AWS-native primitives
that come free with what we already have. Surface throttle events
through the CloudWatch alarms we set up in Stage 4 so we know when
limits fire.

We pick **two layers**: API Gateway route-level throttling at the
front door, Lambda reserved concurrency as a hard backstop. We
explicitly skip three other layers (WAF, app-level, Function URL
throttling) because the cost or complexity isn't justified at our
scale.

## The four layers we considered

| Layer | Cost | Granularity | Decision |
|---|---|---|---|
| API Gateway throttling (HTTP API stage / route settings) | free | per-route, per-stage; not per-user without API keys | **Use** (D5.1) |
| Lambda reserved concurrency | free | total parallel executions | **Use** (D5.2) |
| AWS WAF rate-based rules | ~$5/mo per ACL + per-request | per-IP, per-pattern | Skip (D5.3) |
| App-level (Lambda code, DB-backed counters) | code complexity + DB writes | anything you can detect | Skip (D5.4) |

Plus the auth-service's `/auth/token` endpoint, which already has
nginx `limit_req` from the gateway repo — handled separately, not in
scope here.

## Decisions

### D5.1 — API Gateway: route-level burst 10, rate 5 RPS

Two parameters on the HTTP API stage's `default_route_settings`:

- **`throttling_burst_limit = 10`** — bucket size. How many requests
  can pile up in a tight window without being throttled. Token-bucket
  semantics.
- **`throttling_rate_limit = 5`** — refill rate, in requests per
  second. Sustained RPS ceiling.

Under these, a fast-typing human can't trigger throttling (clicking
once a second is well under 5 RPS, and 10 piled-up clicks would empty
the burst before refill matters). A scripted abuser hitting the
endpoint at 50 RPS gets 429s on every request after the first ~2
seconds.

**Alternatives considered:** higher (looser) limits leave more
headroom for legitimate burst patterns we haven't seen yet. Tighter
limits catch abuse faster but produce more false positives. Without
real production traffic data, conservative-but-not-paranoid is the
right starting point. Easy to tune later.

**Why the stage-level setting (not per-route):** we have one route.
When we have many, route-level overrides matter. Even then, a stage
default makes sense as the floor; per-route bumps allow specific
endpoints to be more or less restrictive.

**Account-level vs. stage-level:** AWS also has account-wide quotas
(default 10,000 RPS burst / 5,000 RPS sustained per region). Those
are limits on YOU as a customer, not what we want. Our stage-level
settings are the per-app floor.

**HTTP API vs REST API note:** HTTP API doesn't support API keys
natively. Per-user or per-key throttling requires REST API + usage
plans, which we don't use (cost reasons documented in D2.C1). Our
HTTP API throttling is per-stage / per-route, not per-user. For
per-user limits later, we'd implement at the application layer (D5.4
revisit) using JWT `sub` as the key.

### D5.2 — Lambda reserved concurrency: 10

`aws_lambda_function.hello.reserved_concurrent_executions = 10`.

This caps the maximum number of Lambda invocations running
**simultaneously** for this function. Above 10, AWS throttles new
invocations (HTTP 429 to API Gateway, which surfaces it as 502 to
the client by default — see "Open items").

**Why this layer in addition to API Gateway throttling:**

- API Gateway limits **rate** (RPS over time). Lambda concurrency
  limits **simultaneity** (peak parallelism).
- An attacker could stay under 5 RPS but launch 50 long-running
  invocations simultaneously, exhausting downstream resources (DB
  connection pool, CloudWatch quota). API Gateway throttling
  wouldn't catch that. Lambda concurrency does.
- Defense in depth: two independent gates. If one is misconfigured,
  the other still bounds blast radius.

**Why 10:** at our scale (handful of users, click-counter workload),
even 1 concurrent invocation would be unusual. 10 leaves plenty of
headroom for normal use while making "we suddenly have 100 parallel
invocations" detectable as a reserved-concurrency throttle.

**Tradeoff:** reserved concurrency *also* removes that capacity from
the account-wide unreserved pool (default 1000). Reserving 10 means
10 fewer for unreserved Lambdas in this account. Not a problem now;
worth knowing when we add more Lambdas (Stage 6's queue consumer
will want its own slice).

**Tradeoff #2:** reserved concurrency caps cold starts too. With
provisioned concurrency (different feature) you can have always-warm
containers up to the reserved concurrency. We don't use provisioned
concurrency (D3.x decisions); reserved concurrency is just the cap.

### D5.3 — Skip AWS WAF

WAF would give us:
- Per-IP rate limits (5-min rolling window, AWS-managed)
- Bot detection rules (managed rule groups)
- Geographic blocking, header inspection, etc.

WAF would cost us:
- ~$5/mo per Web ACL
- $1/M requests evaluated
- $1/M requests for each rule (rate-based rules count)
- Operationally: another resource to terraform, another set of metrics

At our scale, WAF is over-engineering. The free protection from API
Gateway throttling + Lambda concurrency catches most abuse patterns
that matter for a small learning project.

**When WAF starts being right:**
- Real users at internet scale (10k+ MAU)
- Public unauthenticated endpoints
- Specific abuse patterns that need pattern matching (e.g., SQL
  injection attempts, scraping bots)
- Compliance requirements that mandate WAF

Documented as a future revisit; not on the path today.

### D5.4 — Skip application-level rate limiting

Application-level rate limiting (counter in DB, check-and-fail in
Lambda code) gives the most flexibility — per-user, per-action,
per-time-of-day, anything you can express. It also adds:

- A DB write on every request (for the counter)
- Code complexity (counter, check, race conditions, cache?)
- Latency overhead (~5-10ms per request to write+read)

For our case, **API Gateway + Lambda concurrency are sufficient**.
We don't have per-user abuse vectors yet. When we do (e.g., one user
spamming the click counter), per-user limits make sense — and the
JWT `sub` is already a stable identity to key off.

**When app-level starts being right:**
- Per-user abuse vectors emerge ("user X is hitting it 1000x/day")
- Need to differentiate normal-but-busy from abusive (a heavy
  legitimate user vs. a scraper)
- Per-action limits matter (1 password reset per hour, but unlimited
  reads)

Documented as a future revisit. The infrastructure for it (DB,
JWT-derived identity) is already there.

### D5.5 — Skip Function URL throttling

Function URLs (Stage 1 path) can be throttled too via reserved
concurrency at the function level (which we're already doing) or via
client-side patterns at Flask. The Function URL itself doesn't have
rate-limit settings the way API Gateway does.

**Why we don't do anything specific here:** the Function URL is
IAM-authed, callable only by `apps-ec2-role` (the EC2 instance
profile). For an attacker to abuse it, they'd need to compromise the
EC2 box. At that point, rate limiting Function URL is the least of
our problems.

The Lambda's reserved concurrency cap (D5.2) covers this path too.
If Flask itself is the source of abuse (bug in app.py loops the call
forever), the concurrency cap stops it. That's the meaningful gate.

### D5.6 — Skip changes to auth-service

The auth-service's `/auth/token` and `/auth/login` endpoints already
have nginx-level rate limiting:

```
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone $binary_remote_addr zone=auth:10m rate=30r/m;
```

(From `~/gateway/gateway/nginx.conf`.) Per-IP rate limits, configured
when the gateway was set up. Already in production, already protects
the JWT-minting path from abuse.

We don't add anything more here. Stage 5 changes are scoped entirely
to lambda-hw's API Gateway and Lambda function.

## What CloudWatch will show when limits fire

All three sources of throttling surface in CloudWatch metrics we're
already publishing:

| Source | Metric | Existing Stage 4 alarm? |
|---|---|---|
| API Gateway throttle | `AWS/ApiGateway/4XXError` (specifically 429) | No (could add) |
| Lambda concurrency throttle | `AWS/Lambda/Throttles` | **Yes** — `lambda-hw-hello-throttles` from Stage 4 |
| Lambda errors from any source | `AWS/Lambda/Errors` | **Yes** — `lambda-hw-hello-errors` from Stage 4 |

The Stage 4 alarm `${var.function_name}-throttles` was set with
threshold "≥1 throttle in any 5-min window" — meaning the FIRST time
the reserved concurrency limit fires, an email lands. That's
exactly the "something is suddenly hammering us" signal we want.

The dashboard from Stage 4 also shows Lambda throttles as a metric
widget; that'll spike visibly during a throttling incident.

For API Gateway-side 429s, we'd see them in the API Gateway access
log group (`/aws/apigateway/lambda-hw-hello`) with `status: "429"`
fields. No alarm yet. Could add one — but the Lambda-throttle alarm
is the more reliable signal because it fires on the actual blocked
invocations, not just at API Gateway.

## What we did NOT do (intentionally)

- **No WAF** (D5.3) — cost not justified at this scale.
- **No app-level rate limits** (D5.4) — complexity not justified;
  API-Gateway + Lambda-concurrency cover the threat model.
- **No Function URL throttling** (D5.5) — IAM already gates it,
  Lambda concurrency cap is the meaningful backstop.
- **No auth-service changes** (D5.6) — already nginx-limited.
- **No 429-specific alarm** — the Lambda-throttle alarm catches the
  case we actually care about (someone overwhelming our function).
- **No usage plans** — REST API feature; we use HTTP API.
- **No per-user limits** — would require app-level (D5.4) or REST
  API + usage plans + API keys, neither of which we want.

## Open items / future revisits

- **WAF** if we ever face real abuse patterns at internet scale.
- **App-level rate limiting** if specific per-user abuse vectors
  emerge. The JWT `sub` is a stable key to limit on.
- **Tune limits with real traffic data.** Today's 10/5 are conservative
  guesses. In production we'd watch the throttle metric for false
  positives and loosen, or watch for traffic spikes and tighten.
- **API Gateway error response code on 429.** API Gateway HTTP API
  returns 429 to the client by default for throttling. Lambda
  concurrency throttle (which API Gateway sees as a 429 from the
  integration) gets relayed as 502 by default — confusing for
  callers. Worth investigating whether we want to map it to 429 or
  503 with a custom integration response.
- **Provisioned concurrency** if cold-start latency in production
  ever matters enough. Currently we accept ~1.5s p99.
- **Per-route throttling** when we have multiple API Gateway routes.
  Login / read-heavy / write-heavy may want different limits.
- **Cost alarm on AWS Budgets** (Stage 4 has $5/mo) is itself a kind
  of rate limit — it surfaces sustained over-spending. Already in
  place.

## Lessons carried forward

- **Two-layer defense beats one-layer at any scale.** API Gateway
  throttling is fast (no Lambda invocation needed for the 429
  response) but coarse-grained. Lambda concurrency is slower (the
  invocation has to start before being throttled) but bounds blast
  radius downstream. Together they cover both rate-and-burst and
  parallelism-explosion.
- **Free first, paid later.** All Stage 5 changes are AWS-included,
  no incremental cost. WAF and per-user limits cost real money;
  defer until they're actually justified.
- **Existing alarms surface new behavior automatically.** The Stage
  4 throttle alarm was set up before we added concurrency limits;
  now it'll fire when concurrency is exceeded. This is the value of
  the "log + alarm everything early" approach — adding new behavior
  later doesn't require new observability infrastructure.
- **Conservative starts beat optimistic starts.** Better to start
  with too-tight limits (and loosen on observed false positives)
  than too-loose (and tighten only after a real incident).

## Lessons learned (from chunk C+D load tests)

Empirical observations from running `hey` against the deployed setup:

### Lesson 1 — Throttle settings have ~30-60s propagation lag

First load test ran immediately after `terraform apply` and saw very
loose throttling (6/100 throttled at 18 RPS). Re-running ~5 minutes
later showed much tighter behavior (25/100 at 70 RPS). Settings were
the same; AWS just hadn't finished propagating them across all the
edge servers handling the API.

**Practical guidance:** when configuring or tuning throttle limits,
wait at least 1 minute after `apply` before measuring. First-minute
results aren't representative.

### Lesson 2 — AWS HTTP API throttle limits are advisory, not strict

Configured `burst=10, rate=5 RPS`. Strict token-bucket math says
~17 requests should pass over a 1.4-second test. Actual: 75 passed.
**~4-5× looser than the configured value.**

This is documented AWS behavior (the docs call values "approximate")
but isn't headlined. If you need a hard precise rate limit, HTTP API
alone won't deliver it. Options for stricter:

- Use REST API + usage plans + API keys (more cost, more setup, but
  per-key quotas are strict)
- Add app-level enforcement in Lambda (counter in DB or cache)
- Use the downstream concurrency cap as the *real* hard limit, treat
  API Gateway throttling as a soft early warning

We chose the third — Lambda's `reserved_concurrent_executions = 10`
IS strictly enforced, and its combination with the loose API Gateway
throttle is enough for our threat model.

### Lesson 3 — Lambda concurrency throttle vs API Gateway throttle produce different status codes

| Throttle source | Status code returned to client | What it means |
|---|---|---|
| API Gateway rate/burst | **429** | Front door said "too many requests, slow down" |
| Lambda concurrency cap exceeded | **503** | Front door let it through; Lambda had no slot. API Gateway translates Lambda's internal 429 to 503 (integration-level error) |

In our load test with `-c 50`: 34 × 429 + 52 × 503. **Both layers were
firing simultaneously.** The 503s are the diagnostic signal that
"front-door wasn't enough; backstop kicked in." If you only see
429s and no 503s, your front door is absorbing all the overflow —
fine for normal abuse, but you've got no visibility into how close
the backstop is to firing.

### Lesson 4 — The Lambda-throttle alarm fires on the meaningful signal, not noise

The Stage 4 alarm watches `AWS/Lambda/Throttles` (Lambda-side
throttles only — *not* API Gateway throttles). This was deliberate
(or at least correct) because:

- API Gateway 429s are *expected* — they're the front door doing its
  job. Alerting on them would mean an email every time normal traffic
  hits the configured rate. Noisy, useless.
- Lambda throttles mean **something got past the front door and
  overwhelmed the compute layer**. That's a meaningfully bigger event
  worth waking someone up for.

Confirmed empirically: tests 1 and 2 produced API Gateway 429s but
zero Lambda throttles → alarm stayed `OK`. Test 3 with much higher
concurrency produced 52 Lambda throttles → alarm transitioned to
`ALARM` within ~5 min, email landed.

**Generalization:** when you have layered protection, alarm on
"backstop fired," not "outer layer engaged." The outer layer firing
is normal traffic shaping; the backstop firing means something
actually concerning is happening.

### Lesson 5 — `hey` is the right tool, not curl loops

A bash loop with curl works for rough demonstrations but produces
inconsistent results because each `curl` is a fresh process with
its own DNS lookup, TLS handshake, etc. `hey` reuses connections
properly, gives you a real RPS number, and produces histograms that
match how AWS measures load. Worth installing once
(`brew install hey`) for any "is the limit working" verification.
