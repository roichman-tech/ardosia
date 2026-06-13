# Environment variables — local, preview & production

The same set of keys must exist in three places. `.env.example` is the source of
truth for which keys are needed; this doc covers **where** each value comes from
and **how** to wire it per environment.

| Variable | Source | Scope | Local | Preview | Production |
| --- | --- | --- | --- | --- | --- |
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | Clerk → API Keys | browser | test | test | live |
| `CLERK_SECRET_KEY` | Clerk → API Keys | server | test | test | live |
| `REDIS_URL` | Upstash → REST API | server | ✅ | ✅ | ✅ |
| `REDIS_TOKEN` | Upstash → REST API | server | ✅ | ✅ | ✅ |
| `APP_DATABASE_URL` | Supabase → pooler (role `ardosia_app`) | **server-only** | ✅ | ✅ | ✅ |
| `CATALOG_DATABASE_URL` | Supabase → pooler (role `ardosia_catalog`) | **server-only** | ✅ | ✅ | ✅ |

## The database access model (BFF, two restricted roles)

There is **no browser database key**. The app talks to Postgres only from the
server (the SSR/BFF layer), through `src/db` — `src/env/server.ts` is behind
`import "server-only"`, so a DB credential can never be inlined into the client
bundle. Do **not** give any `DATABASE_URL` a `NEXT_PUBLIC_` prefix in any
environment.

Two roles, **two connection strings**, two Drizzle clients (you authenticate *as*
the role through Supavisor, so it's a separate string per role — not `SET ROLE`):

- **`APP_DATABASE_URL`** → role `ardosia_app` — the authenticated owner dashboard.
  Full tenant-scoped DML (SELECT/INSERT/UPDATE/DELETE under RLS).
- **`CATALOG_DATABASE_URL`** → role `ardosia_catalog` — the public catalog path.
  SELECT on the catalog graph + INSERT on `checkout_event*` only. A write bug on
  the public path is therefore a denied-privilege error, not a tenant-data
  incident.

Both roles are `NOBYPASSRLS` + FORCE RLS. Every tenant-scoped query runs inside
`withTenant(db, tenantId, …)`, which sets `app.tenant_id` for one transaction
(see `src/db/with-tenant.ts`). `tenantId` always comes from a server-side
resolver (`resolve_tenant_for_user` for the dashboard, `resolve_tenant_by_slug` /
`resolve_tenant_by_custom_domain` for the catalog), never from client input.

The `service_role` provisioning/webhook credential (first-tenant creation, Clerk
`user.deleted`) is **not** part of this module — it is owned separately (ROI-66)
and is likewise server-only.

### Connection string shape

Use the **transaction**-mode pooler (Supabase → Project Settings → Database →
Connection pooling), port `6543`. The username carries the role and project ref:

```
postgres://ardosia_app.<project-ref>:<password>@<region>.pooler.supabase.com:6543/postgres
postgres://ardosia_catalog.<project-ref>:<password>@<region>.pooler.supabase.com:6543/postgres
```

`src/db/clients.ts` connects with `prepare: false` because transaction-mode
pooling cannot carry prepared statements across reused backends.

### Out-of-band prerequisite (not code)

The two roles are created by the migrations but their passwords are never
committed. Set them once per environment (local / preview / production) before
the strings can authenticate:

```sql
ALTER ROLE ardosia_app     PASSWORD '<from secrets manager>';
ALTER ROLE ardosia_catalog PASSWORD '<from secrets manager>';
```

## Local

Copy `.env.example` → `.env` and fill in values. For local Postgres, run
`supabase start` and `supabase db reset` (applies `supabase/migrations/0001..0005`
and the seed), then point `APP_DATABASE_URL` / `CATALOG_DATABASE_URL` at the local
pooler.

## Vercel (Preview + Production)

Project → **Settings → Environment Variables**. Add every row above, ticking the
**Preview** and **Production** scopes. `NEXT_PUBLIC_*` vars are inlined at build
time, so each environment builds with its own values. The server-only vars
(everything not `NEXT_PUBLIC_`, including both `*_DATABASE_URL`s) are read at
runtime and never reach the browser — audit that no DB credential carries a
`NEXT_PUBLIC_` prefix in any environment.
