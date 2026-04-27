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

### D2.A2 — Algorithm: ES256 (ECDSA P-256)

Asymmetric so API Gateway can verify without the signing key. ES256 chosen
over RS256 for a learning-project reason: it's the modern default, has
smaller signatures (~64 bytes vs ~256), faster signing, and it's worth
internalizing. RS256 would also work and has slightly more universal tooling.

**Symmetric (HS256) is structurally wrong here:** API Gateway would need
the signing key to validate, defeating the whole asymmetric-trust model.
The auth-service alone holds the private key; API Gateway only needs the
public key.

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
private keys shouldn't traverse IaC. One-time setup script:

```bash
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/jwt-priv.pem
openssl pkey -in /tmp/jwt-priv.pem -pubout -out /tmp/jwt-pub.pem
KID=$(openssl dgst -sha256 /tmp/jwt-pub.pem | awk '{print substr($2,1,16)}')
SECRET_JSON=$(jq -n \
    --rawfile priv /tmp/jwt-priv.pem \
    --rawfile pub  /tmp/jwt-pub.pem \
    --arg kid "$KID" \
    '{algorithm:"ES256", kid:$kid, private_key:$priv, public_key:$pub}')
aws secretsmanager create-secret --name gateway/jwt-signing-key \
    --description "ES256 keypair for signing gateway-issued JWTs." \
    --secret-string "$SECRET_JSON"
shred -u /tmp/jwt-priv.pem /tmp/jwt-pub.pem 2>/dev/null \
    || rm -f /tmp/jwt-priv.pem /tmp/jwt-pub.pem
```

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

### D2.A4 — JWKS at `/.well-known/jwks.json` on the auth-service

Standard well-known location. The route is a Flask handler that:

1. Reads the cached public key from in-memory keypair (loaded once from
   Secrets Manager at startup).
2. Converts PEM to JWK format (in-memory math — base64url encoding of
   the EC point's X/Y coordinates).
3. Returns `{"keys": [{kty, crv, x, y, use, alg, kid}]}`.

**No file ever written.** Computation is microseconds; result is cached
via `lru_cache` and served with `Cache-Control: public, max-age=300`.
API Gateway also internally caches JWKS for ~10 minutes, so traffic to
this endpoint stays minimal regardless of inbound API request volume.

The `keys` array is plural specifically to support rotation overlap
windows: during rotation we publish both old and new public keys
simultaneously, distinguished by `kid`.

This endpoint is **public** — it must be reachable without a session
cookie because external services (API Gateway, eventually iOS) need to
fetch it. Will be configured in nginx to bypass `auth_request`.

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

### D2.D2 — Keep Stage 1 server-proxy path side-by-side

Two buttons on the lambda-hw page: **Call via Flask (Stage 1)** and
**Call via API Gateway (Stage 2)**. Both call the same Lambda, both
display response + measured round-trip time. The whole point is to
feel the contrast — different auth model, different network path,
different observable latency profile.

We can clean up later by removing Stage 1's button when it's no longer
useful. For now, both stay.

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
