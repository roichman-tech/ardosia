import { connection } from "next/server";
import { supabase } from "@/lib/supabase";

// Opt into dynamic rendering so the Supabase read runs at request time on every
// environment (local / preview / production) rather than being frozen at build.
export const dynamic = "force-dynamic";

export default async function HelloPage() {
  await connection();

  const { data, error } = await supabase
    .from("greetings")
    .select("message")
    .limit(1)
    .maybeSingle();

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-4 p-16 font-sans">
      <h1 className="text-3xl font-semibold tracking-tight">Supabase says:</h1>
      {error && <p className="text-red-600">Error: {error.message}</p>}

      {!error && data && (
        <p className="text-2xl text-green-600">{data.message}</p>
      )}
      
      {!error && !data && (
        <p className="text-zinc-500">
          No rows returned. Check that the <code>greetings</code> table exists,
          has a row, and has an RLS <code>SELECT</code> policy for the{" "}
          <code>anon</code> role.
        </p>
      )}
    </main>
  );
}
