# Stage 2 — API Gateway + JWT (browser-direct Lambda)

**Goal:** Add a second path from browser to the same Lambda — this time
without Flask in the request path. Browser fetches a short-lived JWT from the
auth-service, presents it to API Gateway, API Gateway validates the signature
and audience, only then invokes the Lambda. Same Lambda as Stage 1; new front
door. The Stage-1 server-proxy path is preserved side-by-side for comparison.

```
                                                     ┌─► Stage 1: ─► Flask /api/hello ─SigV4─┐
   Browser ──fetches gateway session token + JWT─────┤                                       ├─► Lambda
                                                     └─► Stage 2: ─► API Gateway (JWT auth)──┘
```

The shape this enables: an iOS client (or any non-browser client) can use
the Stage-2 path directly. Same JWT, same API Gateway, same Lambda. Stage 7
extends the auth flow to reach iOS; the API surface itself is reusable from
day one.

## Cross-repo split (important)

This stage spans two repos. The work belongs where the resource is owned:

| Concern | Lives in | Why |
|---|---|---|
| JWT signing keypair (Secrets Manager) | `~/gateway/terraform/auth-service/` | The auth-service is gateway infrastructure shared by ALL apps. Keys are gateway-level. |
| `/auth/token` and `/.well-known/jwks.json` route code | `~/gateway/auth-service/app.py` | Lives where the auth-service does. |
| IAM permission for `apps-ec2-role` to read the secret | `~/gateway/terraform/auth-service/` | Couples to the secret. |
| API Gateway HTTP API + JWT authorizer config | `~/lambda-hw/terraform/` | Per-app concern. Each future app has its own. |
| Lambda code reading claims | `~/lambda-hw/lambda/hello/` | Per-app concern. |
| UI changes (Stage-2 button, token fetcher JS) | `~/lambda-hw/templates/` + `~/lambda-hw/app.py` | Per-app concern. |
| Gateway-side decision doc | `~/gateway/docs/` | Separate doc, written when we do that chunk. |

The lambda-hw repo references the JWKS URL as a hardcoded string
`https://apps.ksastry.com/auth/.well-known/jwks.json`. No cross-repo
infrastructure dependency at the IaC level — just a stable HTTPS URL.

## Decisions

### D2.A1 — `/auth/token` endpoint extends the existing auth-service

Not a new dedicated service. The auth-service already validates session
cookies, knows users, owns the user DB. Token minting is a 30-line addition
to a service whose entire job is auth.

**Alternatives considered:** new dedicated token service. Rejected — would
have to re-authenticate the same session, doubling complexity for no gain.

### D2.A2 — Algorithm: RS256 (RSA-2048), polymorphic code

**What we actually deployed:** RS256 with a 2048-bit RSA keypair.

**What we originally chose:** ES256 (ECDSA P-256). We built and deployed
ES256 successfully — token minting, JWKS publishing, browser-side decode
all worked. Then API Gateway's HTTP API JWT authorizer rejected it at
runtime with `error_description="signing method ES256 is invalid"`.
Despite some AWS docs implying ES support, **HTTP API JWT authorizer
only accepts the RS-family in practice**. We switched to RS256 to
unblock; the architectural intent and security properties are identical.

**Symmetric (HS256) is structurally wrong here:** API Gateway would need
the signing key to validate, defeating the whole asymmetric-trust model.
The auth-service alone holds the private key; API Gateway only needs the
public key.

**Code is algorithm-agnostic.** `jwt_signer.py` introspects the loaded
PEM key, detects EC vs RSA, and emits the correct JWK shape. The
`algorithm` field in the Secrets Manager JSON drives signing and
JWKS publication. Swapping back to ES256 — or to PS256, RS512, etc. —
is just an operational change (regenerate keypair, replace secret value,
restart auth-service); no code edit. See lessons learned at the bottom.

### D2.A3 — Private key in AWS Secrets Manager, single JSON entry, manual provisioning

