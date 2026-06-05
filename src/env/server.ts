import "server-only";
import { z } from "zod";

/**
 * Server-only environment variables. These are NEVER inlined into the browser
 * bundle — the `server-only` import makes importing this module from a Client
 * Component a build error, so secrets can't leak. Validated once at module load.
 */
const serverSchema = z.object({
  CLERK_SECRET_KEY: z.string().min(1),
  REDIS_URL: z.url(),
  REDIS_TOKEN: z.string().min(1),
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
