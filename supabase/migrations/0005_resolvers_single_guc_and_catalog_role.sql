-- ============================================================
-- ARDOSIA — migration 0005
-- Tenant-resolution bootstrap + single-GUC model (Design T) +
-- read-only catalog role. Closes schema-security-review findings
-- H-3, M-2 (seed), N-1, and resolves agenda item 2.
-- ============================================================
-- Forward-only. 0001–0004 stay verbatim.
--
-- WHY (H-3 — the bootstrap gap):
--   Every request must turn an UNTRUSTED identifier into a tenant_id
--   BEFORE any tenant context exists:
--     * dashboard: validated Clerk `sub`  -> tenant_user -> tenant_id
--     * catalog  : Host/slug              -> tenant      -> tenant_id
--   Under ardosia_app (NOBYPASSRLS, FORCE RLS) NEITHER lookup works:
--   the `tenant` policy needs current_tenant_id() (still NULL at
--   resolution time) and the `tenant_user` policy needs a JWT-claims
--   GUC Drizzle never sets. The two ad-hoc "fixes" each break an
--   invariant: resolving on service_role over-privileges the public
--   catalog path; feeding the raw slug/sub into a context GUC is the
--   client-influences-context failure the model forbids.
--   Fix: SECURITY DEFINER resolver functions that read the gated
--   tables as their owner (postgres), return ONLY the id, and filter
--   deleted_at. They map identifier -> id; they do NOT grant access
--   (access still requires the BFF to set app.tenant_id, INV-1).
--
-- WHY (Design T — single GUC):
--   The JWT leg of current_tenant_id() is dead on the Drizzle path
--   ([auth.third_party.clerk] is disabled and Drizzle never populates
--   request.jwt.claims). Rather than keep two mechanisms whose
--   live-ness is unclear, app.tenant_id becomes the SOLE RLS
--   mechanism for BOTH paths, set server-side post-validation. This
--   also removes current_tenant_id()'s SECURITY DEFINER + auth-schema
--   dependency — it is now a pure GUC read and a clean portability
--   seam.
--
-- WHY (N-1 — catalog role):
--   ardosia_app spans the anonymous catalog path AND the authenticated
--   owner dashboard; RLS isolates tenants but not authority-within-a-
--   tenant. A dedicated read-only ardosia_catalog (SELECT on catalog
--   tables + INSERT on checkout_event* only) makes a write bug on the
--   public internet path a denied-privilege error instead of a tenant-
--   data-integrity incident. The dashboard keeps ardosia_app.
-- ============================================================

-- ------------------------------------------------------------
-- 1. current_tenant_id() — single GUC leg (Design T).
--    Pure GUC read: no auth.jwt(), no tenant_user lookup, no
--    SECURITY DEFINER. Returns NULL when app.tenant_id is unset or
--    left '' by a rolled-back set_config -> RLS matches nothing
--    (fail closed). The initplan policy form (SELECT current_tenant_id())
--    keeps working unchanged.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_tenant_id()
  RETURNS uuid LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

-- ------------------------------------------------------------
-- 2. Resolver functions (bootstrap). SECURITY DEFINER (owner:
--    postgres) so they read their RLS-gated tables; search_path
--    pinned and every object fully schema-qualified (standard
--    SECURITY DEFINER hardening). Each returns only an id and filters
--    deleted_at (fail closed for unknown/deleted identifiers).
--
--    NOTE on resolve_tenant_for_user: callers MUST pass only a
--    VALIDATED Clerk sub (INV-1 extended to the argument). Mapping an
--    arbitrary sub -> tenant_id grants no access on its own: the app
--    role can already set app.tenant_id to any value, so isolation
--    rests entirely on the BFF setting it from a validated source.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_tenant_by_slug(p_slug text)
  RETURNS uuid LANGUAGE sql STABLE
  SECURITY DEFINER SET search_path = ''
AS $$
  SELECT t.id FROM public.tenant t
  WHERE t.slug = p_slug AND t.deleted_at IS NULL
