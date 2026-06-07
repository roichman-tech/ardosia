# Ardosia — by Roichman Tech
## Stack decision — definitive v1

Consistent with `ardosia_schema.sql` v1 and `ardosia_feature_map.md` v1.
Status: **closed**. All eight decisions resolved, including the two founder tradeoffs.

---

## Decision summary

| Layer | Decision | Runner-up | Runner-up wins if |
|---|---|---|---|
| Public read path | Server-side, inside the app's server layer | PostgREST `anon` policies | Never, for this product |
| Catalog frontend | Next.js App Router (RSC; cart = only client island) | Astro + Preact island | Perf budget fails on real device (see §2) |
| Dashboard | Same Next app, separated by host | Vite + TanStack Router SPA | Dashboard becomes the suite-wide backoffice |
| Backend | Next route handlers; domain logic in `/core` | Separate Hono service | A second real consumer of the same logic exists |
| Hosting | **Vercel Pro** (founder-decided) | DO droplet + Caddy + Coolify | Vercel usage bill exceeds ~$50–60/mo |
| Database | Supabase Postgres (restricted role + `app.tenant_id`) | Postgres on DO | Leaving Supabase |
| Storage / images | Supabase Storage + pre-generated variants at upload | Cloudflare R2 | Egress shows up on the bill |
| Rate limiting | Upstash Redis (free tier) on checkout endpoint | Vercel WAF rules | — |
| Analytics seam | Server-side `emit()` + first-party beacon | — | — |
| Migrations | Plain SQL (Supabase CLI); Drizzle via `pull` for typed queries only | — | — |
| Repo topology | Single repo, single app | Workspace/monorepo split | Second suite product is born |

---

## 1. Public read path — server-side (b)

**Decision:** all public reads go through the catalog app's server layer. RLS stays enabled as defense-in-depth, not as the primary boundary. No separate backend service — the SSR layer *is* the backend.

**Why (a) — PostgREST `anon` reads — is dead, on two grounds independent of RLS quality:**

1. Constraint 3 (SEO + speed on mid-range Android / 4G) requires SSR. SSR means a server process already reads Postgres. Client-side PostgREST would not remove the backend, only add a second public read path beside it.
2. Checkout requires a server-side write regardless. The schema's snapshot-by-value only has integrity if the server recomputes prices from the database. Anonymous `INSERT` on an immutable log table, exposed to the public internet, is an unthrottleable spam vector; building the message client-side would ship `checkout_template` and total logic to the browser.

The founder's own audit experience with `anon` policies is the third reason, not the first.

**Schema consequence:** public reads carry no JWT, so `current_tenant_id()` as written (reads `auth.jwt()`) does not cover this path. To keep RLS meaningful:
- Connect with a restricted Postgres role (not service role)
- `set_config('app.tenant_id', <uuid>, true)` per transaction
- `current_tenant_id()` becomes `COALESCE(<jwt claim path>, current_setting('app.tenant_id', true)::uuid)`

This is part of the migration the schema comment reserved for "leaving Supabase," done on day 1.

**Strongest counter-argument (accepted):** this demotes Supabase to "managed Postgres + Storage + CLI." Defensible at $25/mo, but acknowledged: PostgREST and Supabase Auth go unused.

---

## 2. Catalog frontend — Next.js App Router

**Decision:** Next.js, server components throughout, cart as the only client island. Filters and sorting are server-rendered via query params (work without JS). Per-tenant theming = accent color CSS variable injected in the layout at render time.

**Weakest point, stated first:** Next's JS baseline (~90–120 KB gz React/Next runtime) is the worst number among serious options for mid-range Android on 4G. LCP is fine (server-rendered HTML + image); the real risk is parse/execute cost on weak CPUs (TTI/INP).

**Independent merits (not familiarity):**
- Host-based multi-tenant routing via middleware is the most documented pattern in any ecosystem (Vercel Platforms pattern — use as *reading reference only*, do not fork)
- Clerk's most mature SDK is the Next one (middleware, session validation, components)
- One application covers decisions 2, 3, and 4 — decisive for a solo maintainer

**Founder-accepted condition (binding):** performance budget defined *before* build — **LCP < 2.5 s, TTI < 4 s on Moto G-class Android, throttled 4G** — tested at the end of build step 2. If it fails, the catalog switches to Astro + Preact island before step 3. Deciding in week 2 is cheap; after the dashboard is built, it is not.

---

## 3. Dashboard — same Next app, separated by host

**Decision:** `app.ardosia.app`, routed by middleware to the `(dashboard)` route group. Clerk auth. CRUD via route handlers + TanStack Query (or server actions — taste, not architecture).

