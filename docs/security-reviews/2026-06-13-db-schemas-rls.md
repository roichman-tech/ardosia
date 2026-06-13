# Ardosia — Schema Security Review (migrations 0001–0004 + seed)

**Date:** 2026-06-13
**Scope:** `supabase/migrations/0001..0004` and `supabase/seed.sql`, plus the env/auth
surface that the schema's trust model depends on (`supabase/config.toml`,
`src/env/*`, `.env.example`). No application code yet — the goal is to clear the
schema before any is written.
**Method:** static read of all DDL + seed, cross-referenced against the handoff
brief, `docs/stack-decision.md`, and `config.toml`. Items needing a live database
are marked **needs-empirical-check** with the exact SQL to run.

---

## 0. Verdict summary

| # | Agenda item | Verdict |
|---|---|---|
| 1 | GUC cannot be client-influenced (central property) | **Sound as a property** — but unenforceable in schema; becomes app invariant `INV-1`. One real gap feeds it: see H-3. |
| 2 | JWT leg of `current_tenant_id()` is dead on the Drizzle path | **Confirmed dead by default** (`config.toml:368` clerk disabled + Drizzle never sets `request.jwt.claims`). **Needs a decision** (Design J vs T) — see H-3 / Decision-1. |
| 3 | Pooler transaction mode + `set_config(...,true)` | **Sound by construction**; seed models the correct pattern. Becomes app invariant `INV-2`. |
| 4 | Custom role authenticates through Supavisor as `NOBYPASSRLS` | **Verified (E-1):** `ardosia_app` & `ardosia_catalog` = `rolbypassrls=f, rolsuper=f, login=t`; `postgres`/`service_role` bypass as expected. (Pooler-username form still to confirm on cloud.) |
| 5 | Provisioning + webhook on `service_role`, server-only | **Sound** — schema *forces* it (FORCE RLS blocks `ardosia_app` from first-tenant insert). Becomes invariants `INV-3/4`. |
| 6 | Finish ROI-95; fix 0004 recap comment | 0004 comment is **already accurate** (handoff claim is stale — see note). ROI-95 **incomplete** — see M-3. |
| 7 | Heterogeneous policies → strengthen seed `cmd` assert | **Valid gap**; upgrade provided below. |
| 8 | Composite-FK seed coverage (1 of 6) | **Valid gap**; parameterized loop provided below. |
| 9 | `checkout_event_item.product_id` residual | **Accepted**; reduces to app invariant `INV-5`. |
| 10 | `ALTER DEFAULT PRIVILEGES` scope | **Sound iff migrations always run as `postgres`** — invariant `INV-6`; note the re-arm risk it creates (H-2 territory). |
| 11 | `f_unaccent` / `unaccent` pinning | **Verified (E-2):** `unaccent` in `public`; `f_unaccent('açúcar')='acucar'`; all 3 expression indexes valid; `ardosia_app` write through the index works. |
| 12 | Price-visibility leak | **App-layer** — invariant `INV-7`. |
| 13 | LGPD on the checkout log | **Schema-forced gap** — see L-1. |

**New findings beyond the agenda:** **H-3** (tenant-resolution bootstrap — the
most important), **N-1** (single role spans two trust levels), **M-2** (seed
ASSERT 8 tests a non-production path), **M-3** (ROI-95 env layer incomplete),
**L-1** (LGPD erasure path).

**Bottom line:** the *isolation core* is genuinely strong — composite tenant FKs
make cross-tenant parent references impossible at the engine level (RLS-independent),
FORCE RLS + fail-closed policies are correct, and the privilege surface is tight and
regression-netted. The schema is **not yet shippable** because of **one functional
gap that is also a security fork (H-3)**: how a tenant is *resolved before context
exists* is undefined, and the two obvious ad-hoc fixes (use `service_role` for
catalog reads; or feed the slug/sub into the GUC) each break a stated invariant.
Resolve H-3 (Decision-1) and the model closes.

---

## 1. Findings (new), by severity

### H-3 — HIGH — Tenant resolution has no defined bootstrap; both ad-hoc fixes break an invariant

