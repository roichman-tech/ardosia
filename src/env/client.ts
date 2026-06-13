import { z } from "zod";

/**
 * Client (browser-exposed) environment variables. Every key here is inlined into
 * the JS bundle at build time, so it must be `NEXT_PUBLIC_`-prefixed and safe to
 * expose. Validated once at module load — a missing/invalid value fails fast.
 */
const clientSchema = z.object({
  NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY: z.string().min(1),
});

// `NEXT_PUBLIC_*` vars are inlined at build time, so each must be referenced
// statically by name — a dynamic lookup (`process.env[key]`) would not inline.
const parsed = clientSchema.safeParse({
  NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY:
    process.env.NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY,
});

if (!parsed.success) {
  const details = parsed.error.issues
    .map((issue) => `  - ${issue.path.join(".")}: ${issue.message}`)
    .join("\n");

  throw new Error(`Invalid client environment variables:\n${details}`);
}

export const clientEnv = parsed.data;
