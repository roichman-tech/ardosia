import "server-only";
import { z } from "zod";

/**
 * Server-only environment variables. These are NEVER inlined into the browser
 * bundle — the `server-only` import makes importing this module from a Client
 * Component a build error, so secrets can't leak. Validated once at module load.
 */
// A Supavisor pooler connection string. Both restricted-role URLs share this
// shape; only the role in the username differs (ardosia_app.<ref> vs
// ardosia_catalog.<ref>). Kept server-only — a DB-reachable credential must
// never carry a NEXT_PUBLIC_ prefix or reach the browser bundle.
const dbConnectionString = z
  .string()
  .startsWith("postgres", "must be a postgres:// connection string");

const serverSchema = z.object({
  CLERK_SECRET_KEY: z.string().min(1),
  REDIS_URL: z.url(),
  REDIS_TOKEN: z.string().min(1),
  // ardosia_app — authenticated owner dashboard, full tenant-scoped DML.
  APP_DATABASE_URL: dbConnectionString,
  // ardosia_catalog — public catalog path, read-only + checkout_event INSERT.
  CATALOG_DATABASE_URL: dbConnectionString,
});

// Server vars are read at runtime (not inlined), so parsing `process.env`
// directly is safe — Zod picks out the keys it knows about.
const parsed = serverSchema.safeParse(process.env);

if (!parsed.success) {
  const details = parsed.error.issues
    .map((issue) => `  - ${issue.path.join(".")}: ${issue.message}`)
    .join("\n");

  throw new Error(`Invalid server environment variables:\n${details}`);
}

export const serverEnv = parsed.data;
