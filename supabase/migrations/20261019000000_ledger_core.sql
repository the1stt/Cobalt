-- =====================================================================
-- Cobalt: ledger core
-- Money model:
--   * All amounts are integer minor units (cents) in bigint. No floats.
--   * Every money movement is a transaction made of ledger entries.
--   * balance = sum(credits) - sum(debits) for every account.
--     A debit entry lowers an account, a credit entry raises it.
--     Customer accounts can never go below zero (CHECK constraint).
--     System accounts (external funding, merchant settlement) may go negative.
--   * ledger_entries is append-only. Corrections are compensating transactions.
--   * Every transaction must sum to zero. Enforced by a deferred constraint
--     trigger, so it is checked at COMMIT, not in application code.
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists citext;

create type account_type    as enum ('main', 'pot', 'system');
create type account_status  as enum ('active', 'frozen', 'closed');
create type txn_type        as enum ('transfer', 'topup', 'purchase', 'pot_move', 'round_up', 'reversal', 'fee');
create type txn_status      as enum ('pending', 'posted', 'failed', 'reversed');
create type entry_direction as enum ('debit', 'credit');

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

create table profiles (
  id            uuid primary key references auth.users (id) on delete restrict,
  handle        citext not null unique check (handle ~ '^[a-z0-9_]{3,20}$'),
  full_name     text not null,
  date_of_birth date,
  address       jsonb,
  role          text not null default 'customer' check (role in ('customer', 'admin')),
  status        text not null default 'active'   check (status in ('active', 'frozen')),
  created_at    timestamptz not null default now()
);

create table accounts (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid references profiles (id),
  type           account_type not null,
  currency       char(3) not null default 'USD',
  name           text not null,
  status         account_status not null default 'active',
  balance        bigint not null default 0,
  account_number text unique default lpad((floor(random() * 1e12))::bigint::text, 12, '0'),
  system_key     text unique,
  per_txn_limit  bigint not null default 500000,   -- $5,000.00
  daily_limit    bigint not null default 1000000,  -- $10,000.00 rolling 24h
  created_at     timestamptz not null default now(),
  constraint system_accounts_have_no_owner check ((type = 'system') = (owner_id is null)),
  constraint system_accounts_have_key      check ((type = 'system') = (system_key is not null)),
  constraint no_overdraft                  check (type = 'system' or balance >= 0)
);
create index accounts_owner_idx on accounts (owner_id);

create table transactions (
  id          uuid primary key default gen_random_uuid(),
  type        txn_type not null,
  status      txn_status not null default 'posted',
  reference   text,
  parent_id   uuid references transactions (id),
  created_by  uuid references profiles (id),
  metadata    jsonb not null default '{}',
  created_at  timestamptz not null default now(),
  posted_at   timestamptz
);

create table ledger_entries (
  id             bigint generated always as identity primary key,
  transaction_id uuid not null references transactions (id),
  account_id     uuid not null references accounts (id),
  direction      entry_direction not null,
  amount         bigint not null check (amount > 0),
  currency       char(3) not null,
  created_at     timestamptz not null default now()
);
create index ledger_entries_account_idx on ledger_entries (account_id, id desc);
create index ledger_entries_txn_idx     on ledger_entries (transaction_id);

create table idempotency_keys (
  user_id      uuid not null references profiles (id),
  key          text not null check (length(key) between 8 and 128),
  request_hash text not null,
  response     jsonb,
  created_at   timestamptz not null default now(),
  primary key (user_id, key)
);

-- ---------------------------------------------------------------------
-- Invariants enforced by the database
-- ---------------------------------------------------------------------

-- 1. ledger_entries is append-only.
create function forbid_ledger_mutation() returns trigger
language plpgsql as $$
begin
  raise exception 'ledger_entries is append-only (% blocked)', tg_op;
end $$;

create trigger ledger_entries_no_update_delete
  before update or delete on ledger_entries
  for each row execute function forbid_ledger_mutation();

create trigger ledger_entries_no_truncate
  before truncate on ledger_entries
  for each statement execute function forbid_ledger_mutation();

