# Environment variables — local, preview & production (ROI-22)

The same set of keys must exist in three places. `.env.example` is the source of
truth for which keys are needed; this doc covers **where** each value comes from
and **how** to wire it per environment.

| Variable | Source | Local | Preview | Production |
| --- | --- | --- | --- | --- |
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | Clerk → API Keys | test | test | live |
| `CLERK_SECRET_KEY` | Clerk → API Keys | test | test | live |
| `REDIS_URL` | Upstash → REST API | ✅ | ✅ | ✅ |
| `REDIS_TOKEN` | Upstash → REST API | ✅ | ✅ | ✅ |

## Local

Copy `.env.example` → `.env` and fill in values. `bun dev`, then open
`/hello` — it should render the seeded greeting.

## Vercel (Preview + Production)

Project → **Settings → Environment Variables**. Add every row above, ticking the
**Preview** and **Production** scopes (and Development if you want Vercel to own
local too). `NEXT_PUBLIC_*` vars are inlined at build time, so each environment
builds with its own values — a preview deploy reads the database independently of
production.

## Database setup

Run `supabase/migrations/0001_greetings.sql` against the project (Supabase
Dashboard → SQL Editor, or `supabase db push`). It creates the `greetings`
table, seeds one row, enables RLS, and adds the `anon` SELECT policy that lets
the restricted key read the row.

## Done / DoD

`/hello` on a Vercel **preview** deploy renders `Hello from Supabase 👋` (one row
read with the restricted key).