Every request must turn an *untrusted identifier* into a `tenant_id` **before** any
tenant context exists:

- **Dashboard:** validated Clerk `sub` → `tenant_user` → `tenant_id`.
- **Catalog:** Host/slug → `tenant` → `tenant_id`.

Under `ardosia_app` (NOBYPASSRLS, FORCE RLS) **neither lookup can run**, because both
target tables are gated by policies that need context that doesn't exist yet:

- `tenant` (0004): `tenant_self_read USING (id = (SELECT current_tenant_id()))`.
  At resolution time `current_tenant_id()` is NULL → **`SELECT id FROM tenant WHERE
  slug = $1` returns zero rows.** The catalog cannot find the tenant it is trying to
  enter.
- `tenant_user` (0004): `FOR SELECT USING (auth_user_id = request.jwt.claims->>'sub')`.
  Under Drizzle `request.jwt.claims` is never set → NULL → **zero rows**, unless the
  BFF first injects that GUC.

So the schema is currently **non-functional for both entry paths on the app role** —
and, more importantly, the two natural "fixes" are each a security regression:

1. **Resolve on `service_role`** (BYPASSRLS): over-privileges the public, unauthenticated
   catalog path — a SQL bug there now reads/writes *any* tenant. Directly contradicts
   the "restricted role, not service role" decision (`stack-decision.md:39`).
2. **Push slug/sub into a GUC the policy reads** (`request.jwt.claims` or `app.tenant_id`):
   if the resolver's input is the raw Host header / a client value, this is *exactly*
   the client-influences-context failure the whole model forbids (item 1).

**This is the spine of the review.** The fix must (a) keep the app off `service_role`
for normal reads, and (b) never let an unvalidated identifier reach context.

**Recommended fix — `SECURITY DEFINER` resolver functions** (owner `postgres`,
`SET search_path = ''`, fully schema-qualified, `EXECUTE` to `ardosia_app` only). They
read their gated tables as the definer, return *only the id*, and filter `deleted_at`:

```sql
-- slug → tenant_id (public catalog bootstrap). Exposes only existence-by-slug,
-- which is already public. Returns NULL for unknown/deleted slugs (fail closed).
CREATE FUNCTION resolve_tenant_by_slug(p_slug text)
  RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT t.id FROM public.tenant t
  WHERE t.slug = p_slug AND t.deleted_at IS NULL
$$;
-- and an equivalent resolve_tenant_by_custom_domain(text) for custom domains.

-- validated sub → tenant_id (dashboard bootstrap). The BFF MUST pass only a
-- Clerk-VALIDATED sub here — this is INV-1 extended to the resolver argument.
CREATE FUNCTION resolve_tenant_for_user(p_sub text)
  RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT tu.tenant_id FROM public.tenant_user tu
  WHERE tu.auth_user_id = p_sub AND tu.deleted_at IS NULL
  LIMIT 1
$$;
```

The BFF flow becomes: resolve → `set_config('app.tenant_id', <id>, true)` → run
tenant-scoped queries. `current_tenant_id()` then reads `app.tenant_id` for **both**
paths — one mechanism, set server-side post-validation. This is what makes H-3 and
item 2 collapse into a single, clean answer (Decision-1, Design T below).

---

### N-1 — MEDIUM (defense-in-depth) — one role spans anonymous-catalog and authenticated-owner

`ardosia_app` is used for **both** the public, unauthenticated catalog path and the
authenticated owner dashboard. RLS enforces **tenant** isolation, not **authority
within a tenant**. Once `app.tenant_id = T` is set, the policies are `FOR ALL`
(SELECT/INSERT/UPDATE/DELETE) for tenant T — so the *only* thing stopping a public
catalog visitor's connection from mutating T's catalog is application discipline
(the SSR layer choosing to issue read-only queries).

`stack-decision.md:29` explicitly accepts "RLS as defense-in-depth, not the primary
boundary; the SSR layer *is* the backend" — so this is **consistent with the stated
model**, not a contradiction. But it is cheap to harden the *secondary* boundary too:

