-- ============================================================
-- ARDOSIA — migration 0002
-- Restricted app role + COALESCE current_tenant_id()
-- (stack-decision §1 — mandated "on day 1")
-- ============================================================
-- * ardosia_app is the role the application connects with
--   (Drizzle → Supabase pooler). NOT the service role: it is
--   subject to RLS (NOBYPASSRLS), owns no tables, and holds only
--   DML privileges — so policies actually bind it.
--   The password is never committed; set it out-of-band:
--     ALTER ROLE ardosia_app PASSWORD '<from secrets manager>';
-- * current_tenant_id() now resolves the tenant from EITHER:
--     1. the Clerk JWT claim (Supabase third-party auth path), or
--     2. current_setting('app.tenant_id') — set per transaction by
--        the backend on the public catalog path, which carries no JWT:
--          SELECT set_config('app.tenant_id', '<uuid>', true);
-- ============================================================

-- ------------------------------------------------------------
-- Restricted role (CREATE ROLE has no IF NOT EXISTS)
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ardosia_app') THEN
    CREATE ROLE ardosia_app
      LOGIN
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      NOBYPASSRLS;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO ardosia_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ardosia_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ardosia_app;
-- No sequences in schema v1 (uuid PKs), but cover future ones:
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ardosia_app;

-- Objects created by future migrations (run as postgres) inherit grants
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ardosia_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO ardosia_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO ardosia_app;

--- Checkout event tables are immutable logs, so we revoke update and delete operations
REVOKE UPDATE, DELETE ON checkout_event, checkout_event_item FROM ardosia_app;

-- auth.jwt() lives in the auth schema (Supabase); current_tenant_id()
-- calls it, so the app role needs to reach it.
GRANT USAGE ON SCHEMA auth TO ardosia_app;
GRANT EXECUTE ON FUNCTION auth.jwt() TO ardosia_app;

-- ------------------------------------------------------------
-- current_tenant_id() — wrapper pattern, leg 2 added.
-- JWT claim wins when present; otherwise the per-transaction
-- app.tenant_id set by the backend. Returns NULL when neither
-- is present (RLS then matches nothing — fail closed).
--
-- NULLIF guards the '' a rolled-back set_config can leave behind;
-- missing_ok = true makes an unset GUC return NULL, not error.
--
-- Step-7 note (RLS policies): tenant_user's own policy must NOT
-- use current_tenant_id() — that recurses. Bind it directly to
-- auth_user_id = auth.jwt() ->> 'sub' instead.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_tenant_id()
  RETURNS uuid LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (SELECT tu.tenant_id
       FROM tenant_user tu
      WHERE tu.auth_user_id = (auth.jwt() ->> 'sub')
        AND tu.deleted_at IS NULL
      LIMIT 1),
    NULLIF(current_setting('app.tenant_id', true), '')::uuid
  )
$$;
