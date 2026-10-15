-- Employee cash shifts with a traceable ledger and cash drawer reconciliation.
create table shifts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  employee_id uuid not null references auth.users(id),
  status text not null default 'open' check (status in ('open', 'closed')),
  opening_cash numeric(12,2) not null check (opening_cash >= 0),
  expected_cash numeric(12,2),
  closing_cash numeric(12,2),
  difference numeric(12,2),
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  check (
    (status = 'open' and closed_at is null and closing_cash is null)
    or
    (status = 'closed' and closed_at is not null and closing_cash is not null)
  )
);

create unique index one_open_shift_per_employee
  on shifts(venue_id, employee_id) where status = 'open';
create index shifts_venue_opened_idx on shifts(venue_id, opened_at desc);

create table shift_transactions (
  id bigint generated always as identity primary key,
  venue_id uuid not null references venues(id) on delete cascade,
  shift_id uuid not null references shifts(id),
  amount numeric(12,2) not null check (amount <> 0),
  kind text not null check (kind in ('cash_payment', 'expense')),
  source_id uuid not null,
  description text not null,
  created_at timestamptz not null default now(),
  unique (kind, source_id)
);

create index shift_transactions_shift_idx
  on shift_transactions(shift_id, created_at);

alter table shifts enable row level security;
alter table shift_transactions enable row level security;
create policy shifts_staff_read on shifts
  for select using (
    app.is_admin(venue_id)
    or employee_id = auth.uid() and app.is_staff(venue_id)
  );
create policy shift_transactions_staff_read on shift_transactions
  for select using (
    exists (
      select 1
        from shifts s
       where s.id = shift_transactions.shift_id
         and (
           app.is_admin(s.venue_id)
           or s.employee_id = auth.uid() and app.is_staff(s.venue_id)
         )
    )
  );
grant select on shifts, shift_transactions to authenticated;

create trigger shifts_rt after insert or update on shifts
  for each row execute function app.broadcast_row('shifts');
create trigger shift_transactions_rt after insert on shift_transactions
  for each row execute function app.broadcast_row('shifts');

create or replace function app.record_shift_cash_payment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift shifts;
  v_description text;
begin
  if new.method <> 'cash' then return new; end if;
  if new.created_by is null then return new; end if;

  select * into v_shift
    from shifts
   where venue_id = new.venue_id
     and employee_id = new.created_by
     and status = 'open'
   for update;
  if v_shift.id is null then return new; end if;

  v_description := case
    when new.session_id is not null then 'Paiement en espèces · session'
    else 'Paiement en espèces · commande'
  end;
  insert into shift_transactions(
    venue_id, shift_id, amount, kind, source_id, description
  )
  values (
    new.venue_id, v_shift.id, new.amount, 'cash_payment', new.id, v_description
  )
  on conflict (kind, source_id) do nothing;
  return new;
end
$$;

create trigger payments_cash_shift
after insert on payments
for each row execute function app.record_shift_cash_payment();

create or replace function app.record_shift_expense()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift shifts;
begin
  select * into v_shift
    from shifts
   where venue_id = new.venue_id
     and employee_id = new.created_by
     and status = 'open'
   for update;
  if v_shift.id is null then return new; end if;

  insert into shift_transactions(
    venue_id, shift_id, amount, kind, source_id, description
  )
  values (
    new.venue_id, v_shift.id, -new.amount, 'expense', new.id,
    'Dépense · ' || new.description
  )
  on conflict (kind, source_id) do nothing;
  return new;
end
$$;

create trigger expenses_cash_shift
after insert on expenses
for each row execute function app.record_shift_expense();
revoke all on function app.record_shift_cash_payment()
  from public, anon, authenticated;
revoke all on function app.record_shift_expense()
  from public, anon, authenticated;

create or replace function public.open_cash_shift(
  p_op uuid,
  p_opening_cash numeric default 0
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_shift shifts;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid() and m.is_active
     and m.role in ('owner', 'manager', 'employee')
   order by m.created_at
   limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;
  if p_opening_cash is null or p_opening_cash < 0
     or p_opening_cash > 1000000000 then
    raise exception 'INVALID_OPENING_CASH';
  end if;

  v_result := app.begin_op(
    p_op, v_venue, 'open_cash_shift',
    jsonb_build_object('opening_cash', p_opening_cash)
  );
  if v_result is not null then return v_result; end if;

  insert into shifts(venue_id, employee_id, opening_cash)
  values (v_venue, auth.uid(), round(p_opening_cash, 2))
  returning * into v_shift;
  perform app.audit(
    v_venue, 'cash_shift_opened', 'shift', v_shift.id::text,
    jsonb_build_object('opening_cash', v_shift.opening_cash)
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'id', v_shift.id,
      'status', v_shift.status,
      'opening_cash', v_shift.opening_cash,
      'opened_at', v_shift.opened_at
    )
  );
exception
  when unique_violation then raise exception 'SHIFT_ALREADY_OPEN';
end
$$;

create or replace function public.close_cash_shift(
  p_op uuid,
  p_shift uuid,
  p_closing_cash numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_shift shifts;
  v_expected numeric(12,2);
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_closing_cash is null or p_closing_cash < 0
     or p_closing_cash > 1000000000 then
    raise exception 'INVALID_CLOSING_CASH';
  end if;
  select * into v_shift
    from shifts
   where id = p_shift
   for update;
  if v_shift.id is null then raise exception 'SHIFT_NOT_FOUND'; end if;
  if v_shift.employee_id <> auth.uid()
     and not app.is_admin(v_shift.venue_id) then
    raise exception 'FORBIDDEN';
  end if;
  if v_shift.status <> 'open' then raise exception 'SHIFT_NOT_OPEN'; end if;

  v_result := app.begin_op(
    p_op,
    v_shift.venue_id,
    'close_cash_shift',
    jsonb_build_object('shift_id', p_shift, 'closing_cash', p_closing_cash)
  );
  if v_result is not null then return v_result; end if;

  select round(v_shift.opening_cash + coalesce(sum(t.amount), 0), 2)
    into v_expected
    from shift_transactions t
   where t.shift_id = v_shift.id;
  update shifts
     set status = 'closed',
         expected_cash = v_expected,
         closing_cash = round(p_closing_cash, 2),
         difference = round(p_closing_cash - v_expected, 2),
         closed_at = now()
   where id = v_shift.id
   returning * into v_shift;

  perform app.audit(
    v_shift.venue_id, 'cash_shift_closed', 'shift', v_shift.id::text,
    jsonb_build_object(
      'expected_cash', v_shift.expected_cash,
      'closing_cash', v_shift.closing_cash,
      'difference', v_shift.difference
    )
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'id', v_shift.id,
      'expected_cash', v_shift.expected_cash,
      'closing_cash', v_shift.closing_cash,
      'difference', v_shift.difference,
      'closed_at', v_shift.closed_at
    )
  );
end
$$;

revoke all on function public.open_cash_shift(uuid,numeric) from public, anon;
revoke all on function public.close_cash_shift(uuid,uuid,numeric) from public, anon;
grant execute on function public.open_cash_shift(uuid,numeric) to authenticated;
grant execute on function public.close_cash_shift(uuid,uuid,numeric) to authenticated;