**Recommendation (Decision-2):** a second restricted role `ardosia_catalog` for the
public path — `SELECT` on the catalog tables + `INSERT` on `checkout_event*` only,
**no UPDATE/DELETE anywhere**. Then even a code bug on the anonymous path cannot
mutate a merchant's catalog, and the checkout-log INSERT (the one write the public
path legitimately needs, per `stack-decision.md:34`) still works. The dashboard keeps
`ardosia_app` (full owner DML). Both still resolve via `app.tenant_id`.

This is optional — the app-layer boundary is the accepted primary — but it converts
"a write bug on the public internet path is a tenant-data-integrity incident" into
"a write bug is a denied-privilege error." Low cost, high blast-radius reduction.

---

### M-2 — MEDIUM — seed ASSERT 8 validates a path production never exercises

ASSERT 8 sets `request.jwt.claims` by hand and proves "the JWT leg wins over a
poisoned `app.tenant_id`." Under Drizzle, **nothing populates `request.jwt.claims`**
(`config.toml:368` clerk third-party disabled; Drizzle is not PostgREST). So in
production the JWT leg is *always NULL* and `app.tenant_id` is the **sole** mechanism
— there is no JWT override to fall back on if `app.tenant_id` is wrong.

The test therefore asserts a safety property (**"a poisoned GUC is overridden"**) that
**does not hold in production**. That is worse than no test: it green-lights a defense
that isn't there. Reconcile with Decision-1 — under Design T this assert is rewritten
to prove the *actual* production property (app.tenant_id is the only mechanism and is
honored exactly); under Design J it must be made real by having the BFF set
`request.jwt.claims` and enabling clerk third-party auth.

---

### M-3 — MEDIUM — ROI-95 env layer is incomplete; the browser still mandates the anon key

`src/lib/supabase.ts` is staged for deletion (good), but the trust-boundary cleanup is
not done:

- **`src/env/client.ts:9-10`** still *requires* `NEXT_PUBLIC_SUPABASE_URL` and
  `NEXT_PUBLIC_SUPABASE_ANON_KEY`. While these are present and validated, any build
  still inlines a DB-reachable key into the browser bundle — the exact public read
  path D-BFF deletes.
- **`src/env/server.ts`** has **no** DB credential at all — no `DATABASE_URL`
  (ardosia_app via pooler) and no `service_role` DB URL/key. The server-side DB path
  (ROI-26) is unwired, so today the *only* configured route to Postgres is the browser
  anon key. The intended primary path doesn't exist yet.
- **`.env.example` / `docs/env-vars.md`** still describe the anon-key model and even
  reference a deleted `0001_greetings.sql` table and a `/hello` smoke route. Stale and
  actively misleading about the security model.

**Fix:** remove the `NEXT_PUBLIC_SUPABASE_*` pair from `clientSchema`; add server-only
`DATABASE_URL` (ardosia_app) and a server-only `service_role` connection string/key to
`serverSchema` (behind `import "server-only"`); rewrite `.env.example` + `env-vars.md`
to the BFF model. Audit Vercel (local/preview/prod) so no DB credential carries a
`NEXT_PUBLIC_` prefix in any environment.

---

### L-1 — LOW (out of strict scope; schema-forced) — checkout log has no per-subject erasure path

`checkout_event.message_text` is the full generated WhatsApp order and
`customer_note` is free-text — both routinely contain personal data (name, address,
phone). The log is intentionally immutable (no `deleted_at`; `ardosia_app` has no
UPDATE/DELETE; only `service_role` offboarding cascade removes rows). That means there
is **no mechanism to honor an LGPD erasure/rectification request for one data subject**
short of deleting the whole tenant.

