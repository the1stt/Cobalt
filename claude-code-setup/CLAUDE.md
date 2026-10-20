# Cobalt

Simulated US digital bank, built to show correct money-moving software.
Sandbox only: no real money, no FDIC claims. Spec: docs/ (PRD). The PRD header says
"Kobo"; the project name is Cobalt.

## Layout
- supabase/migrations/  SQL, applied in filename order. NEVER edit an applied migration; add a new one.
- tests/ledger_test.sh  DB tests incl. real concurrency. Run: PGHOST=localhost PGUSER=postgres ./tests/ledger_test.sh
- web/                  Next.js 16 (App Router, TypeScript, Tailwind), src/ directory
- docs/                 PRD, decisions.md

## Commands (from web/)
- npm run dev | npm run lint | npx tsc --noEmit | npm run build

## Money rules (non-negotiable)
- Integer cents only: bigint in Postgres, integer number of cents in TypeScript. No floats,
  no parseFloat on money, no decimals in JSON. Format with src/lib/money.ts.
- Every balance change goes through a security definer Postgres function called via RPC.
  The app never inserts or updates accounts, transactions or ledger_entries directly.
- ledger_entries is append-only. Mistakes are fixed with compensating transactions.
- Every money-moving call carries an idempotency key: one key per user intent, reused on retries.
- Never weaken a constraint, trigger or RLS policy to make a test pass. Find the real cause.

## Security rules
- The service role key is server-only: never in client code, never in NEXT_PUBLIC_*, never committed.
- Do not read .env* files. Ask the human if a value is needed.
- On the server verify identity with supabase.auth.getClaims(). Never trust getSession().
- Validate all input with Zod. RLS on every table; clients read their own rows only.

## Conventions
- Next.js 16: the file is src/proxy.ts (not middleware.ts). searchParams and params are Promises.
- Supabase clients live in src/lib/supabase/{client,server,proxy}.ts. Create one per request.
- Server actions for mutations. Map database error strings to friendly messages.
- Small commits ("feat:", "fix:", "test:"). Run lint and tsc before committing. Never push without asking.
- Record any design or scope decision in docs/decisions.md.

## Database error strings the app must map to friendly text
insufficient_funds, per_txn_limit_exceeded, daily_limit_exceeded, account_frozen,
recipient_not_found, recipient_closed, forbidden_account, same_account, invalid_amount,
idempotency_key_reused, idempotency_key_required, topup_limit_exceeded, not_authenticated,
already_onboarded, invalid_handle, handle_reserved, handle_taken, invalid_name,
invalid_date_of_birth, under_18, invalid_address

## Status
Done: ledger core migration, onboarding + hardening migration, auth scaffold
(login, signup, logout, /auth/confirm, proxy, (app) layout gating).
Written but never compiled or run: everything in web/ and the 19 newest checks in tests/ledger_test.sh.
Next: onboarding form calling complete_onboarding, then transfers UI, feed + realtime,
purchases / pots / round-ups, notifications / velocity rules / admin / audit log, tests, polish.

## Known later work
- Feed needs counterparty names: RLS hides the other leg of a transfer, so add a security definer function.
- Add tables to the Supabase Realtime publication (Day 4).
- Rate limiting on login and transfers. Fake routing number is an app constant.
- Turn Confirm email back ON before the demo and switch the email template to token_hash.