$$;

CREATE OR REPLACE FUNCTION resolve_tenant_by_custom_domain(p_domain text)
  RETURNS uuid LANGUAGE sql STABLE
  SECURITY DEFINER SET search_path = ''
AS $$
  SELECT t.id FROM public.tenant t
  WHERE t.custom_domain = p_domain AND t.deleted_at IS NULL
$$;

CREATE OR REPLACE FUNCTION resolve_tenant_for_user(p_sub text)
  RETURNS uuid LANGUAGE sql STABLE
  SECURITY DEFINER SET search_path = ''
AS $$
  SELECT tu.tenant_id FROM public.tenant_user tu
  WHERE tu.auth_user_id = p_sub AND tu.deleted_at IS NULL
  LIMIT 1
$$;

-- Lock down EXECUTE: revoke the implicit PUBLIC grant, then grant
-- explicitly. ardosia_app (dashboard) gets all three; ardosia_catalog
-- (created below) gets only the public-identifier resolvers.
REVOKE EXECUTE ON FUNCTION resolve_tenant_by_slug(text)          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION resolve_tenant_by_custom_domain(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION resolve_tenant_for_user(text)         FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION resolve_tenant_by_slug(text)          TO ardosia_app;
GRANT  EXECUTE ON FUNCTION resolve_tenant_by_custom_domain(text) TO ardosia_app;
GRANT  EXECUTE ON FUNCTION resolve_tenant_for_user(text)         TO ardosia_app;

-- ------------------------------------------------------------
-- 3. ardosia_catalog — read-only public catalog role (N-1).
--    LOGIN (connects via the pooler), NOBYPASSRLS so the tenant
--    policies bind it. Owns nothing. Password set out-of-band:
--      ALTER ROLE ardosia_catalog PASSWORD '<from secrets manager>';
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ardosia_catalog') THEN
    CREATE ROLE ardosia_catalog
      LOGIN
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
      NOBYPASSRLS;
  END IF;
END $$;

-- Let postgres adopt the role so the seed can exercise RLS as it would
-- (mirrors GRANT ardosia_app TO postgres in 0002).
GRANT ardosia_catalog TO postgres;

GRANT USAGE ON SCHEMA public TO ardosia_catalog;

-- SELECT on the catalog read surface (branding + product graph).
-- Deliberately EXPLICIT (not ON ALL TABLES): least privilege is the
-- point of this role. A future catalog-readable table must be added
-- here; tenant_user, checkout_event*, and any owner-only table are
-- intentionally absent.
GRANT SELECT ON
  tenant, product, product_image, feature, option,
  category, tag, product_category, product_tag
  TO ardosia_catalog;

-- The one write the public path legitimately needs: append the
-- checkout snapshot. INSERT only — no SELECT on the log (the catalog
-- never reads it back), no UPDATE/DELETE anywhere.
GRANT INSERT ON checkout_event, checkout_event_item TO ardosia_catalog;

-- EXECUTE: the policies call current_tenant_id() during evaluation, so
-- the role needs it; plus the two public-identifier resolvers.
GRANT EXECUTE ON FUNCTION current_tenant_id()                   TO ardosia_catalog;
GRANT EXECUTE ON FUNCTION resolve_tenant_by_slug(text)          TO ardosia_catalog;
GRANT EXECUTE ON FUNCTION resolve_tenant_by_custom_domain(text) TO ardosia_catalog;

-- NOTE — RLS binding: the 0003/0004 policies carry no TO clause, so
-- they default to TO public and already bind ardosia_catalog. No new
-- policies are needed; the grants above only decide which COMMANDS the
-- role may attempt, and RLS then scopes the rows to current_tenant_id().
--
-- NOTE — future tables (INV-6): a migration adding a catalog-readable
-- table must GRANT SELECT on it to ardosia_catalog explicitly (there is
-- no ALTER DEFAULT PRIVILEGES for this role, by design — least
-- privilege over convenience).
