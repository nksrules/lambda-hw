# Stage 0 — Skeleton

**Goal:** A Flask "shim" app registered behind the Sastry Apps gateway at
`/app/lambda-hw/`, with no AWS Lambda involvement yet. Prove the front-door
plumbing works before adding any Lambda machinery.

## Decisions

### D0.1 — Use the existing gateway app pattern (Flask + gunicorn + systemd)

We register lambda-hw the same way as `reimbursements`: Flask app at
`/opt/apps/lambda-hw`, registered via `add-app.sh`, served by gunicorn on
`127.0.0.1:8011`, fronted by nginx with auth via `auth_request`.

**Alternatives considered:**

- **Static-only behind nginx.** No Flask process. Smaller surface area, but
  would have required modifying `add-app.sh` and `generate-app-locations.py` in
  the gateway repo. We'll explore this in Stage 2 as a side-by-side comparison.
- **Skip the gateway entirely (S3 + CloudFront).** Loses gateway session
  integration, which is exactly what makes Stage 1's auth story easy. Forces a
  Cognito decision before we're ready.

**Why this:** minimum disruption to the gateway, the Flask shim is ~50 lines,
and it gives us a place to put server-side glue when we need it (e.g., the
SigV4 caller in Stage 1).

### D0.2 — Port 8011

Reimbursements is on 8010; we picked the next free port. No deeper reason.
Documented in `add-app.sh` invocation.

### D0.3 — Standalone mode honored from day one

`STANDALONE=1` (or `python3 app.py` directly) makes `get_user()` return a fake
user and switches templates to use `<base href="/">` plus local CSS fallbacks.
This pays for itself the first time you want to iterate on a template without
SSHing.

## What we did NOT do (intentionally)

- **No `/api/...` routes yet.** Stage 1 adds the first one.
- **No AWS dependencies in `requirements.txt`.** boto3 lands in Stage 1.
- **No data storage.** Nothing to persist yet.

## Open items / future revisits

- The fallback CSS files in `static/` (`anthropic-theme.css`, `gateway.css`)
  will drift from the gateway's canonical copies over time. The app-guide
  documents how to refresh them; this isn't a Stage 0 problem.