-- 2. Transactions cannot be deleted, and only their status may change.
create function transactions_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'transactions cannot be deleted';
  end if;
  if (new.id, new.type, new.reference, new.parent_id, new.created_by, new.created_at)
     is distinct from
     (old.id, old.type, old.reference, old.parent_id, old.created_by, old.created_at) then
    raise exception 'transactions are immutable except status, posted_at and metadata';
  end if;
  return new;
end $$;

create trigger transactions_guard_trg
  before update or delete on transactions
  for each row execute function transactions_guard();

-- 3. Every entry moves the cached balance in the same statement, so the
--    cache can never drift from the entries. The CHECK on accounts.balance
--    is the final backstop against overdraft.
create function apply_entry_to_balance() returns trigger
language plpgsql as $$
begin
  update accounts
     set balance = balance + case new.direction when 'credit' then new.amount else -new.amount end
   where id = new.account_id
     and currency = new.currency;
  if not found then
    raise exception 'currency_mismatch_or_missing_account';
  end if;
  return new;
end $$;

create trigger ledger_entries_apply_balance
  after insert on ledger_entries
  for each row execute function apply_entry_to_balance();

-- 4. Each transaction must balance to exactly zero, use one currency and have
--    at least two entries. Deferred: checked at COMMIT.
create function assert_transaction_balanced() returns trigger
language plpgsql as $$
declare
  v_net bigint;
  v_cnt int;
  v_ccy int;
begin
  select coalesce(sum(case direction when 'credit' then amount else -amount end), 0),
         count(*),
         count(distinct currency)
    into v_net, v_cnt, v_ccy
    from ledger_entries
   where transaction_id = new.transaction_id;

  if v_net <> 0 then
    raise exception 'unbalanced_transaction % (net %)', new.transaction_id, v_net;
  end if;
  if v_cnt < 2 then
    raise exception 'transaction % has fewer than two entries', new.transaction_id;
  end if;
  if v_ccy <> 1 then
    raise exception 'transaction % mixes currencies', new.transaction_id;
  end if;
  return null;
end $$;

create constraint trigger ledger_entries_balanced
  after insert on ledger_entries
  deferrable initially deferred
  for each row execute function assert_transaction_balanced();

-- ---------------------------------------------------------------------
-- System accounts and account creation
-- ---------------------------------------------------------------------

insert into accounts (type, name, system_key) values
  ('system', 'External Funding (sandbox)', 'external_funding'),
  ('system', 'Merchant Settlement',        'merchant_settlement'),
  ('system', 'Fees',                       'fees'),
  ('system', 'Suspense',                   'suspense');

create function create_main_account() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into accounts (owner_id, type, name) values (new.id, 'main', 'Main account');
  return new;
end $$;

create trigger profiles_create_main_account
  after insert on profiles
  for each row execute function create_main_account();

-- ---------------------------------------------------------------------
-- Internal helpers (not callable by clients)
-- ---------------------------------------------------------------------

-- Posts a two-leg transaction: debit one account, credit another.
-- Locks both accounts in id order, so opposite transfers cannot deadlock.
create function ledger_post(
  p_type      txn_type,
  p_actor     uuid,
  p_reference text,
  p_parent    uuid,
  p_meta      jsonb,
  p_debit     uuid,
  p_credit    uuid,
  p_amount    bigint
) returns uuid
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  a_deb  accounts;
  a_cred accounts;
  v_txn  uuid;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_amount';
  end if;
  if p_debit = p_credit then
    raise exception 'same_account';
  end if;

  perform 1 from accounts where id in (p_debit, p_credit) order by id for update;

  select * into a_deb  from accounts where id = p_debit;
  select * into a_cred from accounts where id = p_credit;

  if a_deb.id is null or a_cred.id is null then
    raise exception 'account_not_found';
  end if;
  if a_deb.currency <> a_cred.currency then
    raise exception 'currency_mismatch';
  end if;
  if a_deb.type <> 'system' and a_deb.status <> 'active' then
    raise exception 'account_frozen';
  end if;
  if a_cred.type <> 'system' and a_cred.status = 'closed' then
    raise exception 'recipient_closed';
  end if;
  if a_deb.type <> 'system' and a_deb.balance < p_amount then
    raise exception 'insufficient_funds';
  end if;

  insert into transactions (type, status, reference, parent_id, created_by, metadata, posted_at)
  values (p_type, 'posted', p_reference, p_parent, p_actor, coalesce(p_meta, '{}'), now())
  returning id into v_txn;

  insert into ledger_entries (transaction_id, account_id, direction, amount, currency)
  values (v_txn, p_debit,  'debit',  p_amount, a_deb.currency),
         (v_txn, p_credit, 'credit', p_amount, a_deb.currency);

  return v_txn;
