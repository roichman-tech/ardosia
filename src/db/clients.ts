import "server-only";

import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";

import { serverEnv } from "@/env/server";

/**
 * The two restricted-role database clients.
 *
 * There are two *roles* — `ardosia_app` (full owner DML) and `ardosia_catalog`
 * (SELECT on the catalog graph + INSERT on checkout_event* only) — and under
 * Supavisor you authenticate *as* the role, so each role is a distinct
 * connection string and therefore a distinct client (NOT `SET ROLE` on a shared
 * connection). Picking the wrong client is a privilege error, not a silent
 * over-grant — which is the whole point of having two.
 *
 * Both roles are NOBYPASSRLS + FORCE RLS, so every query they issue is scoped by
 * the tenant policies to `current_tenant_id()` — see {@link withTenant}, which is
 * how that GUC gets set. Neither client is the `service_role` provisioning client
 * (ROI-66); that bypass path is deliberately absent here.
 */

// Supavisor runs in transaction pool mode, which cannot carry prepared
// statements across pooled backends — `prepare: false` is mandatory, not an
// optimization. Without it, the second query on a reused backend errors.
function makeClient(connectionString: string) {
  const sql = postgres(connectionString, { prepare: false });
  return drizzle(sql);
}

// Module-level singletons: a Drizzle client owns a connection pool, so we create
// one per role for the lifetime of the server process rather than per request.
// `server-only` (above) guarantees this module — and therefore the credentials —
// never reaches the browser bundle.

/** Authenticated owner dashboard. Resolve the tenant via `resolve_tenant_for_user`. */
export const appDb = makeClient(serverEnv.APP_DATABASE_URL);

/** Public catalog path. Resolve the tenant via `resolve_tenant_by_slug` / `_custom_domain`. */
export const catalogDb = makeClient(serverEnv.CATALOG_DATABASE_URL);

export type Database = typeof appDb;
