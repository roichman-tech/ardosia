-- ============================================================
-- ARDOSIA — migration 0003
-- Composite tenant FKs + RLS enable/FORCE on every table
-- ============================================================
-- Turns the schema's tenant-isolation INTENTIONS (0001) into
-- DB-enforced INVARIANTS. 0001 stays verbatim (it mirrors the
-- design doc); this migration hardens it.
--
-- Problem 1 — denormalized tenant_id is convention-only.
--   Single-column FKs let a child with tenant_id = A reference a
--   parent owned by tenant B (e.g. a feature pointing at another
--   tenant's product). RLS WITH CHECK only validates the child's
--   OWN tenant_id, and FKs are enforced internally with RLS
--   bypassed — so nothing catches the cross-tenant parent.
--   Fix: composite FKs (tenant_id, <parent_id>) -> parent
--   (tenant_id, id). The parent row must share the child's tenant,
--   enforced by the engine, RLS or not.
--
-- Problem 2 — RLS in 0001 is entirely commented out.
--   Fix: ENABLE + FORCE row level security on EVERY table via a
--   loop (so no future table escapes by omission) and attach
--   tenant-scoped policies. FORCE means even a table owner that is
--   not a superuser is subject to RLS; superusers / BYPASSRLS roles
--   (postgres, service_role) still bypass, so migrations and seeds
--   are unaffected. The app role (ardosia_app, NOBYPASSRLS) is the
--   one these bind to.
--
-- OPERATIONAL NOTE — tenant provisioning runs as service_role.
--   With FORCE RLS + tenant_self_isolation, ardosia_app CANNOT
--   insert a brand-new tenant: at signup current_tenant_id() is
--   still NULL (no tenant_user row yet, app.tenant_id unset), so the
--   WITH CHECK on the INSERT fails. This is correct steady-state
--   behavior. Tenant + first tenant_user creation therefore goes
--   through a SEPARATE provisioning path on service_role
--   (BYPASSRLS), NOT the default Drizzle/ardosia_app connection.
--   Decision: dedicated service_role onboarding route.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Composite tenant FKs
-- ------------------------------------------------------------
-- 1a. UNIQUE (tenant_id, id) on every referenced parent. id is
--     already the PK (hence unique), but a composite FK must
--     reference a unique constraint over EXACTLY its target
--     columns. category and tag are included here even though the
--     task's parent list omitted them — product_category and
--     product_tag take composite FKs to them, which is impossible
--     without this constraint.
ALTER TABLE product        ADD CONSTRAINT uq_product_tenant_id        UNIQUE (tenant_id, id);
ALTER TABLE feature        ADD CONSTRAINT uq_feature_tenant_id        UNIQUE (tenant_id, id);
ALTER TABLE category       ADD CONSTRAINT uq_category_tenant_id       UNIQUE (tenant_id, id);
ALTER TABLE tag            ADD CONSTRAINT uq_tag_tenant_id            UNIQUE (tenant_id, id);
ALTER TABLE checkout_event ADD CONSTRAINT uq_checkout_event_tenant_id UNIQUE (tenant_id, id);

-- 1b. Drop the single-column FKs (PG-generated <table>_<col>_fkey
--     names) and replace each with a tenant-composite FK. The
--     separate tenant_id -> tenant(id) FK on each child is kept;
--     these are additional, narrower constraints.

-- product_image -> product
ALTER TABLE product_image DROP CONSTRAINT IF EXISTS product_image_product_id_fkey;
ALTER TABLE product_image
  ADD CONSTRAINT product_image_tenant_product_fkey
  FOREIGN KEY (tenant_id, product_id) REFERENCES product (tenant_id, id) ON DELETE CASCADE;

-- feature -> product
ALTER TABLE feature DROP CONSTRAINT IF EXISTS feature_product_id_fkey;
ALTER TABLE feature
  ADD CONSTRAINT feature_tenant_product_fkey
  FOREIGN KEY (tenant_id, product_id) REFERENCES product (tenant_id, id) ON DELETE CASCADE;

-- option -> feature
ALTER TABLE option DROP CONSTRAINT IF EXISTS option_feature_id_fkey;
ALTER TABLE option
  ADD CONSTRAINT option_tenant_feature_fkey
  FOREIGN KEY (tenant_id, feature_id) REFERENCES feature (tenant_id, id) ON DELETE CASCADE;

-- product_category -> product (+ category)
ALTER TABLE product_category DROP CONSTRAINT IF EXISTS product_category_product_id_fkey;
ALTER TABLE product_category DROP CONSTRAINT IF EXISTS product_category_category_id_fkey;
ALTER TABLE product_category
  ADD CONSTRAINT product_category_tenant_product_fkey
  FOREIGN KEY (tenant_id, product_id) REFERENCES product (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE product_category
  ADD CONSTRAINT product_category_tenant_category_fkey
  FOREIGN KEY (tenant_id, category_id) REFERENCES category (tenant_id, id) ON DELETE CASCADE;

-- product_tag -> product (+ tag)
ALTER TABLE product_tag DROP CONSTRAINT IF EXISTS product_tag_product_id_fkey;
ALTER TABLE product_tag DROP CONSTRAINT IF EXISTS product_tag_tag_id_fkey;
ALTER TABLE product_tag
  ADD CONSTRAINT product_tag_tenant_product_fkey
  FOREIGN KEY (tenant_id, product_id) REFERENCES product (tenant_id, id) ON DELETE CASCADE;
ALTER TABLE product_tag
  ADD CONSTRAINT product_tag_tenant_tag_fkey
  FOREIGN KEY (tenant_id, tag_id) REFERENCES tag (tenant_id, id) ON DELETE CASCADE;

-- checkout_event_item -> checkout_event
-- checkout_event_id gets the tenant-composite FK like every other
-- parent link. product_id is DELIBERATELY left as a single-column
-- ON DELETE SET NULL "best-effort" link and is NOT tenant-validated.
--   Rationale (not a limitation): a composite (tenant_id, product_id)
--   FK with PG15+ column-level ON DELETE SET NULL (product_id) is
--   technically possible — it would null only product_id and keep
--   tenant_id. We choose NOT to add it: this link is a disposable
--   convenience pointer, the row's product_name / unit_price_cents
--   SNAPSHOT is the source of truth, and RLS already scopes every
--   read by tenant_id. The (tiny) residual is that the nullable
--   pointer could reference another tenant's product id; it is never
--   read cross-tenant and carries no authoritative data.
ALTER TABLE checkout_event_item DROP CONSTRAINT IF EXISTS checkout_event_item_checkout_event_id_fkey;
ALTER TABLE checkout_event_item
  ADD CONSTRAINT checkout_event_item_tenant_event_fkey
  FOREIGN KEY (tenant_id, checkout_event_id) REFERENCES checkout_event (tenant_id, id) ON DELETE CASCADE;

-- ------------------------------------------------------------
-- 2. uq_product_image_position — confirm hard-delete model
-- ------------------------------------------------------------
-- Decision: product_image is hard-delete; storage_key is the only
-- thing that matters. 0001 already shipped it WITHOUT deleted_at and
-- with a non-partial DEFERRABLE INITIALLY DEFERRED unique constraint
-- (the form that lets a position swap commit in one tx and that a
-- partial index could not be). So there is nothing to change — this
-- DROP ... IF EXISTS only guards against drift and documents intent.
ALTER TABLE product_image DROP COLUMN IF EXISTS deleted_at;

-- ------------------------------------------------------------
-- 3. RLS — enable + FORCE on every table, then attach policies
-- ------------------------------------------------------------
-- 3a. ENABLE + FORCE on every base table in public, via a loop so
--     no current or future table escapes by omission. A table with
--     FORCE RLS and no policy denies all rows to non-bypass roles
--     (fail closed) — the safe default.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.table_name);
    EXECUTE format('ALTER TABLE public.%I FORCE  ROW LEVEL SECURITY', r.table_name);
  END LOOP;
END $$;

-- 3b. Standard tenant-isolation policy on every table that carries a
--     tenant_id column, EXCEPT tenant_user (handled separately to
--     avoid RLS recursion). tenant has no tenant_id column so it is
--     not matched here either. Policy uses the initplan form
--     (SELECT current_tenant_id()) per Supabase perf guidance: the
--     function is evaluated once per query, not once per row.
--
--     FOR ALL is intentional. Immutability of the checkout_event*
--     log is NOT enforced here — it comes from migration 0002's
--     REVOKE UPDATE, DELETE ON checkout_event, checkout_event_item
--     FROM ardosia_app. These policies only scope rows by tenant.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE c.table_schema = 'public'
      AND c.column_name  = 'tenant_id'
      AND t.table_type   = 'BASE TABLE'
      AND c.table_name  <> 'tenant_user'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I',
                   r.table_name || '_tenant_isolation', r.table_name);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL '
      || 'USING (tenant_id = (SELECT current_tenant_id())) '
      || 'WITH CHECK (tenant_id = (SELECT current_tenant_id()))',
      r.table_name || '_tenant_isolation', r.table_name);
  END LOOP;