Not a blocker for a schema *security* review, but the schema *forces* the gap, so flag
it: define a documented `service_role` redaction path (e.g. null/overwrite
`message_text`/`customer_note` for a subject's rows while preserving the
amount/snapshot integrity needed for the merchant's records). Cross-ref ROI-52
(log hygiene) so the same PII isn't duplicated into Vercel logs.

---

## 2. Per-agenda verdicts (detail for the items not covered above)

**Item 1 — central property.** Cannot be enforced in DDL; it is `INV-1`. The schema
*supports* it well: with leg-2 as the mechanism, isolation reduces to "the value
written to `app.tenant_id` (and any `sub` passed to a resolver) originates only from a
server-side validated source." H-3's resolver functions are what keep that true
without leaking to `service_role`.

**Item 3 — pooler / transaction locality.** Correct by construction. The local pooler
is `pool_mode = "transaction"` (`config.toml:50`); prod Supavisor is transaction mode.
`set_config(..., true)` + queries must share one transaction or a follow-up query lands
on a different pooled backend with no GUC → RLS matches nothing → **silent empty
result** (fails closed, but a real bug). The seed's BEGIN / `set_config(local)` /
`SET LOCAL ROLE` / COMMIT block is the canonical pattern → `INV-2`. **Critical sub-point:**
the `is_local` third arg must be `true`; a session-level `set_config(...,false)` or bare
`SET` leaks tenant context onto the next request that reuses the pooled connection =
cross-tenant leak. This is the single most dangerous easy mistake in the app layer.

**Item 5 — provisioning/webhook on service_role.** The schema *forces* this: under
FORCE RLS + `tenant_self_*`, `ardosia_app` cannot insert the first tenant (no context
exists at signup), and after C-1 it has no INSERT on `tenant_user` and no UPDATE on it
either (so the `user.deleted` soft-delete must be `service_role`). `INV-3` (provision on
service_role), `INV-4` (webhook on service_role, key server-only).

**Item 6 — 0004 recap comment.** **The handoff's claim that the 0004 header is
"factually wrong" is stale.** The current header (0004:10-22) correctly states
"the ONLY non-bypass role that touches the database is ardosia_app… the anon/publishable
key never reaches the DB directly… the GUC is set by the backend post-validation." No
mention of `anon`/`authenticated` binding. **Mark resolved.** The remaining ROI-95 work
is the env layer (M-3), not the comment.

**Item 9 — `checkout_event_item.product_id`.** Single-column nullable
`ON DELETE SET NULL`, deliberately not tenant-validated; snapshot columns are the source
of truth. Residual: the pointer can reference another tenant's product id. Acceptable iff
no read path joins through it cross-tenant → `INV-5`. The `ix_cei_product (tenant_id,
product_id)` index encourages the correct tenant-scoped access shape.

**Item 10 — ALTER DEFAULT PRIVILEGES.** Applies only to objects created by the role that
ran the ALTER (`postgres`, no `FOR ROLE` clause → current role). Sound iff every future
migration runs as `postgres` (Supabase CLI default) → `INV-6`. **Note the coupling to
H-2:** those defaults grant `UPDATE, DELETE` on *future* tables to `ardosia_app`, so any
new immutable/log table is born mutable and must explicitly `REVOKE` + ship
`SELECT`/`INSERT`-only policies, exactly as 0004 did. Encode that as a migration checklist
(see §5).

**Item 12 — price visibility.** Pure logic: visible IFF `tenant.show_product_prices AND
NOT product.hide_price`; `total_amount_cents`/`unit_price_cents` are NULL when hidden.
No RLS angle. `INV-7`: no read path may compute or emit a price the visibility rule hides,
including via the checkout snapshot.

---

## 3. Consolidated changes

### 3a. DDL — `0005` (DECIDED: Design T + add `ardosia_catalog`; written + applied)

> Decisions §4 resolved this session: **Design T** and **add `ardosia_catalog`**.
> Implemented in `supabase/migrations/0005_resolvers_single_guc_and_catalog_role.sql`,
> validated green (§6). Shape as built:

1. **Resolver functions** `resolve_tenant_by_slug`, `resolve_tenant_by_custom_domain`,
   `resolve_tenant_for_user` (H-3). Required under either design.
2. **(Design T)** simplify `current_tenant_id()` to the single GUC leg and drop
   `SECURITY DEFINER` + the `auth.jwt()`/auth-schema dependency:
   ```sql
   CREATE OR REPLACE FUNCTION current_tenant_id()
     RETURNS uuid LANGUAGE sql STABLE AS $$
     SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
   $$;
   ```
   (Keeps the initplan `(SELECT current_tenant_id())` policy form working unchanged.)
3. **(Decision-2, optional)** create `ardosia_catalog` (SELECT on catalog tables +
   INSERT on `checkout_event*`); grant EXECUTE on the slug/domain resolvers; **no**
   write grants. Add it to the loop-applied grants and a seed assert mirroring ASSERT 9.

> These are **not** written yet — they hinge on the founder's call. `current_tenant_id()`
> being a `COALESCE(jwt, guc)` was an explicit decision (`stack-decision.md:41`), so I am
> not unilaterally removing leg-1.

### 3b. Seed strengthening (no decision required — safe to apply now)

- **Item 8 — all six composite FKs.** Replace the single feature→product assert with a
  loop over the parent/child pairs:
  `(product_image,product)`, `(feature,product)`, `(option,feature)`,
  `(product_category,product)`, `(product_category,category)`, `(product_tag,product)`,
  `(product_tag,tag)`, `(checkout_event_item,checkout_event)` — insert a child row with a
  *foreign-tenant* parent id and assert `foreign_key_violation` each time.
- **Item 7 — assert the policy `cmd` set per table, not mere existence.** Upgrade ASSERT
  10 to compare `pg_policies.cmd` against an expected map, so a future `FOR ALL` sneaking
  back onto `checkout_event*`/`tenant`/`tenant_user` fails CI:
  ```sql
  -- expected (table, cmd-set) after 0004:
  --   checkout_event, checkout_event_item : {SELECT, INSERT}
  --   tenant                              : {SELECT, UPDATE}
  --   tenant_user                         : {SELECT}
  --   all other tenant_id tables          : {ALL}
  ```
  Fail if any table's actual set of `cmd` values diverges.
- **M-2 — fix ASSERT 8** to match the chosen design (see M-2).

---

## 4. Decisions (RESOLVED this session)

- **Decision-1 — tenant resolution & the JWT leg → chose Design T.**
  - **Design T (recommended):** `app.tenant_id` is the *sole* RLS mechanism for both
    paths; bootstrap via the `SECURITY DEFINER` resolver functions; drop leg-1 and the
    `SECURITY DEFINER`/auth dependency from `current_tenant_id()`. One mechanism, crisp
    invariant, no auth-schema coupling, fully portable. Rewrite ASSERT 8 accordingly.
  - **Design J:** keep the JWT leg live by enabling `[auth.third_party.clerk]` and having
    the BFF set `request.jwt.claims` per transaction; still need a slug resolver for the
    catalog. More moving parts, keeps a second mechanism whose only justification (a
    client-direct path) D-BFF says won't exist.
- **Decision-2 — separate `ardosia_catalog` read role → chose Yes.** Hardens the
  secondary boundary cheaply (N-1): a write bug on the public path is now a denied-
  privilege error, not a tenant-data incident.

## 5. Application invariants (test specs for ROI-26 / ROI-74)

- **INV-1** — `app.tenant_id` (and any `sub` passed to `resolve_tenant_for_user`) is
  written **only** from a server-side validated source: validated Clerk `sub` (dashboard)
  or middleware host/slug→id resolution (catalog). No request body/header/query/cookie
  reaches `set_config('app.tenant_id', …)` or a resolver argument unvalidated. *Test:*
  attempt to influence context via every client-controlled input; prove none changes the
  resolved tenant.
- **INV-2** — every tenant-scoped DB access is inside a single `db.transaction()` whose
  **first** statement is `set_config('app.tenant_id', <id>, true)` (is_local = **true**).
  No bare `SET`, no `is_local = false`. *Test:* a tenant-scoped query issued outside a
  context-set transaction returns zero / throws — never leaks.
- **INV-3** — tenant + first `tenant_user` creation runs on a **separate `service_role`**
  connection, never `ardosia_app`.
- **INV-4** — the Clerk `user.deleted` webhook soft-deletes `tenant_user` on
  `service_role`; the `service_role` key/URL is server-only env (never `NEXT_PUBLIC_`).
- **INV-5** — no read path joins `checkout_event_item.product_id → product` without
  `tenant_id` in the join predicate.
- **INV-6** — every migration runs as `postgres`; every migration that adds a table
  **enables + forces RLS and attaches a tenant policy** in the same migration (no event
  trigger exists to catch omissions — 0004:M-1). Immutable/log tables additionally
  `REVOKE UPDATE, DELETE` and ship `SELECT`/`INSERT`-only policies.
- **INV-7** — no read path emits a price hidden by `show_product_prices` / `hide_price`.

## 6. Empirical checks — RESULTS (run against the local Supabase stack, 2026-06-13)

All three checks **passed** after applying 0005 + the seed upgrades via
`supabase db reset` (`ON_ERROR_STOP=1`):

- **E-1 (item 4) — PASS.** `pg_roles`: `ardosia_app` and `ardosia_catalog` are both
  `rolbypassrls=f, rolsuper=f, rolcanlogin=t`; `postgres` and `service_role` are
  `rolbypassrls=t`. So the policies genuinely bind the two app roles, and the
  bypass/provisioning path is correctly limited to postgres/service_role. *Still to
  confirm on cloud only:* that `ardosia_app` authenticates through Supavisor under the
  `ardosia_app.<project-ref>` username form (a deploy-time check; cannot be done locally).
- **E-2 (item 11) — PASS.** `unaccent` resolves to schema `public`;
  `f_unaccent('açúcar') = 'acucar'`; `ix_product_name_search`, `uq_category_name`,
  `uq_tag_name` all exist with `indisvalid=t`; a real `ardosia_app` tenant-scoped
  product insert through the `f_unaccent` expression index succeeds, and
  `has_function_privilege('ardosia_app','public.unaccent(text)','EXECUTE')=t` (via the
  default PUBLIC grant — so the benign `no privileges were granted for "unaccent"`
  warning during 0002 is exactly that: benign).
- **E-3 — PASS.** `supabase db reset` applied 0001–0005 and ran all **14** seed assert
  groups green (8 composite-FK edges; RLS+FORCE; SELECT/WRITE isolation; checkout-log
  immutability; image swap; tenant_user takeover blocked; **app.tenant_id sole mechanism
  / claims ignored / fail-closed**; app privilege surface; per-table policy command-set;
  resolvers + soft-delete filtering; catalog role surface + behaviour). **Confirm CI
  invokes the seed with `ON_ERROR_STOP=1`** (the asserts only abort the run with that
  flag; `supabase db reset` sets it).

**Design T confirmed live:** `current_tenant_id()` is now `prosecdef=f` (no
`SECURITY DEFINER`) and no longer references `auth.jwt` — a pure `app.tenant_id` read.

---

## 7. Status of this session

- **Written:** this review (`docs/schema-security-review.md`).
- **Applied + validated:** `0005_resolvers_single_guc_and_catalog_role.sql` (Design T
  single-GUC `current_tenant_id()`, three `SECURITY DEFINER` resolvers, read-only
  `ardosia_catalog` role); seed upgrades (8-edge composite-FK assert, Design-T ASSERT 8,
  per-table command-set ASSERT 10, resolver ASSERT 11, catalog-role ASSERT 12). Full
  `db reset` green; E-1/E-2/E-3 verified.
- **Still open (app-layer, not schema):**
  - **M-3 / ROI-95** — env layer: remove `NEXT_PUBLIC_SUPABASE_*` from `clientSchema`,
    add server-only `DATABASE_URL` (ardosia_app) + catalog/service-role creds, rewrite
    `.env.example` + `docs/env-vars.md`.
  - **L-1** — define a `service_role` LGPD redaction path for `checkout_event` PII.
  - Invariants `INV-1..7` (§5) become the test specs for ROI-26 / ROI-74.
  - Cloud-only: E-1 pooler-username confirmation at deploy time.

*No application code written — the schema gate is now clear.*
