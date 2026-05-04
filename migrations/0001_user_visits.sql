-- Stage 3 chunk D — initial schema for lambda-hw.
--
-- Run as dbadmin (master user) against the `postgres` maintenance
-- database. This file:
--   1. Creates the lambda_hw database.
--   2. Creates the lambda_hw_app Postgres user with rds_iam (IAM auth).
--   3. Grants the user database-level + schema-level + table-level
--      permissions, scoped to exactly what the Lambda needs.
--   4. Creates the user_visits table (per-user click counter).
--
-- One-shot script; not idempotent (CREATE DATABASE has no IF NOT
-- EXISTS in Postgres). Re-running fails on the first statement.
-- Future schema changes go in 0002_*, 0003_*, etc.
--
-- How to apply:
--   # From operator laptop:
--   scp migrations/0001_user_visits.sql ec2-user@slim.ksastry.com:/tmp/
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
--   # On slim (paste password when prompted):
--   psql -h <rds-direct-endpoint> -U dbadmin -d postgres \
--        -f /tmp/0001_user_visits.sql

-- ---------------------------------------------------------------------------
-- 1. Create the application's database
-- ---------------------------------------------------------------------------

CREATE DATABASE lambda_hw;

\connect lambda_hw

-- ---------------------------------------------------------------------------
-- 2. Application user with IAM-auth capability
-- ---------------------------------------------------------------------------
-- CREATE USER (vs CREATE ROLE) implicitly grants LOGIN — required for the
-- user to authenticate at all.
--
-- GRANT rds_iam TO X — RDS-specific role created automatically when IAM
-- database authentication is enabled on the instance. Membership in
-- this role is what tells RDS "this user is allowed to authenticate
-- via IAM tokens." Without it, even a correct IAM token gets rejected.

CREATE USER lambda_hw_app;
GRANT rds_iam TO lambda_hw_app;

-- Database-level: allow connection
GRANT CONNECT ON DATABASE lambda_hw TO lambda_hw_app;

-- Schema-level: allow finding objects in the public schema
GRANT USAGE ON SCHEMA public TO lambda_hw_app;

-- ---------------------------------------------------------------------------
-- 3. The user_visits table — per-user click counter
-- ---------------------------------------------------------------------------
-- Primary key is `sub` (Cognito UUID, stable forever per D3.5 / B1a).
-- username is duplicated for human-readable queries from CloudWatch
-- Insights or psql, but not authoritative — it can be renamed in the
-- gateway DB and we update it on the next click via the upsert.

CREATE TABLE IF NOT EXISTS user_visits (
    sub          TEXT        PRIMARY KEY,
    username     TEXT        NOT NULL,
    click_count  INTEGER     NOT NULL DEFAULT 0,
    first_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table-level: CRUD permissions for the app. No TRUNCATE, no DDL.
GRANT SELECT, INSERT, UPDATE, DELETE ON user_visits TO lambda_hw_app;
