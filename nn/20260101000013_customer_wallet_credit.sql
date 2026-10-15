-- Customer wallet and credit ledger. Balances are derived from immutable entries.
alter type payment_method add value 'wallet';
alter type payment_method add value 'credit';

alter table customers
  add column credit_limit numeric(12,2) not null default 0
    check (credit_limit >= 0);

create table customer_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid not null references customers(id),
  account text not null check (account in ('wallet', 'credit')),
  delta numeric(12,2) not null check (delta <> 0),
  reason text not null check (
    reason in ('wallet_top_up', 'session_spend', 'debt_created', 'credit_repayment')
  ),
  method text check (method in ('cash', 'card')),
  session_id uuid references sessions(id),
  payment_id uuid references payments(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (
    (account = 'wallet' and (
      (reason = 'wallet_top_up' and delta > 0 and method is not null)
      or (reason = 'session_spend' and delta < 0 and session_id is not null)
    ))
    or
    (account = 'credit' and (
      (reason = 'debt_created' and delta > 0 and session_id is not null)
      or (reason = 'credit_repayment' and delta < 0 and method is not null)
    ))
  )
);

create index customer_ledger_customer_idx
  on customer_ledger_entries(customer_id, created_at desc);
create index customer_ledger_venue_idx
  on customer_ledger_entries(venue_id, created_at desc);

create view customer_balances
with (security_invoker = true) as
  select c.id as customer_id,
         c.venue_id,
         c.credit_limit,
         coalesce(sum(l.delta) filter (where l.account = 'wallet'), 0)::numeric(12,2)
           as wallet_balance,
         coalesce(sum(l.delta) filter (where l.account = 'credit'), 0)::numeric(12,2)
           as credit_balance
    from customers c
    left join customer_ledger_entries l on l.customer_id = c.id
   group by c.id, c.venue_id, c.credit_limit;

alter table customer_ledger_entries enable row level security;
create policy customer_ledger_staff_read on customer_ledger_entries
  for select using (app.is_staff(venue_id));
create policy customer_ledger_self_read on customer_ledger_entries
  for select using (
    exists (
      select 1 from customers c
       where c.id = customer_ledger_entries.customer_id
         and c.user_id = auth.uid()
    )
  );
grant select on customer_ledger_entries, customer_balances to authenticated;

alter table shift_transactions
  drop constraint shift_transactions_kind_check;
alter table shift_transactions
  add constraint shift_transactions_kind_check
  check (kind in ('cash_payment', 'expense', 'wallet_top_up', 'credit_repayment'));

create or replace function app.record_shift_customer_cash()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift shifts;
  v_kind text;
begin
  if new.method <> 'cash'
     or new.reason not in ('wallet_top_up', 'credit_repayment') then
    return new;
  end if;

  select * into v_shift
    from shifts
   where venue_id = new.venue_id
     and employee_id = new.created_by
     and status = 'open'
   for update;
  if v_shift.id is null then return new; end if;

  v_kind := case new.reason
    when 'wallet_top_up' then 'wallet_top_up'
    else 'credit_repayment'
  end;
  insert into shift_transactions(
    venue_id, shift_id, amount, kind, source_id, description
  )
  values (
    new.venue_id, v_shift.id, abs(new.delta), v_kind, new.id,
    case new.reason
      when 'wallet_top_up' then 'Rechargement portefeuille'
      else 'Remboursement crédit'
    end
  )
  on conflict (kind, source_id) do nothing;
  return new;
end
$$;

create trigger customer_ledger_cash_shift
after insert on customer_ledger_entries
for each row execute function app.record_shift_customer_cash();
create trigger customer_ledger_rt
after insert on customer_ledger_entries
for each row execute function app.broadcast_row('customers');
create trigger customer_balance_rt
after update of credit_limit on customers
for each row execute function app.broadcast_row('customers');
revoke all on function app.record_shift_customer_cash()
  from public, anon, authenticated;

