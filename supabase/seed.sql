-- ============================================================
-- ARDOSIA — seed.sql
-- Loaded after migrations on `supabase db reset`. Doubles as the
-- tenant-isolation regression test: the asserts below FAIL the
-- reset (and therefore CI) if the invariants from migrations
-- 0002/0003/0004 ever regress.
--
-- Two fake tenants, A and B. The negative asserts prove that the
-- DB itself — not application convention — prevents cross-tenant
-- references, cross-tenant reads, cross-tenant writes, tenant
-- takeover via tenant_user, and mutation of the immutable log.
--
-- CI NOTE: every assert signals failure via RAISE EXCEPTION, which
-- only aborts the run when the seed is executed with ON_ERROR_STOP=1.
-- `supabase db reset` sets this; any other invocation path MUST too,
-- or a broken invariant logs a notice and CI still goes green.
--
-- GUC HYGIENE: the app-role asserts set the tenant context with the
-- TRANSACTION-LOCAL form — `set_config(key, val, true)` + `SET LOCAL
-- ROLE` inside an explicit BEGIN/COMMIT. This mirrors the ONLY safe
-- backend pattern under a transaction-mode pooler: a session-level
-- `SET` would leak the tenant onto the next request that reuses the
-- pooled connection. Do not "simplify" these back to bare `SET`.
-- ============================================================

-- ------------------------------------------------------------
-- Fixtures (run as the seeding superuser → RLS bypassed)
-- ------------------------------------------------------------
-- The two SD§8 fake tenants, deliberately divergent so every E2 (catalog)
-- and E3 (cart) branch has data. The minimal isolation fixtures live here;
-- the rich catalog/cart fixtures that exercise the branches are appended at
-- the very bottom (after the asserts), so the count-bearing asserts run
-- against a controlled fixture and the catalog data cannot perturb them.
--   A — global price kill-switch OFF (show_product_prices = false), no
--       custom_domain (slug-routed), default branding.
--   B — prices ON with a per-product hide_price exception, custom_domain set
--       (host-routed), non-default accent + non-empty checkout template.
INSERT INTO tenant
  (id, name, slug, whatsapp_number, show_product_prices, custom_domain, accent_color, checkout_template) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Tenant A', 'tenant-a', '+5588900000001',
     false, NULL,                   '#0A0A0A', ''),
  ('22222222-2222-2222-2222-222222222222', 'Tenant B', 'tenant-b', '+5588900000002',
     true,  'loja.tenant-b.com.br', '#C2410C', 'Olá! Segue meu pedido pela Loja B:');

-- Membership rows: A owned by clerk_user_a, B owned by clerk_user_b.
INSERT INTO tenant_user (tenant_id, auth_user_id, role) VALUES
  ('11111111-1111-1111-1111-111111111111', 'clerk_user_a', 'owner'),
  ('22222222-2222-2222-2222-222222222222', 'clerk_user_b', 'owner');

INSERT INTO product (id, tenant_id, name, price_cents) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Product A1', 1000),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Product B1', 2000);

