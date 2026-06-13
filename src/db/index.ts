import "server-only";

/**
 * Server-only database access for Ardosia's BFF.
 *
 * Two restricted-role clients ({@link appDb}, {@link catalogDb}) — never the
 * service_role — and one helper, {@link withTenant}, that sets the per-transaction
 * tenant RLS context. Resolve the tenant first (a plain query via the
 * resolve_tenant_* functions), then run every tenant-scoped query inside
 * `withTenant`. See `docs/env-vars.md` and `docs/security-reviews/`.
 */
export { appDb, catalogDb, type Database } from "./clients";
export { withTenant } from "./with-tenant";