create or replace function public.create_customer_financial_operation(
  p_op uuid,
  p_customer uuid,
  p_action text,
  p_amount numeric,
  p_method text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c customers;
  v_wallet numeric(12,2);
  v_credit numeric(12,2);
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into c from customers where id = p_customer for update;
  if c.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if not app.is_staff(c.venue_id) then raise exception 'FORBIDDEN'; end if;
  if p_action is null
     or p_action not in ('wallet_top_up', 'credit_repayment', 'set_credit_limit') then
    raise exception 'INVALID_FINANCIAL_ACTION';
  end if;
  if p_amount is null or p_amount < 0 or p_amount > 1000000000
     or p_amount <> round(p_amount, 2)
     or (p_action <> 'set_credit_limit' and p_amount = 0) then
    raise exception 'INVALID_FINANCIAL_AMOUNT';
  end if;
  if p_action <> 'wallet_top_up' and not app.has_perm(c.venue_id, 'manage_credit') then
    raise exception 'FORBIDDEN';
  end if;
  if p_action = 'wallet_top_up'
     and (p_method is null or p_method not in ('cash', 'card')) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;
  if p_action = 'credit_repayment'
     and (p_method is null or p_method not in ('cash', 'card')) then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;
  if p_action = 'set_credit_limit' and p_method is not null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  v_result := app.begin_op(
    p_op, c.venue_id, 'create_customer_financial_operation',
    jsonb_build_object(
      'customer_id', p_customer,
      'action', p_action,
      'amount', p_amount,
      'method', p_method
    )
  );
  if v_result is not null then return v_result; end if;

  if p_action = 'set_credit_limit' then
    select coalesce(sum(delta), 0) into v_credit
      from customer_ledger_entries
     where customer_id = c.id and account = 'credit';
    if round(p_amount, 2) < v_credit then
      raise exception 'CREDIT_LIMIT_BELOW_BALANCE';
    end if;
    update customers set credit_limit = round(p_amount, 2) where id = c.id
      returning * into c;
  else
    if p_action = 'credit_repayment' then
      select coalesce(sum(delta), 0) into v_credit
        from customer_ledger_entries
       where customer_id = c.id and account = 'credit';
      if p_amount > v_credit then raise exception 'REPAYMENT_EXCEEDS_BALANCE'; end if;
      insert into customer_ledger_entries(
        venue_id, customer_id, account, delta, reason, method, created_by
      )
      values (
        c.venue_id, c.id, 'credit', -round(p_amount, 2),
        'credit_repayment', p_method, auth.uid()
      );
    else
      insert into customer_ledger_entries(
        venue_id, customer_id, account, delta, reason, method, created_by
      )
      values (
        c.venue_id, c.id, 'wallet', round(p_amount, 2),
        'wallet_top_up', p_method, auth.uid()
      );
    end if;
  end if;

  select coalesce(sum(delta) filter (where account = 'wallet'), 0),
         coalesce(sum(delta) filter (where account = 'credit'), 0)
    into v_wallet, v_credit
    from customer_ledger_entries
   where customer_id = c.id;
  perform app.audit(
    c.venue_id, p_action, 'customer', c.id::text,
    jsonb_build_object('amount', p_amount, 'method', p_method)
  );
  if p_action = 'wallet_top_up' then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    select c.venue_id, m.user_id, 'wallet_recharged',
           'Portefeuille rechargé',
           round(p_amount, 2)::text || ' DA',
           'customer', c.id,
           jsonb_build_object('amount', round(p_amount, 2))
      from venue_members m
     where m.venue_id = c.venue_id and m.role = 'customer'
       and m.is_active
       and exists (
         select 1 from customers linked
          where linked.venue_id = c.venue_id
            and linked.id = c.id
            and linked.user_id = m.user_id
       );
  end if;
  return app.end_op(
    p_op,
    jsonb_build_object(
      'customer_id', c.id,
      'wallet_balance', v_wallet,
      'credit_balance', v_credit,
      'credit_limit', c.credit_limit
    )
  );
end
$$;

revoke all on function public.create_customer_financial_operation(uuid,uuid,text,numeric,text)
  from public, anon;
grant execute on function public.create_customer_financial_operation(uuid,uuid,text,numeric,text)
  to authenticated;
