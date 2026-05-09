-- Stage 6 chunk B — click_audit table + dedicated user for the audit consumer.
--
-- Run as dbadmin (master user) against the lambda_hw database.
-- This file:
--   1. Creates the click_audit table (append-only audit records).
--   2. Creates the lambda_hw_audit Postgres user with rds_iam (IAM auth).
--   3. Grants INSERT, SELECT only — no UPDATE, no DELETE. Audit records
--      once written cannot be tampered with by the audit consumer.
--   4. Creates an index on (sub, clicked_at DESC) for "recent clicks
--      by user" queries.
--
-- One-shot script; not idempotent (CREATE USER fails if it exists).
-- Future schema changes go in 0003_*, etc.
--
-- How to apply (same pattern as 0001):
--   # From operator laptop:
--   scp migrations/0002_click_audit.sql ec2-user@slim.ksastry.com:/tmp/
--
--   # On laptop, fetch master password:
--   SECRET_ARN=$(cd ~/gateway/terraform/data-platform && \
--       terraform output -raw master_user_secret_arn)
--   aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
--       --query SecretString --output text | jq -r .password
--
--   # SSH to slim:
--   ssh ec2-user@slim.ksastry.com
--
--   # On slim — connect to lambda_hw (NOT postgres) and run:
--   psql -h <rds-direct-endpoint> -U dbadmin -d lambda_hw \
--        -f /tmp/0002_click_audit.sql

\connect lambda_hw

-- ---------------------------------------------------------------------------
-- 1. The click_audit table
-- ---------------------------------------------------------------------------
-- Primary key is request_id — Lambda's per-invocation UUID. Used for
-- idempotency: SQS at-least-once delivery means we may see the same
-- message twice; INSERT ... ON CONFLICT (request_id) DO NOTHING swallows
-- the dup at the DB level.

CREATE TABLE IF NOT EXISTS click_audit (
    request_id    TEXT        PRIMARY KEY,
    sub           TEXT        NOT NULL,
    username      TEXT        NOT NULL,
    clicked_at    TIMESTAMPTZ NOT NULL,
    source        TEXT        NOT NULL,
    received_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Lookup pattern: "show me user X's recent clicks." Probably overkill
-- at our scale but it's the right index if we ever query this way.
CREATE INDEX IF NOT EXISTS idx_click_audit_sub_clicked_at
    ON click_audit (sub, clicked_at DESC);

-- ---------------------------------------------------------------------------
-- 2. Application user for the audit consumer Lambda
-- ---------------------------------------------------------------------------
-- Separate from lambda_hw_app (which owns user_visits) to limit blast
-- radius: a compromise of the audit consumer can read/write only
-- click_audit, not user_visits.

CREATE USER lambda_hw_audit;
GRANT rds_iam TO lambda_hw_audit;

-- Database-level: allow connection
GRANT CONNECT ON DATABASE lambda_hw TO lambda_hw_audit;

-- Schema-level: allow finding objects in the public schema
GRANT USAGE ON SCHEMA public TO lambda_hw_audit;

-- ---------------------------------------------------------------------------
-- 3. Table-level grants — APPEND-ONLY by design (D6.10)
-- ---------------------------------------------------------------------------
-- INSERT: write new audit records (the consumer's main job)
-- SELECT: read records (for the consumer's own ON CONFLICT idempotency
--         check; also useful for ad-hoc audit queries from this user)
--
-- DELIBERATELY NOT GRANTED:
--   UPDATE — audit records are immutable once written
--   DELETE — audit records are append-only; cleanup happens via DBA
--   TRUNCATE — same reasoning
--   REFERENCES — no foreign keys originating from this user's tables
--   TRIGGER — out of scope for the audit consumer

GRANT SELECT, INSERT ON click_audit TO lambda_hw_audit;