end $$;

-- Idempotency: returns the stored response on a replay, null on first use.
-- A concurrent duplicate blocks on the unique index until the first request
-- commits, then returns the same response. If the first request fails, its
-- key row rolls back with it and the client can safely retry.
create function idem_begin(p_actor uuid, p_key text, p_hash text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_n   int;
  v_row idempotency_keys;
begin
  insert into idempotency_keys (user_id, key, request_hash)
  values (p_actor, p_key, p_hash)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  if v_n = 1 then
    return null;
  end if;

  select * into v_row from idempotency_keys where user_id = p_actor and key = p_key;
  if v_row.request_hash <> p_hash then
    raise exception 'idempotency_key_reused';
  end if;
  return v_row.response || jsonb_build_object('replayed', true);
end $$;

create function idem_finish(p_actor uuid, p_key text, p_response jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  update idempotency_keys set response = p_response where user_id = p_actor and key = p_key;
$$;

-- ---------------------------------------------------------------------
-- Client-facing money functions (called via RPC, identity = auth.uid())
-- ---------------------------------------------------------------------

create function post_transfer(
  p_from            uuid,
  p_to              uuid,
  p_amount          bigint,
  p_reference       text,
  p_idempotency_key text
) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor  uuid := auth.uid();
  v_hash   text;
  v_replay jsonb;
  v_from   accounts;
  v_today  bigint;
  v_txn    uuid;
  v_resp   jsonb;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency_key_required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_amount';
  end if;

  v_hash := encode(digest(concat_ws('|', p_from, p_to, p_amount, coalesce(p_reference, '')), 'sha256'), 'hex');
  v_replay := idem_begin(v_actor, p_idempotency_key, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  select * into v_from from accounts where id = p_from;
  if v_from.id is null or v_from.owner_id is distinct from v_actor or v_from.type <> 'main' then
    raise exception 'forbidden_account';
  end if;
  perform 1 from accounts where id = p_to and type = 'main';
  if not found then
    raise exception 'recipient_not_found';
  end if;

  -- Lock both accounts in id order BEFORE reading limits, so concurrent
  -- transfers from the same account cannot both pass the daily limit.
  perform 1 from accounts where id in (p_from, p_to) order by id for update;

  if p_amount > v_from.per_txn_limit then
    raise exception 'per_txn_limit_exceeded';
  end if;

  select coalesce(sum(le.amount), 0) into v_today
    from ledger_entries le
    join transactions t on t.id = le.transaction_id
   where le.account_id = p_from
     and le.direction = 'debit'
     and t.type = 'transfer'
     and le.created_at >= now() - interval '24 hours';
  if v_today + p_amount > v_from.daily_limit then
    raise exception 'daily_limit_exceeded';
  end if;

  v_txn := ledger_post('transfer', v_actor, p_reference, null, '{}'::jsonb, p_from, p_to, p_amount);

  v_resp := jsonb_build_object(
    'transaction_id', v_txn, 'status', 'posted',
    'amount', p_amount, 'from', p_from, 'to', p_to);
  perform idem_finish(v_actor, p_idempotency_key, v_resp);
  return v_resp;
end $$;

-- Sandbox top-up: money enters from the External Funding system account.
create function post_topup(p_amount bigint, p_idempotency_key text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor  uuid := auth.uid();
  v_hash   text;
  v_replay jsonb;
  v_main   uuid;
  v_fund   uuid;
  v_txn    uuid;
  v_resp   jsonb;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency_key_required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_amount';
  end if;
  if p_amount > 500000 then
    raise exception 'topup_limit_exceeded';
  end if;

  v_hash := encode(digest(concat_ws('|', 'topup', p_amount), 'sha256'), 'hex');
  v_replay := idem_begin(v_actor, p_idempotency_key, v_hash);
  if v_replay is not null then
    return v_replay;
  end if;

  select id into v_main from accounts where owner_id = v_actor and type = 'main';
  select id into v_fund from accounts where system_key = 'external_funding';
  if v_main is null then
    raise exception 'account_not_found';
  end if;

  v_txn := ledger_post('topup', v_actor, 'Sandbox top-up', null, '{}'::jsonb, v_fund, v_main, p_amount);

  v_resp := jsonb_build_object('transaction_id', v_txn, 'status', 'posted', 'amount', p_amount, 'to', v_main);
  perform idem_finish(v_actor, p_idempotency_key, v_resp);
  return v_resp;
end $$;

-- Recipient lookup by handle. Returns only what the sender needs to confirm.
create function find_recipient(p_handle citext)
returns table (account_id uuid, display_name text)
language sql security definer stable set search_path = public, pg_temp as $$
  select a.id, p.full_name
    from profiles p
    join accounts a on a.owner_id = p.id and a.type = 'main'
   where p.handle = p_handle and p.status = 'active';
$$;

-- Reconciliation: cached balances vs entries, and whole-ledger sum.
create function reconcile_ledger() returns jsonb
language sql security definer stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'ledger_sum', (select coalesce(sum(case direction when 'credit' then amount else -amount end), 0)
                     from ledger_entries),
    'balance_sum', (select coalesce(sum(balance), 0) from accounts),
    'balance_discrepancies', coalesce((
      select jsonb_agg(jsonb_build_object('account_id', d.id, 'cached', d.balance, 'computed', d.computed))
        from (
          select a.id, a.balance,
                 coalesce(sum(case le.direction when 'credit' then le.amount else -le.amount end), 0) as computed
            from accounts a
            left join ledger_entries le on le.account_id = a.id
           group by a.id, a.balance
          having a.balance <> coalesce(sum(case le.direction when 'credit' then le.amount else -le.amount end), 0)
        ) d), '[]'::jsonb),
    'unbalanced_transactions', coalesce((
      select jsonb_agg(x.transaction_id)
        from (
          select transaction_id
            from ledger_entries
           group by transaction_id
          having sum(case direction when 'credit' then amount else -amount end) <> 0
        ) x), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------
-- Row level security and privileges
-- Clients read their own data and write ONLY through the functions above.
-- ---------------------------------------------------------------------

alter table profiles         enable row level security;
alter table accounts         enable row level security;
alter table transactions     enable row level security;
alter table ledger_entries   enable row level security;
alter table idempotency_keys enable row level security;

create policy profiles_self on profiles for select using (id = auth.uid());
create policy accounts_own  on accounts for select using (owner_id = auth.uid());
create policy entries_own   on ledger_entries for select using (
  exists (select 1 from accounts a where a.id = ledger_entries.account_id and a.owner_id = auth.uid()));
create policy txns_own      on transactions for select using (
  exists (select 1 from ledger_entries le
            join accounts a on a.id = le.account_id
           where le.transaction_id = transactions.id and a.owner_id = auth.uid()));
-- idempotency_keys: no policy, so clients can read nothing.

revoke insert, update, delete, truncate on
  profiles, accounts, transactions, ledger_entries, idempotency_keys
  from anon, authenticated;

revoke all on function ledger_post(txn_type, uuid, text, uuid, jsonb, uuid, uuid, bigint) from public, anon, authenticated;
revoke all on function idem_begin(uuid, text, text)   from public, anon, authenticated;
revoke all on function idem_finish(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function reconcile_ledger()             from public, anon, authenticated;
revoke all on function post_transfer(uuid, uuid, bigint, text, text) from public, anon;
revoke all on function post_topup(bigint, text)                       from public, anon;
revoke all on function find_recipient(citext)                         from public, anon;

grant execute on function post_transfer(uuid, uuid, bigint, text, text) to authenticated;
grant execute on function post_topup(bigint, text)                       to authenticated;
grant execute on function find_recipient(citext)                         to authenticated;
grant execute on function reconcile_ledger()                             to service_role;
