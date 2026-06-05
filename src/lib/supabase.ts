import { createClient } from "@supabase/supabase-js";
import { clientEnv } from "@/env/client";

/**
 * Server-side Supabase client.
 *
 * Uses the *restricted* (publishable / anon) key, which is bound to the
 * RLS-enforced `anon` Postgres role — NOT the `service_role` key, which would
 * bypass Row Level Security. Reads therefore only return rows allowed by an
 * explicit RLS policy (see `supabase/migrations/`).
 *
 * Both values are public by design: the URL and publishable key are safe to
 * expose, so they use the `NEXT_PUBLIC_` prefix. The same slots accept either a
 * legacy anon key (`eyJ...`) or a new-style publishable key (`sb_publishable_...`).
 */
export const supabase = createClient(
  clientEnv.NEXT_PUBLIC_SUPABASE_URL,
  clientEnv.NEXT_PUBLIC_SUPABASE_ANON_KEY,
);