-- Two images on Product A1 for the position-swap test.
INSERT INTO product_image (id, tenant_id, product_id, storage_key, position) VALUES
  ('aaaaaaaa-1111-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'a/img-0.jpg', 0),
  ('aaaaaaaa-1111-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'a/img-1.jpg', 1);

-- Parents in BOTH tenants so every composite FK edge can be exercised
-- with a foreign-tenant parent (ASSERT 1). A-side parents pair with a
-- B-side product to isolate the "->product" edge of the junctions;
-- B-side parents pair with the A-side product to isolate the other edge.
INSERT INTO feature (id, tenant_id, product_id, name) VALUES
  ('aaaaaaaa-2222-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'Feature A'),
  ('bbbbbbbb-2222-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'Feature B');
INSERT INTO category (id, tenant_id, name) VALUES
  ('aaaaaaaa-3333-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Category A'),
  ('bbbbbbbb-3333-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Category B');
INSERT INTO tag (id, tenant_id, name) VALUES
  ('aaaaaaaa-4444-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Tag A'),
  ('bbbbbbbb-4444-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Tag B');
INSERT INTO checkout_event (id, tenant_id, message_text) VALUES
  ('bbbbbbbb-5555-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'order B');

-- ============================================================
-- ASSERT 1 — every composite tenant FK blocks a cross-tenant parent
-- reference. One sub-test per FK EDGE (8 total): a child owned by
-- tenant A whose parent id belongs to tenant B must be rejected by the
-- engine. Runs as the seeding superuser, so RLS is bypassed — this
-- isolates the FOREIGN KEY behaviour, exactly the gap convention-only
-- tenant_id left open. A failure on ANY edge fails the reset.
--   const A = 1111…, B = 2222…; A-product = aaaa…0001, B-product =
--   bbbb…0001, plus the per-type parents seeded above.
-- ============================================================
DO $$
DECLARE
  A constant uuid := '11111111-1111-1111-1111-111111111111';
BEGIN
  -- 1. product_image -> product
  BEGIN
    INSERT INTO product_image (tenant_id, product_id, storage_key, position)
    VALUES (A, 'bbbbbbbb-0000-0000-0000-000000000001', 'x/cross.jpg', 7);
    RAISE EXCEPTION 'ISOLATION FAIL [product_image->product]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 2. feature -> product
  BEGIN
    INSERT INTO feature (tenant_id, product_id, name)
    VALUES (A, 'bbbbbbbb-0000-0000-0000-000000000001', 'x');
    RAISE EXCEPTION 'ISOLATION FAIL [feature->product]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 3. option -> feature
  BEGIN
    INSERT INTO option (tenant_id, feature_id, name)
    VALUES (A, 'bbbbbbbb-2222-0000-0000-000000000001', 'x');
    RAISE EXCEPTION 'ISOLATION FAIL [option->feature]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 4. product_category -> product (foreign product, own category)
  BEGIN
    INSERT INTO product_category (tenant_id, product_id, category_id)
    VALUES (A, 'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-3333-0000-0000-000000000001');
    RAISE EXCEPTION 'ISOLATION FAIL [product_category->product]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 5. product_category -> category (own product, foreign category)
  BEGIN
    INSERT INTO product_category (tenant_id, product_id, category_id)
    VALUES (A, 'aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-3333-0000-0000-000000000001');
    RAISE EXCEPTION 'ISOLATION FAIL [product_category->category]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 6. product_tag -> product (foreign product, own tag)
  BEGIN
    INSERT INTO product_tag (tenant_id, product_id, tag_id)
    VALUES (A, 'bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-4444-0000-0000-000000000001');
    RAISE EXCEPTION 'ISOLATION FAIL [product_tag->product]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 7. product_tag -> tag (own product, foreign tag)
  BEGIN
    INSERT INTO product_tag (tenant_id, product_id, tag_id)
    VALUES (A, 'aaaaaaaa-0000-0000-0000-000000000001', 'bbbbbbbb-4444-0000-0000-000000000001');
    RAISE EXCEPTION 'ISOLATION FAIL [product_tag->tag]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  -- 8. checkout_event_item -> checkout_event
  BEGIN
    INSERT INTO checkout_event_item (tenant_id, checkout_event_id, product_name, quantity)
    VALUES (A, 'bbbbbbbb-5555-0000-0000-000000000001', 'snap', 1);
    RAISE EXCEPTION 'ISOLATION FAIL [checkout_event_item->checkout_event]: cross-tenant insert allowed';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;

  RAISE NOTICE 'OK: all 8 composite FK edges blocked cross-tenant references';
END $$;

-- ============================================================
-- ASSERT 2 — every base table has RLS enabled AND forced.
-- ============================================================
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(relname, ', ' ORDER BY relname) INTO bad
  FROM pg_class
  WHERE relnamespace = 'public'::regnamespace
    AND relkind = 'r'
    AND (NOT relrowsecurity OR NOT relforcerowsecurity);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: tables missing RLS/FORCE: %', bad;
  END IF;
  RAISE NOTICE 'OK: all public tables have RLS enabled + forced';
END $$;

-- ============================================================
-- ASSERT 3 + 4 — read and write isolation under the app role,
-- public-catalog (no-JWT) path. Adopt tenant A via the
-- per-transaction GUC the backend uses on the catalog path. The
-- whole block is one transaction: set_config(...,true) and SET LOCAL
-- revert at COMMIT, so nothing leaks to later asserts.
-- ============================================================
BEGIN;
SELECT set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE ardosia_app;

-- ASSERT 3 — cross-tenant SELECT returns 0 (policy USING clause).
DO $$
BEGIN
  -- Count-agnostic: the bottom of this file seeds many catalog products for
  -- BOTH tenants. The isolation claim is "everything visible belongs to A,
  -- and A sees at least one" — independent of how many rows the seed grows.
  IF EXISTS (SELECT 1 FROM product
               WHERE tenant_id <> '11111111-1111-1111-1111-111111111111') THEN
    RAISE EXCEPTION 'ISOLATION FAIL: tenant A saw a product from another tenant under RLS';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM product) THEN
    RAISE EXCEPTION 'ISOLATION FAIL: tenant A should see its own product(s)';
  END IF;
  RAISE NOTICE 'OK: RLS confines SELECT to the current tenant';
END $$;

-- ASSERT 4 — cross-tenant WRITE is rejected (policy WITH CHECK).
-- An RLS WITH CHECK violation is SQLSTATE 42501 -> insufficient_privilege.
DO $$
BEGIN
  BEGIN
    INSERT INTO product (tenant_id, name, price_cents)
    VALUES ('22222222-2222-2222-2222-222222222222', 'Smuggled into B', 999);
    RAISE EXCEPTION 'ISOLATION FAIL: cross-tenant product insert was allowed';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'OK: WITH CHECK blocked cross-tenant write';
  END;
END $$;

COMMIT;

-- ============================================================
-- ASSERT 5 — checkout_event* is immutable to the app role.
-- Twin guard: (a) the UPDATE/DELETE privilege is revoked (0002), and
-- (b) post-0004 there is no UPDATE/DELETE POLICY either, so mutation
-- is denied even if a future migration re-grants the privilege.
-- Table-level privilege is checked before RLS, so these fail with
-- the log empty — no fixture required. Denied -> 42501.
-- ============================================================
BEGIN;
SET LOCAL ROLE ardosia_app;
DO $$
BEGIN
  BEGIN
    UPDATE checkout_event SET message_text = 'tampered';
    RAISE EXCEPTION 'ISOLATION FAIL: ardosia_app could UPDATE the checkout log';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'OK: checkout_event is UPDATE-protected from the app role';
  END;

  BEGIN
    DELETE FROM checkout_event_item;
    RAISE EXCEPTION 'ISOLATION FAIL: ardosia_app could DELETE from the checkout log';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'OK: checkout_event_item is DELETE-protected from the app role';
  END;
END $$;
COMMIT;

-- ============================================================
-- ASSERT 6 — image position swap commits in a single transaction.
-- The DEFERRABLE INITIALLY DEFERRED unique constraint must tolerate
-- the transient duplicate (both rows briefly at position 1), with
-- the check deferred to the end of the transaction.
-- ============================================================
DO $$
BEGIN
  UPDATE product_image SET position = 1 WHERE id = 'aaaaaaaa-1111-0000-0000-000000000000';
  UPDATE product_image SET position = 0 WHERE id = 'aaaaaaaa-1111-0000-0000-000000000001';
  IF (SELECT position FROM product_image WHERE id = 'aaaaaaaa-1111-0000-0000-000000000000') <> 1
  OR (SELECT position FROM product_image WHERE id = 'aaaaaaaa-1111-0000-0000-000000000001') <> 0 THEN
    RAISE EXCEPTION 'ISOLATION FAIL: image position swap did not persist';
  END IF;
  RAISE NOTICE 'OK: image position swap committed in a single tx';
END $$;

-- ============================================================
-- ASSERT 7 — tenant takeover via tenant_user is blocked (FIX C-1).
-- Authenticated as clerk_user_a (owner of A only). The JWT sub is
-- presented via the request.jwt.claims GUC exactly as PostgREST sets
-- it. Attempting to grant himself a membership in tenant B must be
-- denied — there is no INSERT policy/privilege on tenant_user for the
-- app role. Before 0004 this INSERT SUCCEEDED (the takeover bug).
-- ============================================================
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"clerk_user_a"}', true);
SET LOCAL ROLE ardosia_app;
DO $$
BEGIN
  BEGIN
    INSERT INTO tenant_user (tenant_id, auth_user_id, role)
    VALUES ('22222222-2222-2222-2222-222222222222', 'clerk_user_a', 'owner');
    RAISE EXCEPTION 'ISOLATION FAIL: app role joined another tenant via tenant_user insert';
  EXCEPTION
    WHEN insufficient_privilege THEN
      RAISE NOTICE 'OK: app role cannot write tenant_user (no INSERT policy/privilege)';
  END;
END $$;
COMMIT;

-- ============================================================
-- ASSERT 8 — app.tenant_id is the SOLE tenant mechanism (Design T,
-- migration 0005), and request.jwt.claims can NO LONGER influence
-- context (the JWT leg is gone — proving M-2's removal stuck).
--
-- (a) Poison test: set request.jwt.claims to clerk_user_b (which, under
--     the OLD JWT leg, would have resolved tenant B) while app.tenant_id
--     names tenant A. current_tenant_id() must resolve A purely from the
--     GUC and IGNORE the claims entirely — the visible product set is A's.
-- (b) Fail-closed test: clear app.tenant_id (the '' a rolled-back
--     set_config leaves) with the claims still set. There is no JWT
--     fallback, so current_tenant_id() is NULL and RLS shows nothing.
-- ============================================================
BEGIN;
SELECT set_config('request.jwt.claims', '{"sub":"clerk_user_b"}', true);
SELECT set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE ardosia_app;
DO $$
BEGIN
  IF current_tenant_id() <> '11111111-1111-1111-1111-111111111111' THEN
    RAISE EXCEPTION 'ISOLATION FAIL: app.tenant_id was not the sole mechanism; request.jwt.claims leaked in (got %)',
      current_tenant_id();
  END IF;
  IF EXISTS (SELECT 1 FROM product
               WHERE tenant_id <> '11111111-1111-1111-1111-111111111111')
  OR NOT EXISTS (SELECT 1 FROM product) THEN
    RAISE EXCEPTION 'ISOLATION FAIL: GUC-resolved tenant saw the wrong product set';
  END IF;
END $$;
RESET ROLE;
-- (b) fail-closed when the GUC is empty, claims notwithstanding.
SELECT set_config('app.tenant_id', '', true);
SET LOCAL ROLE ardosia_app;
DO $$
BEGIN
  IF current_tenant_id() IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: current_tenant_id() not NULL with empty app.tenant_id (got %)',
      current_tenant_id();
  END IF;
  IF (SELECT count(*) FROM product) <> 0 THEN
    RAISE EXCEPTION 'ISOLATION FAIL: rows visible with no tenant context (RLS not fail-closed)';
  END IF;
  RAISE NOTICE 'OK: app.tenant_id is the sole mechanism; claims ignored; fail-closed without it';
END $$;
COMMIT;

-- ============================================================
-- ASSERT 9 — the app role's privilege surface stays minimal
-- (catalog-level guard for C-1, H-1, H-2 against future re-grants).
-- Runs as the seeding superuser; has_table_privilege inspects any
-- role. Fails the reset if a later migration widens the surface.
-- ============================================================
DO $$
BEGIN
  IF has_table_privilege('ardosia_app', 'tenant_user', 'INSERT')
  OR has_table_privilege('ardosia_app', 'tenant_user', 'UPDATE')
  OR has_table_privilege('ardosia_app', 'tenant_user', 'DELETE') THEN
    RAISE EXCEPTION 'ISOLATION FAIL: ardosia_app has write privilege on tenant_user';
  END IF;
  IF has_table_privilege('ardosia_app', 'tenant', 'INSERT')
  OR has_table_privilege('ardosia_app', 'tenant', 'DELETE') THEN
    RAISE EXCEPTION 'ISOLATION FAIL: ardosia_app can INSERT/DELETE the tenant table';
  END IF;
  IF has_table_privilege('ardosia_app', 'checkout_event', 'UPDATE')
  OR has_table_privilege('ardosia_app', 'checkout_event', 'DELETE')
  OR has_table_privilege('ardosia_app', 'checkout_event_item', 'UPDATE')
  OR has_table_privilege('ardosia_app', 'checkout_event_item', 'DELETE') THEN
    RAISE EXCEPTION 'ISOLATION FAIL: the checkout log is mutable by ardosia_app';
  END IF;
  RAISE NOTICE 'OK: ardosia_app privilege surface is minimal';
END $$;

-- ============================================================
-- ASSERT 10 — every tenant_id-bearing base table has at least one
-- RLS policy (FIX M-1's regression net), AND each table's policy
-- COMMAND SET matches the post-0004 design. Mere existence is not
-- enough: a future `FOR ALL` sneaking back onto checkout_event*,
-- tenant, or tenant_user would re-open mutation while still "having a
-- policy". The cmd set (string_agg distinct cmd, alphabetical) must be:
--   checkout_event, checkout_event_item : INSERT,SELECT
--   tenant                              : SELECT,UPDATE
--   tenant_user                         : SELECT
--   every other tenant_id table         : ALL
-- ============================================================
DO $$
DECLARE
  missing text;
  r record;
  expected text;
BEGIN
  -- (a) existence net — every tenant_id table must have a policy.
  SELECT string_agg(t.table_name, ', ' ORDER BY t.table_name) INTO missing
  FROM information_schema.columns c
  JOIN information_schema.tables t
    ON t.table_schema = c.table_schema AND t.table_name = c.table_name
  WHERE c.table_schema = 'public'
    AND c.column_name  = 'tenant_id'
    AND t.table_type   = 'BASE TABLE'
    AND NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = 'public' AND p.tablename = t.table_name
    );
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: tenant_id tables with no RLS policy: %', missing;
  END IF;

  -- (b) command-set net — actual cmd set per policied table == expected.
  --     `tenant` is included explicitly (it has no tenant_id column).
  FOR r IN
    SELECT p.tablename,
           string_agg(DISTINCT p.cmd, ',' ORDER BY p.cmd) AS cmds
    FROM pg_policies p
    WHERE p.schemaname = 'public'
    GROUP BY p.tablename
  LOOP
    expected := CASE r.tablename
      WHEN 'checkout_event'      THEN 'INSERT,SELECT'
      WHEN 'checkout_event_item' THEN 'INSERT,SELECT'
      WHEN 'tenant'              THEN 'SELECT,UPDATE'
      WHEN 'tenant_user'         THEN 'SELECT'
      ELSE 'ALL'
    END;
    IF r.cmds <> expected THEN
      RAISE EXCEPTION 'ISOLATION FAIL: % has policy cmd set [%], expected [%]',
        r.tablename, r.cmds, expected;
    END IF;
  END LOOP;
  RAISE NOTICE 'OK: every tenant_id table has a policy with the expected command set';
END $$;

-- ============================================================
-- Extra fixtures for the resolver asserts: a soft-deleted tenant and a
-- soft-deleted membership. Resolvers must filter both out (fail closed).
-- ============================================================
INSERT INTO tenant (id, name, slug, whatsapp_number, deleted_at) VALUES
  ('33333333-3333-3333-3333-333333333333', 'Tenant C (deleted)', 'tenant-c', '+5588900000003', now());
INSERT INTO tenant_user (tenant_id, auth_user_id, role, deleted_at) VALUES
  ('11111111-1111-1111-1111-111111111111', 'clerk_user_deleted', 'owner', now());

-- ============================================================
-- ASSERT 11 — bootstrap resolvers (migration 0005). SECURITY DEFINER
-- functions map an UNTRUSTED identifier -> tenant_id, reading their
-- RLS-gated tables as the owner. They must resolve live rows, ignore
-- soft-deleted ones, and return NULL for unknown input (fail closed).
-- Run as the seeding superuser (has EXECUTE on the definer functions).
-- ============================================================
DO $$
BEGIN
  IF resolve_tenant_by_slug('tenant-a') <> '11111111-1111-1111-1111-111111111111'
  OR resolve_tenant_by_slug('tenant-b') <> '22222222-2222-2222-2222-222222222222' THEN
    RAISE EXCEPTION 'ISOLATION FAIL: resolve_tenant_by_slug did not resolve a live slug';
  END IF;
  IF resolve_tenant_by_slug('tenant-c') IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: resolve_tenant_by_slug returned a soft-deleted tenant';
  END IF;
  IF resolve_tenant_by_slug('does-not-exist') IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: resolve_tenant_by_slug returned non-NULL for unknown slug';
  END IF;

  IF resolve_tenant_for_user('clerk_user_a') <> '11111111-1111-1111-1111-111111111111'
  OR resolve_tenant_for_user('clerk_user_b') <> '22222222-2222-2222-2222-222222222222' THEN
    RAISE EXCEPTION 'ISOLATION FAIL: resolve_tenant_for_user did not resolve a live membership';
  END IF;
  IF resolve_tenant_for_user('clerk_user_deleted') IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: resolve_tenant_for_user returned a soft-deleted membership';
  END IF;
  IF resolve_tenant_for_user('nobody') IS NOT NULL THEN
    RAISE EXCEPTION 'ISOLATION FAIL: resolve_tenant_for_user returned non-NULL for unknown sub';
  END IF;
  RAISE NOTICE 'OK: resolvers map live identifiers, ignore soft-deletes, fail closed';
END $$;

-- ============================================================
-- ASSERT 12 — ardosia_catalog (migration 0005) is a read-only public
-- role: SELECT on the catalog graph + INSERT on the checkout log only,
-- still tenant-scoped by app.tenant_id, with NO mutation of the catalog
-- and NO access to tenant_user.
-- ============================================================
-- (a) privilege surface — checked as superuser via has_table_privilege.
DO $$
BEGIN
  IF NOT has_table_privilege('ardosia_catalog', 'product', 'SELECT')
  OR NOT has_table_privilege('ardosia_catalog', 'tenant', 'SELECT')
  OR NOT has_table_privilege('ardosia_catalog', 'checkout_event', 'INSERT') THEN
    RAISE EXCEPTION 'ISOLATION FAIL: ardosia_catalog is missing an expected read/append privilege';
  END IF;
  IF has_table_privilege('ardosia_catalog', 'product', 'UPDATE')
  OR has_table_privilege('ardosia_catalog', 'product', 'DELETE')
  OR has_table_privilege('ardosia_catalog', 'product', 'INSERT')
  OR has_table_privilege('ardosia_catalog', 'checkout_event', 'SELECT')
  OR has_table_privilege('ardosia_catalog', 'tenant', 'UPDATE')
  OR has_table_privilege('ardosia_catalog', 'tenant_user', 'SELECT') THEN
    RAISE EXCEPTION 'ISOLATION FAIL: ardosia_catalog privilege surface is too wide';
  END IF;
  RAISE NOTICE 'OK: ardosia_catalog privilege surface is read-only + checkout-append';
END $$;

-- (b) behaviour under the role, public-catalog (no-JWT) path on tenant A.
BEGIN;
SELECT set_config('app.tenant_id', '11111111-1111-1111-1111-111111111111', true);
SET LOCAL ROLE ardosia_catalog;
DO $$
BEGIN
  -- reads are tenant-scoped (count-agnostic; see ASSERT 3)
  IF EXISTS (SELECT 1 FROM product
               WHERE tenant_id <> '11111111-1111-1111-1111-111111111111')
  OR NOT EXISTS (SELECT 1 FROM product) THEN
    RAISE EXCEPTION 'ISOLATION FAIL: catalog role saw the wrong product set';
  END IF;

  -- the one legitimate write: append a checkout snapshot for the current tenant
  INSERT INTO checkout_event (tenant_id, message_text)
  VALUES ('11111111-1111-1111-1111-111111111111', 'catalog order');

  -- cannot mutate the catalog (no UPDATE privilege)
  BEGIN
    UPDATE product SET name = 'tampered' WHERE tenant_id = '11111111-1111-1111-1111-111111111111';
    RAISE EXCEPTION 'ISOLATION FAIL: catalog role could UPDATE a product';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  -- cannot append a checkout for another tenant (WITH CHECK)
  BEGIN
    INSERT INTO checkout_event (tenant_id, message_text)
    VALUES ('22222222-2222-2222-2222-222222222222', 'smuggled');
    RAISE EXCEPTION 'ISOLATION FAIL: catalog role wrote a checkout for another tenant';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  -- cannot touch tenant_user at all (no privilege)
  BEGIN
    PERFORM 1 FROM tenant_user;
    RAISE EXCEPTION 'ISOLATION FAIL: catalog role could read tenant_user';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  RAISE NOTICE 'OK: catalog role reads scoped, appends checkout, cannot mutate or reach tenant_user';
END $$;
COMMIT;

-- ============================================================
-- E2 / E3 CATALOG + CART FIXTURES
-- ============================================================
-- Everything below is plain fixture data (no asserts). It loads AFTER
-- every isolation assert, as the seeding superuser (RESET at the COMMIT
-- above), so RLS is bypassed and rows for both tenants insert freely.
-- It deliberately spreads data across every E2 (catalog SSR) and E3
-- (cart) branch so each tenant renders a DISTINCT, fully-populated state:
--
--   tenant config        A: show_product_prices=false / no custom_domain
--                        B: show_product_prices=true  / custom_domain set
--   price visibility     B has hide_price=true (per-product exception) so
--                        "visible IFF show_product_prices AND NOT hide_price"
--                        is observable; on A the global switch hides all.
--   stock                in_stock=false on A2 and B3 (Indisponível badge)
--   listing filter       is_active=false (A3) and deleted_at (B4) — both
--                        must be excluded from the catalog listing
--   quantity cap         max_quantity NULL (A1/B1/B2, unlimited) AND set
--                        (A2=5, A4=2, B3=3)
--   variations           required feature (A "Recheio", B "Tamanho"),
--                        optional feature (A "Feature A", B "Cor"),
--                        inactive feature (B "Oculta"), inactive option
--                        (A "Inativo"), deltas >0 and =0
--   images               multi-image (A1), single primary (A2/B1/B2/B3),
--                        none (A3/A4) — placeholder branch
--   taxonomy             multi-category (B1), no category (A4),
--                        inactive category (A "Category A Inativa")
--
-- Reuses the isolation fixtures already seeded at the top: products
-- A1/B1, Feature A/B, Category A/B, Tag A/B. New IDs only.
-- ============================================================

-- ---- Tenant A — additional products (prices globally hidden) ----------
INSERT INTO product (id, tenant_id, name, description, price_cents, hide_price, max_quantity, in_stock, is_active, deleted_at) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
     'Bolo de Cenoura', 'Com cobertura de chocolate.', 4500, false, 5,    false, true,  NULL),  -- out of stock + capped qty
  ('aaaaaaaa-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
     'Produto Inativo A', 'Não deve aparecer na vitrine.',  800, false, NULL, true,  false, NULL), -- is_active=false → hidden from listing
  ('aaaaaaaa-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
     'Sem Categoria A', 'Sem categoria e sem imagem.',     1200, false, 2,    true,  true,  NULL);  -- no category, no image (placeholder)

-- ---- Tenant B — additional products (prices visible) ------------------
INSERT INTO product (id, tenant_id, name, description, price_cents, hide_price, max_quantity, in_stock, is_active, deleted_at) VALUES
  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222',
     'Sob Consulta', 'Preço sob consulta.',               9900, true,  NULL, true,  true,  NULL),  -- hide_price exception (tenant shows prices)
  ('bbbbbbbb-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222',
     'Esgotado B', 'Temporariamente sem estoque.',        3000, false, 3,    false, true,  NULL),  -- out of stock + capped qty
  ('bbbbbbbb-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222',
     'Produto Apagado B', 'Soft-deleted, nunca exibido.',  500, false, NULL, true,  true,  now()); -- deleted_at → excluded

-- ---- Images (position 0 = primary) -----------------------------------
-- A1 already has two images (seeded at the top, used by the swap assert).
INSERT INTO product_image (id, tenant_id, product_id, storage_key, position) VALUES
  ('aaaaaaaa-1111-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002', 'a/bolo-0.jpg', 0),
  ('bbbbbbbb-1111-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'b/camiseta-0.jpg', 0),
  ('bbbbbbbb-1111-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000002', 'b/sob-consulta-0.jpg', 0),
  ('bbbbbbbb-1111-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000003', 'b/esgotado-0.jpg', 0);

-- ---- Features (variations) -------------------------------------------
-- 'Feature A'/'Feature B' (seeded at top, required=false) get options below.
-- One required feature per tenant forces a cart selection; B also gets an
-- inactive feature the catalog must skip.
INSERT INTO feature (id, tenant_id, product_id, name, required, is_active) VALUES
  ('aaaaaaaa-2222-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'Recheio',  true,  true),
  ('bbbbbbbb-2222-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'Tamanho',  true,  true),
  ('bbbbbbbb-2222-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'Oculta',   false, false); -- inactive → skipped

-- ---- Options (price_delta_cents: 0 = no change, >0 = surcharge) -------
INSERT INTO option (id, tenant_id, feature_id, name, price_delta_cents, is_active) VALUES
  -- A · Feature A (optional)
  ('aaaaaaaa-6666-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-2222-0000-0000-000000000001', 'Pequeno', 0,   true),
  ('aaaaaaaa-6666-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-2222-0000-0000-000000000001', 'Grande',  500, true),
  ('aaaaaaaa-6666-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-2222-0000-0000-000000000001', 'Inativo', 200, false), -- inactive option → skipped
  -- A · Recheio (required)
  ('aaaaaaaa-6666-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-2222-0000-0000-000000000002', 'Sem',      0,   true),
  ('aaaaaaaa-6666-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-2222-0000-0000-000000000002', 'Catupiry', 300, true),
  -- B · Cor (optional, all zero-delta)
  ('bbbbbbbb-6666-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-2222-0000-0000-000000000001', 'Branca',   0,   true),
  ('bbbbbbbb-6666-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-2222-0000-0000-000000000001', 'Preta',    0,   true),
  -- B · Tamanho (required, mixed deltas)
  ('bbbbbbbb-6666-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-2222-0000-0000-000000000002', 'P',        0,    true),
  ('bbbbbbbb-6666-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-2222-0000-0000-000000000002', 'M',        0,    true),
  ('bbbbbbbb-6666-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222', 'bbbbbbbb-2222-0000-0000-000000000002', 'G',        1500, true);

-- ---- Extra taxonomy --------------------------------------------------
-- 'Category A'/'Category B' and 'Tag A'/'Tag B' already seeded at the top.
INSERT INTO category (id, tenant_id, name, is_active) VALUES
  ('aaaaaaaa-3333-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Category A Inativa', false), -- inactive → not a filter option
  ('bbbbbbbb-3333-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'Category B Extra',   true);

-- ---- Junctions -------------------------------------------------------
INSERT INTO product_category (tenant_id, product_id, category_id) VALUES
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-3333-0000-0000-000000000001'),  -- A1 in Category A
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-3333-0000-0000-000000000001'),  -- A2 in Category A
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-3333-0000-0000-000000000001'),  -- B1 in Category B …
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-3333-0000-0000-000000000002'),  -- … and Category B Extra (multi)
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000002', 'bbbbbbbb-3333-0000-0000-000000000001');  -- B2 in Category B

INSERT INTO product_tag (tenant_id, product_id, tag_id) VALUES
  ('11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-4444-0000-0000-000000000001'),  -- A1 · Tag A
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-4444-0000-0000-000000000001'),  -- B1 · Tag B
  ('22222222-2222-2222-2222-222222222222', 'bbbbbbbb-0000-0000-0000-000000000003', 'bbbbbbbb-4444-0000-0000-000000000001');  -- B3 · Tag B