**Counter-argument (accepted):** deploy coupling — a bad dashboard deploy redeploys the catalog. Mitigated by Vercel atomic deploys + instant rollback + preview deploys.

**Split condition:** the dashboard becomes the shared backoffice of the Roichman suite. Not before.

---

## 4. Backend — no separate service; `/core` is the boundary

**Decision:** Next route handlers hold catalog reads (Drizzle → Supabase pooler, restricted role + `app.tenant_id`), checkout write + message building + `wa.me` redirect, Clerk validation (middleware), `user.deleted` webhook. Provisioning is a CLI script in the repo.

**The separation that matters is module, not network:**

```
src/core    → pricing, message building, checkout, provisioning logic
              Pure TypeScript. Zero imports from next/* or react.
              Enforced by ESLint rule. Unit-testable in isolation.
src/app/api → thin handlers: parse → call core → serialize
```

**Why not a separate Hono service:** either Next SSR calls Hono over HTTP (a network hop on the hottest path, against constraint 3, plus service-to-service auth that didn't exist) or Next reads Postgres directly and Hono only writes (domain logic — e.g. price visibility — split across two services: *worse* separation of responsibilities). Plus: second deploy, second pipeline, second secrets set, CORS, version skew, and a new failure mode against constraint 5.

**Middle path (available, not chosen):** mount a Hono app inside Next via catch-all route handler (`src/app/api/[...route]/route.ts` + Vercel adapter). Same single deployment, Hono idioms, extraction later = swap the adapter.

**Extraction condition:** a second real consumer (mobile app, second suite product). With `/core` isolated, extraction is a day's work of thin handlers.

**Operational note:** checkout endpoint rate limiting cannot be in-memory on serverless → Upstash Redis (free tier). If Upstash is down, checkout degrades to "no throttle," not "down" — constraint 5 holds.

---

## 5. Hosting & multi-tenant routing — Vercel Pro (founder-decided)

**Decision:** Vercel Pro ($20/mo) from launch (Hobby prohibits commercial use). Project domains: `ardosia.app`, `*.ardosia.app` (wildcard requires Vercel nameservers for the apex), plus each merchant custom domain attached individually via Domains API. Unlimited custom domains per project; automatic TLS on all of them — constraint 4 satisfied with zero manual certificate work.

**The known trap, disarmed on day 1:** Vercel usage pricing — in an image-heavy product, Vercel Image Optimization left enabled is the guaranteed surprise bill. **`images.unoptimized = true` in `next.config`**; images are solved in §6. Remaining catalog traffic for small-town merchants fits in Pro's $20 included usage for a long time.

**Runner-up:** DO droplet ($12–24 fixed) + Caddy on-demand TLS (zero per-domain cost) + Coolify. Wins if the Vercel usage bill exceeds ~$50–60/mo or platform policy bites. Its cost is not money but ops ownership (patching, uptime, incidents).

**Host → tenant resolution (middleware, every request):**

```
clientsite.com.br             → tenant lookup by custom_domain
{slug}.ardosia.app            → tenant lookup by slug
app.ardosia.app               → rewrite to (dashboard) route group
```

Internal rewrite to `/(catalog)/[tenantId]/...`; the visitor only ever sees their domain. One indexed lookup per request; cache the host→tenant map with a short TTL.

**Custom domain flow (in `provision.ts`):**
1. Write `custom_domain` on the `tenant` row (column + unique index already in schema)
2. `POST /v10/projects/{id}/domains` (Vercel Domains API)
3. API returns DNS instructions (A record for apex, CNAME for `www`) → handed to the merchant, in pt-BR, pre-formatted by the script
4. DNS propagates → Vercel validates → TLS issued → live

**Real weak point of this flow:** step 3 — small-town merchants configuring DNS at Registro.br. Expect to do it for them at first. This is an argument for selling `{slug}.ardosia.app` as the default and custom domains as an upsell.

**Catalogs never live under a path** (`app.ardosia.app/{slug}` is wrong): it would break cookies, per-domain SEO, and clean theming. `app.` = dashboard only.

---

## 6. Storage & images — Supabase Storage + pre-generated variants

**Decision:** the right question is not "Supabase vs R2" but "on-the-fly transforms vs pre-generation." On-the-fly is a per-catalog tax (Supabase: $5 / 1,000 origin images beyond 100 on Pro; Vercel: the §5 trap).

- `sharp` in the upload route handler generates 3 WebP variants (~300w card, ~800w detail, original), stored under derived `storage_key`s
- Transformation cost: zero, forever
- Served from a public bucket behind Supabase Smart CDN (Pro: 100 GB storage, 250 GB egress included; cached overage $0.03/GB)

**Counter-argument (accepted):** rigidity — a new size requires a backfill script over all `storage_key`s. Acceptable: backfill is a for-loop and the design system is locked.

**Runner-up:** R2 (zero egress, $0.015/GB). The schema's opaque `storage_key` makes the swap an object sweep + config flip, by design.

---

## 7. Analytics seam — `emit()` + first-party beacon

**The detail that invalidates the naive answer:** if catalog pages are ISR/CDN-cached, server code does not run per view — server-side page views undercount exactly when the product succeeds. Two legs:

1. **Page views:** ~1 KB inline beacon → `POST /api/e` (first-party) → handler calls `emit()`
2. **Checkout:** the checkout handler calls `emit()` with the same payload as the `checkout_event` row

`emit()` in v1 is a no-op; the event contract (names + shapes) is documented in the repo. Later: fire-and-forget `fetch` to Tinybird Events API — never awaited on the critical path, failure-silent. Constraint 5 holds by construction; schema untouched.

**Accepted losses:** ~1 KB of JS on a minimal-JS catalog; ad-blocker undercount on page views. `checkout_event` in Postgres remains the durable record.

---

## 8. Repo & deploy — one repo

**`ardosia`** — private, GitHub, Vercel git integration. No second repo, no shared packages until the second suite product exists (then: move into a pnpm/turborepo workspace and promote `/core` — an import refactor, cheap).

```
ardosia/
├── src/                    # all application source
│   ├── app/
│   │   ├── (catalog)/      # public routes, resolved by host in middleware
│   │   ├── (dashboard)/    # app.ardosia.app, Clerk
│   │   └── api/            # checkout, beacon (/api/e), Clerk webhook, upload
│   ├── core/               # pure TS domain logic — no next/* imports (lint-enforced)
│   ├── db/
│   │   └── schema.gen.ts   # drizzle-kit pull output; never hand-edited (CI diff check)
│   ├── lib/                # shared helpers (Supabase/Clerk clients, utils)
│   ├── env/                # validated environment access
│   └── proxy.ts            # host→tenant middleware entry
├── supabase/               # stays at repo root, outside src/ (Supabase CLI convention)
│   ├── migrations/         # plain SQL — source of truth (schema v1 = 0001)
│   └── seed.sql            # 2 fake tenants
├── scripts/
│   └── provision.ts        # tenant + Clerk link + Vercel Domains API (attach AND detach)
└── .github/workflows/ci.yml
```

- **Migrations: plain SQL** via Supabase CLI. The schema uses triggers, partial indexes on `f_unaccent`, and a DEFERRABLE constraint — exactly what ORM-first migration tools handle worst. Drizzle never migrates.
- **Drizzle for typed queries only**, via `drizzle-kit pull`. CI check: re-run `pull`, fail on diff.
- **Local dev:** `supabase start` (local Postgres stack in Docker) + seed.
- **CI minimum:** typecheck + lint + build + migration dry-run. App deploys via Vercel git integration. Migrations applied through a manual gate (`supabase db push`) — safer than unsupervised automation for a solo maintainer.

---

## Monthly cost estimate

| | 0 tenants (pre-launch) | 10 tenants | 50 tenants |
|---|---|---|---|
| Vercel | $0 (Hobby in dev) | $20 | $20 + ~$10–30 usage |
| Supabase | $0 (Free) | $25 (Pro — Free pauses idle projects; unusable in prod) | $25 |
| Clerk | $0 | $0 (free tier ≫ merchant count) | $0 |
| Upstash | $0 | $0 | $0 |
| Domain | ~$2 | ~$2 | ~$2 |
| **Total** | **~$2** | **~$47** | **~$60–80** |

Per tenant: ~$4.70 at 10, ~$1.30–1.60 at 50. Margin requires merchant pricing above ~R$50/mo.

---

## Build order

1. Repo + `supabase start` + migrations applied + seed (2 fake tenants)
2. Host→tenant middleware + catalog SSR (list, detail, query-param filters, accent theming) → **run the §2 performance budget test here**
3. Cart (client island) + checkout handler (server-side price recompute, persist event, build message, rate limit) + `wa.me` redirect
4. Clerk + dashboard CRUD (products → images with variant pipeline → features/options → categories/tags → brand)
5. `provision.ts` (tenant + Clerk link + Vercel Domains API)
6. Beacon + `emit()` + documented event contract
7. RLS policies on every table + contrast validation + launch with 1 real merchant

---

## Backlog (registered, not v1)

- `provision.ts` inverse command: detach custom domain (Vercel `DELETE` + clear column) — without it, dead domains accumulate on the project pointing at soft-deleted tenants
- wa.me message-length guard revisit (carried from feature map)
- Category `sort_order` (carried from feature map)
- `/core` extraction to a shared package — trigger: second suite product