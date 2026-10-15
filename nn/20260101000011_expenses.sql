-- Append-only, venue-scoped expense register.
create table expenses (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  category text not null check (
    category in ('rent', 'utilities', 'supplies', 'maintenance', 'payroll', 'other')
  ),
  description text not null check (length(trim(description)) between 2 and 500),
  amount numeric(12,2) not null check (amount > 0),
  incurred_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create index expenses_venue_incurred_idx
  on expenses(venue_id, incurred_at desc);

alter table expenses enable row level security;
create policy expenses_admin_read on expenses
  for select using (app.is_admin(venue_id));
grant select on expenses to authenticated;

create trigger expenses_rt after insert on expenses
  for each row execute function app.broadcast_row('expenses');

create or replace function public.create_expense(
  p_op uuid,
  p_category text,
  p_description text,
  p_amount numeric,
  p_incurred_at timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_expense expenses;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid()
     and m.is_active
     and m.role in ('owner', 'manager')
   order by m.created_at
   limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;
  if p_category is null or p_category not in (
    'rent', 'utilities', 'supplies', 'maintenance', 'payroll', 'other'
  ) then
    raise exception 'INVALID_EXPENSE_CATEGORY';
  end if;
  if p_description is null
     or length(trim(p_description)) not between 2 and 500 then
    raise exception 'INVALID_EXPENSE_DESCRIPTION';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'INVALID_EXPENSE_AMOUNT';
  end if;
  if p_incurred_at is null or p_incurred_at > now() + interval '1 day' then
    raise exception 'INVALID_EXPENSE_DATE';
  end if;

  v_result := app.begin_op(
    p_op,
    v_venue,
    'create_expense',
    jsonb_build_object(
      'category', p_category,
      'description', trim(p_description),
      'amount', p_amount,
      'incurred_at', p_incurred_at
    )
  );
  if v_result is not null then return v_result; end if;

  insert into expenses(
    venue_id, category, description, amount, incurred_at, created_by
  )
  values (
    v_venue, p_category, trim(p_description), round(p_amount, 2),
    p_incurred_at, auth.uid()
  )
  returning * into v_expense;

  perform app.audit(
    v_venue,
    'expense_created',
    'expense',
    v_expense.id::text,
    jsonb_build_object(
      'category', v_expense.category,
      'amount', v_expense.amount,
      'description', v_expense.description
    )
  );

  return app.end_op(
    p_op,
    jsonb_build_object(
      'id', v_expense.id,
      'category', v_expense.category,
      'description', v_expense.description,
      'amount', v_expense.amount,
      'incurred_at', v_expense.incurred_at
    )
  );
end
$$;

revoke all on function public.create_expense(uuid,text,text,numeric,timestamptz)
  from public, anon;
grant execute on function public.create_expense(uuid,text,text,numeric,timestamptz)
  to authenticated;
