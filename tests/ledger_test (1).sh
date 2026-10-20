#!/usr/bin/env bash
# Cobalt ledger tests. Requires a local Postgres 15+ and a superuser connection.
# Usage: PGHOST=localhost PGUSER=postgres ./tests/ledger_test.sh
# It creates and drops a scratch database called cobalt_test.

set -u
cd "$(dirname "$0")/.."

DB=cobalt_test
PASS=0
FAIL=0

psql_admin() { psql -X -q -t -A -d postgres "$@"; }
q()          { psql -X -q -t -A -d "$DB" -c "$1" 2>&1; }

ok()   { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        got: $2"; }

# assert_eq <name> <expected> <actual>
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2)" "$3"; fi; }
# assert_err <name> <substring> <output>
assert_err() { if echo "$3" | grep -q "$2"; then ok "$1"; else bad "$1 (expected error containing '$2')" "$3"; fi; }

# run a statement as a given user id (sets the JWT subject GUC the auth.uid() stub reads)
as_user() { psql -X -q -t -A -d "$DB" -c "set request.jwt.claim.sub = '$1'; $2" 2>&1 | grep -v '^SET$'; }

echo "== setup"
psql_admin -c "drop database if exists $DB" >/dev/null
psql_admin -c "create database $DB" >/dev/null

