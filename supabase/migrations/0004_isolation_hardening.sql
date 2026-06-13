-- ============================================================
-- ARDOSIA — migration 0004
-- Isolation hardening — closes the holes found in the security
-- review of 0001–0003.
-- ============================================================
-- Forward-only. 0001–0003 stay verbatim (they mirror the design
-- doc and may already be applied); this migration corrects the
-- enforced reality on top of them.
--
-- Threat-model recap: in production the ONLY non-bypass role that
-- touches the database is ardosia_app — the app is a BFF (browser →
-- Next → Drizzle as ardosia_app), and the Clerk JWT is validated in
-- Node before the backend sets app.tenant_id on the transaction. The
-- anon/publishable key never reaches the DB directly. current_tenant_id()
-- is therefore trustworthy: the GUC is set by the backend post-validation,
-- never by the client.
--
-- Because a single named role binds here, POLICIES and REVOKEs are
-- redundant layers over that same role, not primary-vs-secondary:
-- the policy denies the command via RLS, the REVOKE denies it via
-- table privilege, and either alone would hold. service_role
-- (BYPASSRLS) remains the provisioning/offboarding path.
-- ============================================================

-- ------------------------------------------------------------
-- FIX C-1 (CRITICAL) — tenant takeover via tenant_user self-insert.
--
-- The 0003 policy was `FOR ALL` with a WITH CHECK that constrained
-- auth_user_id (the caller's own sub) but NOT tenant_id. Any
-- authenticated user could therefore INSERT (their_sub, ANY tenant,
-- 'owner') and join an arbitrary tenant — full cross-tenant read
-- AND write.
--
-- tenant_user is a PROVISIONING table: rows are created only by the
-- service_role onboarding route (0003 operational note), never by
-- the app. So the app role needs SELECT only — a user may READ their
-- own membership(s), never write them. Making the policy FOR SELECT
-- removes any INSERT/UPDATE/DELETE policy, so RLS denies those
-- commands for every non-bypass role regardless of table grants.
-- The REVOKE is belt-and-suspenders for ardosia_app.
--
-- NOTE: current_tenant_id() (SECURITY DEFINER, runs as postgres /
-- BYPASSRLS) does NOT depend on this policy — its internal
-- tenant_user lookup bypasses RLS. So read-only here is safe.
-- CONSEQUENCE: the Clerk `user.deleted` webhook that soft-deletes a
-- tenant_user row must run on the service_role connection, not the
-- app connection.
-- ------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON tenant_user FROM ardosia_app;

DROP POLICY IF EXISTS tenant_user_self_access ON tenant_user;
CREATE POLICY tenant_user_self_access ON tenant_user
  FOR SELECT
  USING (auth_user_id = (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'));

-- ------------------------------------------------------------
-- FIX H-1 (HIGH) — app could hard-DELETE its own tenant (cascade
-- wipe of every child, including the "immutable" checkout log) and
-- bypass the soft-delete model.
--
-- An owner legitimately UPDATEs their own tenant row (store
-- settings). They must NOT INSERT a tenant (that is service_role
-- provisioning) nor DELETE one (that is service_role offboarding,
-- which soft-deletes via deleted_at). Replace the `FOR ALL` policy
-- with SELECT + UPDATE only: with no INSERT/DELETE policy present,
-- those commands are denied for non-bypass roles.
-- ------------------------------------------------------------
REVOKE INSERT, DELETE ON tenant FROM ardosia_app;

DROP POLICY IF EXISTS tenant_self_isolation ON tenant;
CREATE POLICY tenant_self_read ON tenant
  FOR SELECT
  USING (id = (SELECT current_tenant_id()));
CREATE POLICY tenant_self_update ON tenant
  FOR UPDATE
  USING (id = (SELECT current_tenant_id()))
  WITH CHECK (id = (SELECT current_tenant_id()));

-- ------------------------------------------------------------
-- FIX H-2 (HIGH) — make checkout-log immutability defense-in-depth.
--
-- 0002 revokes UPDATE/DELETE on checkout_event* from ardosia_app,
-- but that is the ONLY guard: any future blanket
-- `GRANT ... UPDATE, DELETE ON ALL TABLES` (or the 0002 ALTER
-- DEFAULT PRIVILEGES on new tables) silently re-arms mutation, and
-- the 0003 policy was `FOR ALL` (it would permit it the moment the
-- grant returned).
--
-- Replace the `FOR ALL` isolation policy on each checkout table with
-- SELECT + INSERT policies only. With no UPDATE/DELETE policy, RLS
-- denies mutation for every non-bypass role even if the privilege is
-- re-granted. service_role (BYPASSRLS) still cascades on offboarding.
-- ------------------------------------------------------------
DROP POLICY IF EXISTS checkout_event_tenant_isolation ON checkout_event;
CREATE POLICY checkout_event_tenant_read ON checkout_event
  FOR SELECT
  USING (tenant_id = (SELECT current_tenant_id()));
CREATE POLICY checkout_event_tenant_insert ON checkout_event
  FOR INSERT
  WITH CHECK (tenant_id = (SELECT current_tenant_id()));

DROP POLICY IF EXISTS checkout_event_item_tenant_isolation ON checkout_event_item;
CREATE POLICY checkout_event_item_tenant_read ON checkout_event_item
  FOR SELECT
  USING (tenant_id = (SELECT current_tenant_id()));
CREATE POLICY checkout_event_item_tenant_insert ON checkout_event_item
  FOR INSERT
  WITH CHECK (tenant_id = (SELECT current_tenant_id()));

-- ------------------------------------------------------------
-- FIX M-1 (MEDIUM, partial) — "no future table escapes RLS" was
-- asserted but only enforced by a one-shot loop at 0003 time. The
-- proper enforcement (a ddl_command_end EVENT TRIGGER) requires
-- superuser, which the migration role is NOT on Supabase, so it
-- cannot live in a migration. Enforcement therefore stays in the
-- seed/CI regression net (seed.sql asserts 2 + 8): every base table
-- must have RLS+FORCE, and every tenant_id table must have a policy.
-- This comment is the durable record of WHY there is no event
-- trigger; future migrations that add a table MUST enable+force RLS
-- and attach a policy themselves.
-- ------------------------------------------------------------
