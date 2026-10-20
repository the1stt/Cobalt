# Cobalt: ledger foundation (Day 1 to 3 core)

Simulated US digital bank. This folder holds the part that decides whether the project is credible: the database ledger. The Next.js app comes next and only calls these functions.

## What is here

- supabase/migrations/20261019000000_ledger_core.sql: schema, invariants, money functions, RLS
- supabase/migrations/20261019000001_onboarding_and_hardening.sql: onboarding functions and hardening fixes
- tests/ledger_test.sh: 69 checks, including real concurrency tests

## Apply it

Supabase SQL editor: paste each migration, in filename order, and run it. The second one is safe to re-run.
Or with the CLI: copy the files into your repo's supabase/migrations folder and run supabase db push.

## Run the tests

Needs a local Postgres 15+ and a superuser:

    PGHOST=localhost PGUSER=postgres ./tests/ledger_test.sh

The script creates and drops a scratch database called cobalt_test. It stubs the Supabase auth schema, so it runs without Supabase.

## Money model

- Integer minor units (cents) in bigint. No floats anywhere.
- balance = credits minus debits. A debit lowers an account, a credit raises it.
- Every movement is a transaction with at least two entries that sum to zero.
- ledger_entries is append-only. Corrections are compensating transactions.
- System accounts (External Funding, Merchant Settlement, Fees, Suspense) are the other side of anything that enters or leaves the bank. They may go negative, customer accounts may not.

## What the database enforces (not the app)

- Unbalanced transactions fail at COMMIT (deferred constraint trigger).
- Entries cannot be updated, deleted or truncated.
- Customer balances cannot go below zero (CHECK constraint), as a backstop behind the insufficient_funds check.
- Cached balances move inside the same statement as the entries, so they cannot drift. reconcile_ledger() proves it.
- Two accounts are always locked in id order, so opposite transfers cannot deadlock.
- Limits are read after the lock, so parallel transfers cannot both slip past a daily limit.
- Each user has exactly one main account (unique partial index).
- Onboarding rules (reserved handles, 18+, US address shape) are validated in the database, not just the form.
- Clients have read-only access to their own rows. All writes go through security definer functions.

## Functions

- complete_onboarding(handle, full_name, date_of_birth, address): creates the caller's profile, and through it the main account. The only way a customer comes into existence
- is_handle_available(handle): boolean, for the live check on the onboarding form
- post_transfer(from, to, amount, reference, idempotency_key)
- post_topup(amount, idempotency_key): sandbox funding from the External Funding account
- find_recipient(handle): returns account id and display name only
- reconcile_ledger(): service role only

Error messages the app should map to friendly text: insufficient_funds, per_txn_limit_exceeded, daily_limit_exceeded, account_frozen, recipient_not_found, recipient_closed, forbidden_account, same_account, invalid_amount, idempotency_key_reused, idempotency_key_required, topup_limit_exceeded, not_authenticated, already_onboarded, invalid_handle, handle_reserved, handle_taken, invalid_name, invalid_date_of_birth, under_18, invalid_address.

## Idempotency contract for the client

Generate one key per user intent (when the confirm screen opens), reuse it on retries and double-clicks, and generate a new one for a new payment. A replay returns the original response with replayed: true. Reusing a key with a different payload is an error.

## Known gaps (planned)

- No velocity rules, held transfers or audit log yet (Day 6 and 7).
- Pots, purchases and round-ups reuse ledger_post, to be exposed as functions on Day 5.
- Rolling 24 hour daily limit, not calendar day. Account numbers are random 12 digit with a unique constraint, retried up to 5 times on collision.
- A superuser can disable triggers. In production, the service role key stays server-side only.
