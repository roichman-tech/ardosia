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

-- postgres (the role that applies migrations and seeds) is NOT a
-- superuser on Supabase, so it cannot `SET ROLE ardosia_app` unless it
-- is a member of the role. The seed adopts ardosia_app to exercise RLS
-- as the app would; grant the membership so that path is permitted.
-- Mirrors how Supabase grants anon/authenticated to the authenticator.
GRANT ardosia_app TO postgres;

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

-- auth.jwt() lives in the auth schema (owned by supabase_admin), which
-- postgres cannot grant on — so granting auth access to ardosia_app
-- directly is impossible in every environment (migrations run as
-- postgres). Instead current_tenant_id() below is SECURITY DEFINER:
-- it executes as its owner (postgres), which reaches auth via its
-- inherited membership in the standard Supabase roles. The app role
-- only needs EXECUTE on the function, not the auth schema.

-- ------------------------------------------------------------
-- current_tenant_id() — wrapper pattern, leg 2 added.
-- JWT claim wins when present; otherwise the per-transaction
-- app.tenant_id set by the backend. Returns NULL when neither
-- is present (RLS then matches nothing — fail closed).
--
-- NULLIF guards the '' a rolled-back set_config can leave behind;
-- missing_ok = true makes an unset GUC return NULL, not error.
--
-- SECURITY DEFINER (owner: postgres) so the callers — ardosia_app and
-- the standard RLS roles — need no auth-schema grants of their own.
-- auth.jwt() merely reads the per-request `request.jwt.claims` GUC, so
-- running as the definer does not change which claims are seen. The
-- definer context also lets the tenant_user lookup bypass that table's
-- RLS, which is what we want: the lookup is already scoped to the
-- caller's own JWT sub, and reading it via current_tenant_id() inside
-- tenant_user's own policy would otherwise recurse.
--
-- search_path is pinned and every object fully schema-qualified, the
-- standard hardening for SECURITY DEFINER against search_path capture.
--
-- Step-7 note (RLS policies): tenant_user's own policy must NOT
-- use current_tenant_id() — that recurses. Bind it directly to
-- auth_user_id = auth.jwt() ->> 'sub' instead.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_tenant_id()
  RETURNS uuid LANGUAGE sql STABLE
  SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT tu.tenant_id
       FROM public.tenant_user tu
      WHERE tu.auth_user_id = (auth.jwt() ->> 'sub')
        AND tu.deleted_at IS NULL
      LIMIT 1),
    NULLIF(current_setting('app.tenant_id', true), '')::uuid
  )
$$;