The signing key is stored as one Secrets Manager secret named
**`gateway/jwt-signing-key`** (gateway namespace — NOT `lambda-hw`),
containing a JSON blob:

```json
{
  "algorithm": "ES256",
  "kid": "<sha256[:16] of the public key>",
  "private_key": "-----BEGIN EC PRIVATE KEY-----\n...\n",
  "public_key":  "-----BEGIN PUBLIC KEY-----\n...\n"
}
```

**Why one JSON entry, not two secrets:** keeps the keys paired (no risk of
mismatched private/public), one IAM permission to grant, one Secrets
Manager API call at startup, and we can carry the `kid` along for free.
The `kid` (key ID) is a JWT-standard header field; JWKS publishes
`(kid, public_key)` pairs so consumers can match the right key during
rotation overlap.

**Why manual provisioning, not terraform-generated:** terraform's
`tls_private_key` would put the private key in tfstate, which lives in
S3. Even with bucket encryption, that's the wrong operational pattern —
private keys shouldn't traverse IaC. One-time setup script (RSA-2048
form, what's deployed today):

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/jwt-priv.pem
openssl pkey -in /tmp/jwt-priv.pem -pubout -out /tmp/jwt-pub.pem
KID=$(openssl dgst -sha256 /tmp/jwt-pub.pem | awk '{print substr($2,1,16)}')
SECRET_JSON=$(jq -n \
    --rawfile priv /tmp/jwt-priv.pem \
    --rawfile pub  /tmp/jwt-pub.pem \
    --arg kid "$KID" \
    '{algorithm:"RS256", kid:$kid, private_key:$priv, public_key:$pub}')
aws secretsmanager put-secret-value \
    --secret-id gateway/jwt-signing-key \
    --secret-string "$SECRET_JSON"
shred -u /tmp/jwt-priv.pem /tmp/jwt-pub.pem 2>/dev/null \
    || rm -f /tmp/jwt-priv.pem /tmp/jwt-pub.pem
```

For an EC keypair (ES256, would need a non-API-Gateway verifier), swap
the first two lines for `openssl ecparam -name prime256v1 -genkey -noout
-out /tmp/jwt-priv.pem` and the algorithm field for `"ES256"`. The
auth-service's `jwt_signer.py` handles either kind; only the secret
value changes.

For first-time creation (vs replacing an existing value), use
`aws secretsmanager create-secret --name gateway/jwt-signing-key
--description ... --secret-string ...` instead of `put-secret-value`.

Terraform owns the **secret container** (`aws_secretsmanager_secret`
resource) and IAM permissions, but never touches the secret value.

**Auth-service caching:** keys fetched once per worker process via
`@lru_cache(maxsize=1)`. ~1 Secrets Manager call per gunicorn worker
restart. Rotation requires worker restart for now (revisit as a
"smarter cache" item later).

**Production hardening (not done here):** AWS KMS asymmetric signing.
KMS holds the key and signs on request via `kms:Sign`; the key never
enters auth-service memory. Right answer for production; overkill for
learning. Documented as future work.

### D2.A4 — Two public well-known endpoints on the auth-service

Verifiers find our public key via two endpoints, both at standard
well-known locations:

1. **`/auth/.well-known/openid-configuration`** — minimal OIDC discovery
   document. API Gateway's JWT authorizer fetches *this first* (given
   only our issuer URL) to learn where the JWKS lives. We don't
   implement full OIDC — only the fields a JWT verifier strictly needs:

   ```json
   {
     "issuer": "https://apps.ksastry.com/auth",
     "jwks_uri": "https://apps.ksastry.com/auth/.well-known/jwks.json",
     "id_token_signing_alg_values_supported": ["RS256"]
   }
   ```

2. **`/auth/.well-known/jwks.json`** — the JSON Web Key Set: the public
   half of the keypair, formatted per RFC 7517. The route is a Flask
   handler that:

   1. Reads the cached public key from the in-memory keypair (loaded
      once from Secrets Manager at startup).
   2. Detects whether it's RSA or EC and converts PEM → JWK
      (in-memory math: base64url-encoding the modulus + exponent for
      RSA, or the X/Y coordinates for EC).
   3. Returns `{"keys": [{kty, ..., use, alg, kid}]}`.

**Both endpoints are public** — must be reachable without a session
cookie because API Gateway, iOS, etc. need to fetch them. Configured in
nginx to bypass `auth_request` and the `/.` deny rule.

**No files ever written.** All computation is microseconds; results are
cached via `lru_cache` and served with `Cache-Control: public, max-age=300`.
API Gateway also internally caches JWKS for ~10 minutes, so traffic to
either endpoint stays minimal regardless of inbound API request volume.

The `keys` array is plural specifically to support rotation overlap
windows: during rotation we publish both old and new public keys
simultaneously, distinguished by `kid`.

**Why both endpoints, not just JWKS:** API Gateway's HTTP API JWT
authorizer doesn't accept a JWKS URL directly; you give it the issuer
URL and it requires that issuer to serve OIDC discovery. We discovered
this the hard way during chunk B → chunk C handoff. See lessons learned.

### D2.B1 — JWT claims

Standard JWT claims:

| Claim | Value | Purpose |
|---|---|---|
| `iss` | `https://apps.ksastry.com/auth` | Issuer; helps consumers match against trust list. |
| `sub` | `str(user_id)` from auth-service DB | Stable, immutable user identifier. **Use this for foreign keys, ACLs, audit.** |
| `aud` | The app slug, e.g. `lambda-hw` | Audience; API Gateway rejects tokens not intended for it. |
| `iat` | unix timestamp | Issued-at; diagnostics. |
| `exp` | `iat + 900` (15 min) | Hard expiry. |

