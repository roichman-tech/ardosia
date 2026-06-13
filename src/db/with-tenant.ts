import "server-only";

import { sql } from "drizzle-orm";
import { z } from "zod";

import type { appDb } from "./clients";

/**
 * Both restricted-role clients are built by the same `makeClient` with no schema,
 * so a single type describes either one — `withTenant` is identical for the
 * dashboard (`appDb`) and the catalog (`catalogDb`); only the pool differs.
 */
type RestrictedClient = typeof appDb;

/** The transaction handle Drizzle hands the callback — inferred, never hand-rolled. */
type TenantTx = Parameters<Parameters<RestrictedClient["transaction"]>[0]>[0];

// The resolvers (resolve_tenant_for_user / _by_slug) always return a uuid. Parsing
// here is the app-layer fail-closed guard (INV-2): an empty string, null, or any
// non-uuid throws *before* a transaction opens, so we never run tenant-scoped work
// with no — or a malformed — context. (Even if a bad value slipped through, RLS
// would match zero rows; this turns that silent-empty into a loud throw.)
const tenantUuid = z.uuid({
  message: "tenantId must be a resolved tenant uuid",
});

/**
 * Run `work` with the tenant RLS context set for exactly one transaction.
 *
 * INV-2 — the invariant that silently leaks cross-tenant data if violated:
 *   - a SINGLE transaction wraps the context-set and all the work;
 *   - `set_config('app.tenant_id', …)` is the FIRST statement;
 *   - the third arg is `true` (is_local) so the GUC is scoped to *this*
 *     transaction and is gone the instant it commits/rolls back.
 *
 * Why `true` is non-negotiable: Supavisor reuses pooled backends across requests.
 * A bare `SET`, or `set_config(…, false)`, would leave `app.tenant_id` set on the
 * backend for whatever request lands on it next — a cross-tenant leak. is_local =
 * true binds the value to the transaction's lifetime, so the next request starts
 * with no context (RLS matches nothing — fail closed).
 *
 * `tenantId` must come from a resolver (server-side, validated), never from client
 * input — INV-1. This helper enforces only that it *looks* like a resolved uuid;
 * the caller is responsible for it having a trustworthy *source*.
 *
 * @example
 *   const tenantId = await resolve_tenant_for_user(validatedClerkSub); // outside
 *   const products = await withTenant(appDb, tenantId, (tx) =>
 *     tx.select().from(product),
 *   );
 */
export function withTenant<T>(
  db: RestrictedClient,
  tenantId: string,
  work: (tx: TenantTx) => Promise<T>,
): Promise<T> {
  const id = tenantUuid.parse(tenantId);

  return db.transaction(async (tx) => {
    // FIRST statement. is_local = true. Both are load-bearing — see above.
    await tx.execute(sql`select set_config('app.tenant_id', ${id}, true)`);
    return work(tx);
  });
}