END $$;

-- 3c. tenant — distinct policy keyed on its own id.
DROP POLICY IF EXISTS tenant_self_isolation ON tenant;
CREATE POLICY tenant_self_isolation ON tenant
  FOR ALL
  USING (id = (SELECT current_tenant_id()))
  WITH CHECK (id = (SELECT current_tenant_id()));

-- 3d. tenant_user — bound DIRECTLY to the auth provider identity,
--     NOT to current_tenant_id(): current_tenant_id() reads
--     tenant_user, so a policy referencing it would recurse. A user
--     sees only their own access rows; this is also exactly what
--     current_tenant_id() needs to resolve the JWT path. The public
--     catalog path (no JWT) sees nothing here and doesn't need to —
--     it resolves the tenant from app.tenant_id instead.
--
--     The JWT sub is read DIRECTLY from the request.jwt.claims GUC,
--     NOT via auth.jwt(): this policy runs in the invoker's context,
--     and ardosia_app (NOBYPASSRLS) has no access to the auth schema
--     (SET ROLE ardosia_app; SELECT auth.jwt() -> permission denied
--     for schema auth), so an auth.jwt() call would break the first
--     SELECT the app makes against tenant_user. auth.jwt() is just a
--     wrapper over this GUC; reading the GUC needs no schema grant.
--     (current_tenant_id() in 0002 stays SECURITY DEFINER — that is
--     what gives IT auth-schema access; only this invoker-context
--     policy must avoid auth.jwt().)
DROP POLICY IF EXISTS tenant_user_self_access ON tenant_user;
CREATE POLICY tenant_user_self_access ON tenant_user
  FOR ALL
  USING (auth_user_id = (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))
  WITH CHECK (auth_user_id = (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'));
  