Custom claims (so Lambda doesn't need DB lookups for auth context):

| Claim | Source | Purpose |
|---|---|---|
| `username` | gateway DB | Human-meaningful identifier. **Mutable** — don't use as foreign key. |
| `display_name` | gateway DB | UI greeting. |
| `role` | gateway DB | `user` or `admin`. Available for fast role checks in the Lambda. |

**Why `sub` is a string, not an integer:** JWT spec requires it. Even
though our user IDs are integers in the DB, we stringify them in the
claim. (Not a UUID today; if we ever federate with Cognito, `sub` shifts
to Cognito's UUIDs and we plan a migration.)

**Why include both `username` and `sub`:** they have different stability
properties. `sub` is forever; `username` can be renamed. Use `sub` for
anything persisted; use `username` for human-facing stuff. The Lambda
echoes `received_username` today purely for visibility into the wire.

### D2.B2 — Token TTL: 15 minutes, transparent refresh

15 minutes is the balance: short enough that a leaked token has a
narrow exploit window; long enough that the user doesn't refresh
constantly. JS handles refresh transparently — proactive (check `exp`
before each call; refresh if within 2 min) rather than reactive (catch
401 and retry). Avoids latency surprises on unlucky requests.

The `/auth/token` endpoint plays the role of "refresh token" — it uses
the gateway session cookie, which is much longer-lived (typically days),
to mint a fresh JWT on demand. No separate refresh-token mechanism.

User visibility: zero. The only thing that pulls the user back to login
is the gateway session cookie expiring.

### D2.C1 — API Gateway: HTTP API (not REST API)

| | HTTP API | REST API |
|---|---|---|
| Pricing | $1.00 / M requests | $3.50 / M requests |
| Built-in JWT authorizer | yes | no (needs Lambda authorizer) |
| Latency | lower | higher |
| Features | minimal | full (usage plans, request transforms, caching, multi-stage) |

We pick HTTP API. The built-in JWT authorizer is the whole reason this
stage is reasonable. We don't need REST features yet. If Stage 5 needs
usage plans for rate limiting, we'll discuss whether to swap or layer.

### D2.C2 — CORS: restrictive, browser-explicit

CORS (Cross-Origin Resource Sharing) is a browser-only security feature.
It prevents random websites from making authenticated calls to your
APIs on the user's behalf. Configured on API Gateway:

```hcl
cors_configuration {
  allow_origins     = ["https://apps.ksastry.com"]
  allow_methods     = ["GET", "POST", "OPTIONS"]
  allow_headers     = ["Authorization", "Content-Type"]
  allow_credentials = false           # we use Bearer tokens, not cookies
  max_age           = 300
}
```

**Why specific origin, not `"*"`:** wildcard would let any random page's
JS call this API. Even if our auth would still reject those calls, the
defense-in-depth principle is to refuse them at the browser layer too.

**Why no credentials:** our auth flows entirely through the
`Authorization` header (Bearer JWT). Cookies aren't involved in
cross-origin calls. `allow_credentials = false` keeps the surface area
narrow.

Server-to-server callers (curl, the iOS app, another Lambda) don't
care about CORS — it's exclusively a browser-enforced thing.

### D2.D1 — Lambda trusts API Gateway's JWT validation

The Lambda code reads claims directly from
`event.requestContext.authorizer.jwt.claims` without re-validating the
signature. API Gateway has already done the cryptographic check; doing
it again would waste cold-start time.

Lambda still does **business-level** checks ("is this user allowed to
delete this resource") — those use the claim values, but don't
re-verify the signature.

The only way to bypass API Gateway is to call the Lambda's underlying
ARN directly. After Stage 2, the Lambda's Function URL still exists
(Stage 1's path) but is gated by IAM, not by anyone-with-a-JWT. So
trusting the JWT inside the Lambda is safe: any path that delivered
the request is one we control.

### D2.D2 — Keep Stage 1 server-proxy path side-by-side (learning-only)

Two buttons on the lambda-hw page: **Call via Flask (Stage 1)** and
**Call via API Gateway (Stage 2)**. Both call the same Lambda, both
display response + measured round-trip time. The whole point is to
feel the contrast — different auth model, different network path,
different observable latency profile.

**This is not the production-shape architecture.** A real lambda-hw
would have ONE ingress per Lambda (API Gateway), and the Function URL
+ Flask server-proxy path would be removed entirely. Multiple ingresses
to the same Lambda complicate trust analysis, monitoring, and rate
limiting. We keep both purely because the side-by-side comparison is
the learning artifact. See D2.D3 for the production-shape rationale.

### D2.D3 — Production architecture: one ingress per Lambda, one API Gateway per app

Two architectural rules of thumb that emerged from clarifying questions
during chunk D:

**Rule 1: One API Gateway *per app*, many Lambdas *per API Gateway*.**

A single API Gateway HTTP API can have many routes, each integrated
with a different Lambda:

```
lambda-hw API Gateway:
    POST /hello         → lambda-hw-hello
    POST /things        → lambda-hw-create-thing
    GET  /things/{id}   → lambda-hw-get-thing
```

All under one API, one JWT authorizer, one CORS config, one audience
(`aud: "lambda-hw"`). As lambda-hw grows, we add routes here.

For *multiple apps*, each gets its own API Gateway. Reasons: audience
scoping matches one-API-one-app naturally; per-app terraform stays
clean; blast radius contained; HTTP API has no per-API base charge so
it's cost-neutral.

**Rule 2: One ingress per Lambda in production. We have two for learning.**

Production Lambda functions almost always have a single invocation
path. Reasons:
- Single trust boundary — much easier to reason about security.
- Easier monitoring / metrics / log aggregation.
- Rate limiting / WAF apply once.
- The Lambda code reads identity from one place, not two.

Legitimate exceptions to the "one ingress" rule:
- Public webhooks (HMAC-validated) + authenticated user calls (JWT) —
  same business logic, two distinct caller populations.
- API Gateway for browser/mobile + direct Lambda invoke for internal
  cron/Step Functions — different audiences, both legitimate.

What we have (Function URL + API Gateway, both for the same browser
audience) is **not** one of those exceptions; it's a learning artifact.
A production cleanup would delete the Function URL, the inline IAM
policy granting `lambda:InvokeFunctionUrl`, the resource-based policy
on the function, and the Flask `/api/hello` server-proxy code. The
button removal would follow.

**Preferred ingress for our shape (web + future iOS): API Gateway with JWT.**
Function URL + IAM is the right pick only when callers are
exclusively AWS services or your own server fleet, with no need for
user-level identity inside the Lambda.

## What we did NOT do (intentionally)

- **No KMS-based signing.** Private key sits in auth-service memory.
  KMS would be the production-correct answer. Documented as future work.
- **No refresh tokens.** The gateway session cookie + `/auth/token`
  plays that role. Adding a separate refresh token would be appropriate
  if we ever needed offline access (e.g., long-lived iOS background tasks).
- **No multi-app token issuance yet.** We mint tokens with `aud:
  "lambda-hw"`. The architecture is ready for `aud: <other-app>` when
  another app exists, but we don't build that now.
- **No JWKS rotation tooling.** The keypair is generated once. Rotation
  is a documented procedure (see Open items) but not automated.
- **No request rate limiting.** Stage 5.

## Open items / future revisits

- **KMS-based signing** for production hardening.
- **Multi-app audience scoping** (Pattern 2 in B1b discussion). The
  `/auth/token` endpoint accepts an `audience` parameter from day one,
  so adding more apps is just: (1) check the user's app-access ACL,
  (2) include the requested audience in the JWT, (3) the new app's
  API Gateway accepts only its own audience. No changes to the
  signing key or auth-service trust model.
- **JWT key rotation runbook.** Documented procedure: add new key as a
  second JSON to Secrets Manager (or use Secrets Manager versions),
  restart auth-service so JWKS publishes both, wait for old tokens to
  expire (15 min), remove old key. Not automated.
- **Smarter JWKS cache invalidation.** Today, key rotation requires
  worker restart. A timed refresh (re-read Secrets Manager every N
  minutes) would let rotation happen without restart.
- **Cognito federation** if iOS auth ends up using Cognito. Would shift
  `sub` from gateway DB user IDs to Cognito UUIDs; needs migration plan.
- **`aws:SourceAccount`-style condition on the Stage-1 Function URL**
  was already added; the Stage-2 API Gateway's analogous defense is the
  audience claim. Worth periodically auditing both.

## Lessons carried forward from Stage 1

- **IAM eventual consistency.** Resource-policy and identity-policy
  changes can take seconds to minutes to propagate. After any policy
  change, wait 30-60s and run each verification 2-3 times before
  drawing conclusions.
- **Don't trust the IAM simulator alone.** It only evaluates
  identity-based policies and doesn't include all runtime context.
  Use it as a weak signal, not as a verdict.
- **Try the action via a different code path early** when something
  fails. Same target, different front door, isolates "auth" from
  "infrastructure."
- **Run terraform as a non-root IAM identity.** Stage 1 inherited a
  root-credentials habit; this stage should not perpetuate it. If
  not yet fixed, do it before next apply.

## Lessons learned (debugging chunks B and C)

### Lesson 1 — HTTP API JWT authorizer requires OIDC discovery, not just JWKS

When you set `issuer = "https://apps.ksastry.com/auth"` on the
authorizer, API Gateway fetches `<issuer>/.well-known/openid-configuration`
to find the JWKS URI — it does NOT accept a JWKS URL directly. You need
to publish a *minimal* OIDC discovery document at that path. The bare
minimum is:

```json
{
  "issuer": "https://apps.ksastry.com/auth",
  "jwks_uri": "https://apps.ksastry.com/auth/.well-known/jwks.json",
  "id_token_signing_alg_values_supported": ["RS256"]
}
```

Real OIDC providers include `authorization_endpoint`, `token_endpoint`,
`response_types_supported`, and many other fields. We don't need any of
those — we're not implementing a full OIDC IdP, just enough to be
JWKS-discoverable. AWS docs don't make this requirement obvious.

### Lesson 2 — HTTP API JWT authorizer rejects ES256 in practice

**Symptom:** API Gateway returns 401 with header
`error_description="signing method ES256 is invalid"` even though our
JWT, JWKS, and OIDC discovery doc were all internally consistent.

**Cause:** Despite some AWS docs implying ES-family algorithms are
supported, HTTP API's JWT authorizer accepts only the **RS-family**
(RS256/384/512) in practice. There are scattered reports of this in
GitHub issues; AWS hasn't published a definitive list.

**Fix:** Switch to RS256. We replaced the keypair value in Secrets
Manager (no terraform change needed since terraform owns only the
container) and restarted auth-service. The polymorphic `jwt_signer.py`
code emits the right JWK shape based on the key type, so no Python
edit either.

**Defensive design that paid off:** because we made the algorithm
field of the secret value drive both signing and JWKS publication,
swapping algorithms was an operational change, not a code change.
This is a pattern worth keeping in any signing system.

**Workarounds if you need ES support:** REST API + custom Lambda
authorizer (3.5× cost, more code), or validate JWTs inside the Lambda
itself (loses the "Lambda doesn't run if auth fails" property).
Neither is worth it for our case.

### Lesson 3 — Git hygiene for new directories

During the chunk B → main merge, the entire `terraform/auth-service/`
directory disappeared from the squash commit because every file in it
was untracked when the original commits were made. `git add` on
specific paths missed the directory; the soft-reset preserved an
already-incomplete index. Recovery was easy because the JWT-tokens
branch wasn't deleted yet.

**Habits to internalize:**
- `git status` *before every commit*, even when you think you know
  what's there.
- For new directories, use `git add <dir>/` explicitly. `git commit -a`
  only touches already-tracked files — that's the trap.
- Don't delete feature branches until you're sure main has everything.
  `git branch -d JWT-tokens` is cheap insurance.

### Lesson 4 — Provisioning patterns for cross-repo dependencies

Stage 2's design correctly split the work across two repos: gateway-side
infrastructure (signing key, IAM, route code) versus app-side
infrastructure (API Gateway, JWT authorizer config). The lambda-hw
terraform references the gateway's JWKS URL as a hardcoded HTTPS string,
not as a cross-repo IaC dependency. This is the right pattern: it keeps
each project's terraform self-contained and lets either side be replaced
without touching the other. **Worth keeping for any future
multi-app/multi-repo setup.**

### Lesson 5 — CSP is the *other* browser security mechanism

After CORS was correctly configured on API Gateway, the browser still
refused to send the request — not with a CORS error, but with a CSP
(Content Security Policy) violation:

> Refused to connect because it violates the document's Content Security Policy.

The gateway's nginx sets a strict `default-src 'self'` CSP, which
governs *outbound* connections via `connect-src` when not specified
explicitly. With no `connect-src` directive, the browser refused any
fetch to a different origin — including our API Gateway URL.

**Fix:** add `connect-src 'self' https://*.execute-api.us-east-1.amazonaws.com`
to the CSP header in `gateway/nginx.conf`. This is a gateway-level
concern: the same CSP serves every app, and any future app behind this
gateway that fetches API Gateway endpoints in us-east-1 is now covered.

**Mental model: the three browser security gates and what each governs:**

| Gate | What it does | Configured at |
|---|---|---|
| **Same-Origin Policy** | Default browser sandbox (built-in) | (browser; CORS+CSP relax it) |
| **CORS** | Cross-origin response readability — "can this page read what came back?" | The *responder* (API Gateway) |
| **CSP** | Outbound request permission — "can this page even attempt this request?" | The *page server* (nginx) |

Our chunk D needed both: API Gateway's CORS to allow the browser to
read responses, and nginx's CSP to allow the browser to send the
request in the first place. Hitting CORS and not CSP usually means
your same-origin assumptions broke; hitting CSP without CORS means
the browser rejected the request before any network attempt.

When debugging "TypeError: Failed to fetch" with no other context,
check both — the order in the browser is CSP first (request blocked
outright), then CORS (request sent, response withheld).
