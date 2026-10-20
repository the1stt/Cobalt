-- =====================================================================
-- Cobalt: onboarding and hardening
-- Follows 20261019000000_ledger_core.sql. Additive: the first migration is
-- not edited. Uses create or replace / if not exists, so it is safe to re-run.
--
--   1. One main account per user (unique partial index).
--   2. Account-number collisions are retried instead of failing sign-up.
--   3. post_transfer re-reads limits AFTER taking the row lock.
--   4. find_recipient search_path covers the extensions schema (citext).
--   5. complete_onboarding / is_handle_available: the only way a customer
--      profile (and therefore an account) comes into existence.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Exactly one main account per user.
--    post_topup and the app both assume this; now the database enforces it.
-- ---------------------------------------------------------------------
create unique index if not exists accounts_one_main_per_owner
  on accounts (owner_id) where type = 'main';

-- ---------------------------------------------------------------------
-- 2. Retry on a random account-number collision (unique constraint stays
--    the backstop). Any other unique violation is re-raised untouched.
-- ---------------------------------------------------------------------
create or replace function create_main_account() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_con text;
begin
  for i in 1..5 loop
    begin
      insert into accounts (owner_id, type, name) values (new.id, 'main', 'Main account');
      return new;
    exception when unique_violation then
      get stacked diagnostics v_con = constraint_name;
      if v_con is distinct from 'accounts_account_number_key' or i = 5 then
        raise;
      end if;
    end;
  end loop;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 3. post_transfer: identical to the original except the sender row is
--    re-read after the lock, so per_txn_limit and daily_limit are never a
--    stale pre-lock snapshot. Grants carry over from the original.
-- ---------------------------------------------------------------------
create or replace function post_transfer(
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

  -- Cheap ownership check before locking (ownership never changes).
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

  -- Re-read the sender now that the lock is held: limits are current.
  select * into v_from from accounts where id = p_from;

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

-- ---------------------------------------------------------------------
-- 4. find_recipient: resolve citext operators wherever the extension lives.
-- ---------------------------------------------------------------------
alter function find_recipient(citext) set search_path = public, extensions, pg_temp;

-- ---------------------------------------------------------------------
-- 5. Onboarding
-- ---------------------------------------------------------------------

-- Handles users may not claim (impersonation of the bank itself).
create or replace function is_reserved_handle(p_handle text) returns boolean
language sql immutable as $$
  select lower(p_handle) = any (array[
    'admin', 'administrator', 'support', 'help', 'cobalt', 'security',
    'root', 'system', 'bank', 'official', 'staff', 'team', 'billing'
  ]);
$$;

-- Live availability check for the onboarding form. Boolean only.
create or replace function is_handle_available(p_handle citext) returns boolean
language sql security definer stable set search_path = public, extensions, pg_temp as $$
  select p_handle is not null
     and p_handle::text ~ '^[A-Za-z0-9_]{3,20}$'
     and not is_reserved_handle(p_handle::text)
     and not exists (select 1 from profiles where handle = p_handle);
$$;

-- Creates the caller's profile; the profiles trigger then creates the main
-- account. Identity is auth.uid(), never a parameter. Everything is validated
-- here so the rules hold no matter which client calls it.
create or replace function complete_onboarding(
  p_handle        citext,
  p_full_name     text,
  p_date_of_birth date,
  p_address       jsonb
) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_actor  uuid := auth.uid();
  v_handle text := lower(btrim(coalesce(p_handle::text, '')));
  v_name   text := btrim(coalesce(p_full_name, ''));
  v_street text;
  v_city   text;
  v_state  text;
  v_zip    text;
  v_con    text;
  v_acct   accounts;
begin
  if v_actor is null then
    raise exception 'not_authenticated';
  end if;
  if exists (select 1 from profiles where id = v_actor) then
    raise exception 'already_onboarded';
  end if;

  if v_handle !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'invalid_handle';
  end if;
  if is_reserved_handle(v_handle) then
    raise exception 'handle_reserved';
  end if;

  if length(v_name) < 2 or length(v_name) > 100 then
    raise exception 'invalid_name';
  end if;

  if p_date_of_birth is null
     or p_date_of_birth < date '1900-01-01'
     or p_date_of_birth > current_date then
    raise exception 'invalid_date_of_birth';
  end if;
  if p_date_of_birth > (current_date - interval '18 years')::date then
    raise exception 'under_18';
  end if;

  if p_address is null or jsonb_typeof(p_address) <> 'object' then
    raise exception 'invalid_address';
  end if;
  v_street := btrim(coalesce(p_address->>'street', ''));
  v_city   := btrim(coalesce(p_address->>'city', ''));
  v_state  := upper(btrim(coalesce(p_address->>'state', '')));
  v_zip    := btrim(coalesce(p_address->>'zip', ''));
  if length(v_street) not between 3 and 100
     or length(v_city) not between 2 and 60
     or v_zip !~ '^\d{5}(-\d{4})?$'
     or not (v_state = any (array[
          'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA',
          'KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ',
          'NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT',
          'VA','WA','WV','WI','WY','DC'])) then
    raise exception 'invalid_address';
  end if;

  begin
    insert into profiles (id, handle, full_name, date_of_birth, address)
    values (v_actor, v_handle::citext, v_name, p_date_of_birth,
            jsonb_build_object('street', v_street, 'city', v_city,
                               'state', v_state, 'zip', v_zip));
  exception when unique_violation then
    get stacked diagnostics v_con = constraint_name;
    if v_con = 'profiles_pkey' then
      raise exception 'already_onboarded';
    elsif v_con = 'profiles_handle_key' then
      raise exception 'handle_taken';
    else
      raise;
    end if;
  end;

  select * into v_acct from accounts where owner_id = v_actor and type = 'main';

  return jsonb_build_object(
    'profile_id',     v_actor,
    'handle',         v_handle,
    'account_id',     v_acct.id,
    'account_number', v_acct.account_number);
end $$;

-- ---------------------------------------------------------------------
-- Privileges: signed-in users only. Anonymous callers get nothing.
-- ---------------------------------------------------------------------
revoke all on function is_reserved_handle(text)                      from public, anon, authenticated;
revoke all on function is_handle_available(citext)                   from public, anon;
revoke all on function complete_onboarding(citext, text, date, jsonb) from public, anon;

grant execute on function is_handle_available(citext)                    to authenticated;
grant execute on function complete_onboarding(citext, text, date, jsonb) to authenticated;