psql -X -q -d "$DB" >/dev/null <<'SQL'
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema public, auth to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
SQL
for f in supabase/migrations/*.sql; do
  psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" >/dev/null || { echo "migration failed: $f"; exit 1; }
done

A=00000000-0000-0000-0000-00000000000a
B=00000000-0000-0000-0000-00000000000b
C=00000000-0000-0000-0000-00000000000c
q "insert into auth.users values ('$A'),('$B'),('$C');
   insert into profiles (id, handle, full_name) values
     ('$A','alice','Alice A'),('$B','bob','Bob B'),('$C','carol','Carol C');" >/dev/null
acct() { q "select id from accounts where owner_id='$1' and type='main'"; }
bal()  { q "select balance from accounts where id='$1'"; }
AA=$(acct $A); BA=$(acct $B); CA=$(acct $C)

echo "== basic money movement"
as_user $A "select post_topup(10000, 'topup-alice-0001')" >/dev/null
assert_eq "topup credits alice" 10000 "$(bal $AA)"
assert_eq "external funding went negative by same amount" -10000 "$(q "select balance from accounts where system_key='external_funding'")"

as_user $A "select post_transfer('$AA','$BA',2500,'rent','xfer-0001-aaaa')" >/dev/null
assert_eq "alice debited" 7500 "$(bal $AA)"
assert_eq "bob credited" 2500 "$(bal $BA)"

echo "== validation"
assert_err "insufficient funds rejected" insufficient_funds "$(as_user $A "select post_transfer('$AA','$BA',400000,'x','xfer-0002-aaaa')")"
assert_err "per-transaction limit enforced" per_txn_limit_exceeded "$(as_user $A "select post_transfer('$AA','$BA',600000,'x','xfer-0003-aaaa')")"
assert_err "cannot send from someone else's account" forbidden_account "$(as_user $A "select post_transfer('$BA','$AA',100,'x','xfer-0004-aaaa')")"
assert_err "cannot send to self" same_account "$(as_user $A "select post_transfer('$AA','$AA',100,'x','xfer-0005-aaaa')")"
assert_err "zero amount rejected" invalid_amount "$(as_user $A "select post_transfer('$AA','$BA',0,'x','xfer-0006-aaaa')")"
assert_err "negative amount rejected" invalid_amount "$(as_user $A "select post_transfer('$AA','$BA',-5,'x','xfer-0007-aaaa')")"
assert_err "unauthenticated rejected" not_authenticated "$(q "select post_transfer('$AA','$BA',100,'x','xfer-0008-aaaa')")"
assert_eq "failed attempts changed nothing (alice)" 7500 "$(bal $AA)"
assert_eq "failed attempts left no idempotency rows" 0 "$(q "select count(*) from idempotency_keys where key in ('xfer-0002-aaaa','xfer-0003-aaaa')")"

echo "== idempotency"
R1=$(as_user $A "select post_transfer('$AA','$BA',1000,'coffee','idem-key-0001')")
R2=$(as_user $A "select post_transfer('$AA','$BA',1000,'coffee','idem-key-0001')")
assert_eq "replay posts only once" 6500 "$(bal $AA)"
assert_err "replay is flagged" '"replayed": true' "$R2"
assert_eq "replay returns same transaction" "$(echo "$R1" | grep -o '"transaction_id": "[^"]*"')" "$(echo "$R2" | grep -o '"transaction_id": "[^"]*"')"
assert_err "same key with different payload rejected" idempotency_key_reused "$(as_user $A "select post_transfer('$AA','$BA',1001,'coffee','idem-key-0001')")"

echo "== ledger integrity at the database level"
assert_err "unbalanced transaction rejected at commit" unbalanced_transaction "$(q "
  begin;
  insert into transactions (id, type) values ('11111111-1111-1111-1111-111111111111','fee');
  insert into ledger_entries (transaction_id, account_id, direction, amount, currency) values
    ('11111111-1111-1111-1111-111111111111','$AA','credit',100,'USD'),
    ('11111111-1111-1111-1111-111111111111','$BA','debit',99,'USD');
  commit;")"
assert_err "single-entry transaction rejected" "unbalanced_transaction" "$(q "
  begin;
  insert into transactions (id, type) values ('22222222-2222-2222-2222-222222222222','fee');
  insert into ledger_entries (transaction_id, account_id, direction, amount, currency) values
    ('22222222-2222-2222-2222-222222222222','$AA','credit',100,'USD');
  commit;")"
assert_err "ledger entries cannot be updated" append-only "$(q "update ledger_entries set amount = 1")"
assert_err "ledger entries cannot be deleted" append-only "$(q "delete from ledger_entries")"
assert_err "ledger entries cannot be truncated" append-only "$(q "truncate ledger_entries")"
assert_err "transactions cannot be deleted" "cannot be deleted" "$(q "delete from transactions")"
assert_err "balance check blocks direct overdraft" no_overdraft "$(q "update accounts set balance = -1 where id='$AA'")"
assert_eq "reconciliation: ledger sums to zero" 0 "$(q "select reconcile_ledger()->>'ledger_sum'")"
assert_eq "reconciliation: no drifted balances" '[]' "$(q "select reconcile_ledger()->'balance_discrepancies'")"

echo "== account status"
q "update accounts set status='frozen' where id='$CA'" >/dev/null
as_user $A "select post_transfer('$AA','$CA',100,'to frozen','xfer-0009-aaaa')" >/dev/null
assert_eq "frozen account can still receive" 100 "$(bal $CA)"
assert_err "frozen account cannot send" account_frozen "$(as_user $C "select post_transfer('$CA','$AA',50,'x','xfer-0010-ccc')")"
q "update accounts set status='active' where id='$CA'" >/dev/null

echo "== row level security"
assert_eq "bob sees only his own account" 1 "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$B'; select count(*) from accounts" | grep -v SET)"
assert_eq "bob sees no one else's profile" 1 "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$B'; select count(*) from profiles" | grep -v SET)"
assert_err "client cannot insert ledger entries" "permission denied" "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$B'; insert into ledger_entries (transaction_id, account_id, direction, amount, currency) values (gen_random_uuid(), '$BA','credit',1,'USD')" 2>&1)"
assert_err "client cannot edit balances" "permission denied" "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$B'; update accounts set balance = 999999999" 2>&1)"
assert_eq "client cannot read idempotency keys (RLS, no policy)" 0 "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$B'; select count(*) from idempotency_keys" 2>&1 | grep -v SET)"
assert_err "client cannot call internal ledger_post" "permission denied" "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$B'; select ledger_post('transfer'::txn_type, null, 'x', null, '{}'::jsonb, '$BA'::uuid, '$AA'::uuid, 1)" 2>&1)"
assert_eq "recipient lookup works" "$BA|Bob B" "$(as_user $A "select account_id, display_name from find_recipient('BOB')")"

echo "== onboarding and hardening"
D=00000000-0000-0000-0000-00000000000d
E=00000000-0000-0000-0000-00000000000e
q "insert into auth.users values ('$D'),('$E');" >/dev/null
ADDR='{"street":"1 Main St","city":"Austin","state":"tx","zip":"78701"}'
BADZIP='{"street":"1 Main St","city":"Austin","state":"TX","zip":"7870"}'
BADST='{"street":"1 Main St","city":"Austin","state":"ZZ","zip":"78701"}'
U18=$(q "select (current_date - interval '17 years')::date")
onb() { as_user "$1" "select complete_onboarding('$2','$3','$4','$5'::jsonb)"; }

assert_err "onboarding requires login" not_authenticated "$(q "select complete_onboarding('dave_d','Dave D','1990-05-17','$ADDR'::jsonb)")"
assert_err "taken handle rejected, any case" handle_taken "$(onb $E ALICE 'Eve E' 1990-05-17 "$ADDR")"
assert_err "reserved handle rejected" handle_reserved "$(onb $E admin 'Eve E' 1990-05-17 "$ADDR")"
assert_err "malformed handle rejected" invalid_handle "$(onb $E 'a!' 'Eve E' 1990-05-17 "$ADDR")"
assert_err "under 18 rejected" under_18 "$(onb $E eve_e 'Eve E' "$U18" "$ADDR")"
assert_err "bad ZIP rejected" invalid_address "$(onb $E eve_e 'Eve E' 1990-05-17 "$BADZIP")"
assert_err "bad state rejected" invalid_address "$(onb $E eve_e 'Eve E' 1990-05-17 "$BADST")"
assert_eq "failed onboarding attempts created no profile" 0 "$(q "select count(*) from profiles where id='$E'")"

OUT=$(onb $D Dave_D 'Dave D' 1990-05-17 "$ADDR")
assert_err "valid onboarding succeeds" '"handle": "dave_d"' "$OUT"
assert_eq "handle stored lowercase, state uppercase" "dave_d|TX" "$(q "select handle::text || '|' || (address->>'state') from profiles where id='$D'")"
assert_eq "exactly one main account, zero balance" "1|0" "$(q "select count(*) || '|' || coalesce(sum(balance),0) from accounts where owner_id='$D' and type='main'")"
assert_err "second onboarding rejected" already_onboarded "$(onb $D dave_two 'Dave D' 1990-05-17 "$ADDR")"

assert_err "authenticated role can call it (grant works)" '"handle": "eve_e"' "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$E'; select complete_onboarding('eve_e','Eve E','1990-05-17','$ADDR'::jsonb)" 2>&1)"
assert_err "anon cannot call it" "permission denied" "$(psql -X -q -t -A -d $DB -c "set role anon; select complete_onboarding('zed_z','Zed Z','1990-05-17','$ADDR'::jsonb)" 2>&1)"
assert_err "client cannot insert a profile directly" "permission denied" "$(psql -X -q -t -A -d $DB -c "set role authenticated; set request.jwt.claim.sub='$E'; insert into profiles (id, handle, full_name) values ('$E','sneaky','Sneaky')" 2>&1)"

assert_eq "handle availability: taken" f "$(as_user $E "select is_handle_available('ALICE')")"
assert_eq "handle availability: free" t "$(as_user $E "select is_handle_available('fresh_handle')")"
assert_eq "handle availability: reserved" f "$(as_user $E "select is_handle_available('admin')")"
assert_err "second main account for a user blocked" accounts_one_main_per_owner "$(q "insert into accounts (owner_id, type, name) values ('$A','main','dup')")"

echo "== concurrency: 30 parallel transfers of \$10 from an account holding \$100"
q "select 1" >/dev/null
# reset alice to exactly 10000
CUR=$(bal $AA)
if [ "$CUR" -lt 10000 ]; then as_user $A "select post_topup($((10000-CUR)), 'topup-reset-0001')" >/dev/null; fi
if [ "$CUR" -gt 10000 ]; then as_user $A "select post_transfer('$AA','$CA',$((CUR-10000)),'drain','drain-key-0001')" >/dev/null; fi
assert_eq "alice starts with exactly 10000" 10000 "$(bal $AA)"
q "update accounts set daily_limit = 100000000 where id in ('$AA','$BA')" >/dev/null

seq 1 30 | xargs -P 30 -I{} psql -X -q -t -A -d "$DB" -c \
  "set request.jwt.claim.sub='$A'; select post_transfer('$AA','$BA',1000,'race','race-key-{}-aaaa')" \
  > /tmp/cobalt_race.out 2>&1
OKS=$(grep -c '"status": "posted"' /tmp/cobalt_race.out)
NSF=$(grep -c insufficient_funds /tmp/cobalt_race.out)
assert_eq "exactly 10 of 30 succeed" 10 "$OKS"
assert_eq "exactly 20 rejected for insufficient funds" 20 "$NSF"
assert_eq "alice ends at exactly zero, never negative" 0 "$(bal $AA)"

echo "== concurrency: same idempotency key sent 20 times at once"
as_user $B "select post_topup(5000, 'topup-bob-0001')" >/dev/null
BEFORE=$(bal $BA)
seq 1 20 | xargs -P 20 -I{} psql -X -q -t -A -d "$DB" -c \
  "set request.jwt.claim.sub='$B'; select post_transfer('$BA','$CA',700,'double click','same-key-0001')" \
  > /tmp/cobalt_same.out 2>&1
assert_eq "only one transfer posted" $((BEFORE-700)) "$(bal $BA)"
assert_eq "exactly one transaction row for that key" 1 "$(q "select count(*) from transactions where reference='double click'")"

echo "== concurrency: opposite-direction transfers (deadlock check)"
as_user $A "select post_topup(100000, 'topup-alice-0002')" >/dev/null
as_user $B "select post_topup(100000, 'topup-bob-0002')" >/dev/null
( seq 1 40 | xargs -P 20 -I{} psql -X -q -t -A -d "$DB" -c \
    "set request.jwt.claim.sub='$A'; select post_transfer('$AA','$BA',100,'ab','ab-key-{}-aaaa')" ) > /tmp/cobalt_ab.out 2>&1 &
( seq 1 40 | xargs -P 20 -I{} psql -X -q -t -A -d "$DB" -c \
    "set request.jwt.claim.sub='$B'; select post_transfer('$BA','$AA',100,'ba','ba-key-{}-bbbb')" ) > /tmp/cobalt_ba.out 2>&1 &
wait
DEAD=$(cat /tmp/cobalt_ab.out /tmp/cobalt_ba.out | grep -ci deadlock)
assert_eq "no deadlocks" 0 "$DEAD"
assert_eq "all 80 opposite transfers posted" 80 "$(cat /tmp/cobalt_ab.out /tmp/cobalt_ba.out | grep -c '"status": "posted"')"

echo "== final reconciliation"
assert_eq "ledger sums to zero" 0 "$(q "select reconcile_ledger()->>'ledger_sum'")"
assert_eq "cached balances sum to zero" 0 "$(q "select reconcile_ledger()->>'balance_sum'")"
assert_eq "no balance discrepancies" '[]' "$(q "select reconcile_ledger()->'balance_discrepancies'")"
assert_eq "no unbalanced transactions" '[]' "$(q "select reconcile_ledger()->'unbalanced_transactions'")"
assert_eq "no negative customer balances" 0 "$(q "select count(*) from accounts where type <> 'system' and balance < 0")"

psql_admin -c "drop database if exists $DB" >/dev/null
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
