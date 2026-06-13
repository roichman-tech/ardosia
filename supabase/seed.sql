-- ============================================================
-- ARDOSIA — seed.sql
-- Loaded after migrations on `supabase db reset`. Doubles as the
-- tenant-isolation regression test: the asserts below FAIL the
-- reset (and therefore CI) if the invariants from migrations
-- 0002/0003 ever regress.
--
-- Two fake tenants, A and B. The negative asserts prove that the
-- DB itself — not application convention — prevents cross-tenant
-- references, cross-tenant reads, cross-tenant writes, and mutation
-- of the immutable checkout log.
--
-- CI NOTE: every assert signals failure via RAISE EXCEPTION, which
-- only aborts the run when the seed is executed with ON_ERROR_STOP=1.
-- `supabase db reset` sets this; any other invocation path MUST too,
-- or a broken invariant logs a notice and CI still goes green.
-- ============================================================

-- ------------------------------------------------------------
-- Fixtures
-- ------------------------------------------------------------
INSERT INTO tenant (id, name, slug, whatsapp_number) VALUES
  ('11111111-1111-1111-1111-111111111111', 'Tenant A', 'tenant-a', '+5588900000001'),
  ('22222222-2222-2222-2222-222222222222', 'Tenant B', 'tenant-b', '+5588900000002');

INSERT INTO product (id, tenant_id, name, price_cents) VALUES
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Product A1', 1000),
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'Product B1', 2000);

-- Two images on Product A1 for the position-swap test.
INSERT INTO product_image (id, tenant_id, product_id, storage_key, position) VALUES
  ('aaaaaaaa-1111-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'a/img-0.jpg', 0),
  ('aaaaaaaa-1111-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000001', 'a/img-1.jpg', 1);

-- ============================================================
-- ASSERT 1 — composite FK blocks a cross-tenant parent reference.
-- A feature owned by tenant A that points at tenant B's product
-- must be rejected by the engine. Runs as the seeding superuser, so
-- RLS is bypassed: this isolates the FOREIGN KEY behaviour, which
-- is exactly the gap convention-only tenant_id left open.
-- ============================================================
DO $$
BEGIN
  BEGIN
    INSERT INTO feature (tenant_id, product_id, name)
    VALUES ('11111111-1111-1111-1111-111111111111',   -- tenant A
            'bbbbbbbb-0000-0000-0000-000000000001',   -- tenant B's product
            'Cross-tenant feature');
    RAISE EXCEPTION 'ISOLATION FAIL: cross-tenant feature insert was allowed';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'OK: composite FK blocked cross-tenant feature reference';
  END;
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
-- ASSERT 3 + 4 — read and write isolation under the app role.
-- Switch to the app role (NOBYPASSRLS) and adopt tenant A via the
-- per-transaction GUC (the public-catalog path current_tenant_id()
-- understands). Both asserts run in this one role/GUC context.
-- ============================================================
SET app.tenant_id = '11111111-1111-1111-1111-111111111111';
SET ROLE ardosia_app;

-- ASSERT 3 — cross-tenant SELECT returns 0 (policy USING clause).
-- Tenant A must see its own product and none of B's.
DO $$
BEGIN
  IF (SELECT count(*) FROM product
        WHERE tenant_id = '22222222-2222-2222-2222-222222222222') <> 0 THEN
    RAISE EXCEPTION 'ISOLATION FAIL: tenant A saw tenant B products under RLS';
  END IF;
  IF (SELECT count(*) FROM product) <> 1 THEN
    RAISE EXCEPTION 'ISOLATION FAIL: tenant A should see exactly its own product';
  END IF;
  RAISE NOTICE 'OK: RLS confines SELECT to the current tenant';
END $$;

-- ASSERT 4 — cross-tenant WRITE is rejected (policy WITH CHECK clause).
-- Still tenant A under ardosia_app. Inserting a product whose
-- tenant_id is B must be blocked by WITH CHECK, even though
-- ardosia_app holds INSERT privilege. Write-side twin of Assert 3:
-- USING confines reads, WITH CHECK confines writes. An RLS WITH CHECK
-- violation is SQLSTATE 42501 -> condition insufficient_privilege.
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

RESET ROLE;
RESET app.tenant_id;

-- ============================================================
-- ASSERT 5 — checkout_event* is immutable to the app role.
-- Verifies migration 0002's REVOKE UPDATE, DELETE ON checkout_event,
-- checkout_event_item FROM ardosia_app. Table-level privilege is
-- checked BEFORE RLS and BEFORE any row is matched, so these fail
-- even with the log empty — no fixture required. Denied privilege
-- surfaces as SQLSTATE 42501 -> condition insufficient_privilege.
-- ============================================================
SET ROLE ardosia_app;

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

RESET ROLE;

-- ============================================================
-- ASSERT 6 — image position swap commits in a single transaction.
-- The DEFERRABLE INITIALLY DEFERRED unique constraint must tolerate
-- the transient duplicate (both rows briefly at position 1), with
-- the check deferred to the end of the transaction. The whole swap
-- happens inside one DO block (one transaction): a non-deferrable
-- constraint would abort on the first UPDATE; the deferred one only
-- checks when the block's transaction commits, by which point the
-- positions are distinct again.
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