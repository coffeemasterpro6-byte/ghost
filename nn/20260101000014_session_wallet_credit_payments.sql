-- Commit migration 13 first: PostgreSQL enum values cannot be used in the
-- transaction that adds them.
create or replace function public.pay_session(
  p_op uuid,
  p_session uuid,
  p_lines jsonb,
  p_customer_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  c customers;
  line jsonb;
  method payment_method;
  amount numeric;
  sum_lines numeric(12,2) := 0;
  wallet_balance numeric(12,2);
  credit_balance numeric(12,2);
  bill session_bill;
  inv invoices;
  payment payments;
  r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  if s.status <> 'waiting_payment' then raise exception 'SESSION_NOT_WAITING_PAYMENT'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'INVALID_PAYMENT_LINES';
  end if;

  if p_customer_id is not null then
    update sessions set customer_id = p_customer_id where id = s.id;
    select * into s from sessions where id = p_session;
  end if;

  r := app.begin_op(
    p_op,
    s.venue_id,
    'pay_session',
    jsonb_build_object('session_id', p_session, 'lines', p_lines, 'customer_id', p_customer_id)
  );
  if r is not null then return r; end if;

  select * into bill from session_bill where session_id = s.id;
  if bill.balance_due < 0 then raise exception 'NEGATIVE_SESSION_BALANCE'; end if;
  if bill.balance_due > 0 and jsonb_array_length(p_lines) = 0 then
    raise exception 'INVALID_PAYMENT_LINES';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_lines) as items(value)
     where value ->> 'method' in ('wallet', 'credit')
  ) then
    if s.customer_id is null then raise exception 'CUSTOMER_REQUIRED'; end if;
    select * into c from customers
     where id = s.customer_id and venue_id = s.venue_id
     for update;
    if c.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  end if;

  for line in select * from jsonb_array_elements(p_lines) loop
    begin
      method := (line ->> 'method')::payment_method;
      amount := (line ->> 'amount')::numeric;
    exception when others then
      raise exception 'INVALID_PAYMENT_LINE';
    end;
    if method is null then raise exception 'INVALID_PAYMENT_METHOD'; end if;
    if amount is null or amount <= 0 or amount > 1000000000
       or amount <> round(amount, 2) then
      raise exception 'INVALID_PAYMENT_AMOUNT';
    end if;

    if method = 'wallet' then
      select coalesce(sum(delta), 0) into wallet_balance
        from customer_ledger_entries
       where customer_id = c.id and account = 'wallet';
      if amount > wallet_balance then raise exception 'INSUFFICIENT_WALLET'; end if;
    elsif method = 'credit' then
      if not app.has_perm(s.venue_id, 'manage_credit') and not app.is_staff(s.venue_id) then
        raise exception 'FORBIDDEN';
      end if;
    end if;

    insert into payments(venue_id, session_id, method, amount, created_by)
    values (s.venue_id, s.id, method, amount, auth.uid())
    returning * into payment;
    if method = 'wallet' then
      insert into customer_ledger_entries(
        venue_id, customer_id, account, delta, reason,
        session_id, payment_id, created_by
      )
      values (
        s.venue_id, c.id, 'wallet', -amount, 'session_spend',
        s.id, payment.id, auth.uid()
      );
    elsif method = 'credit' then
      insert into customer_ledger_entries(
        venue_id, customer_id, account, delta, reason,
        session_id, payment_id, created_by
      )
      values (
        s.venue_id, c.id, 'credit', amount, 'debt_created',
        s.id, payment.id, auth.uid()
      );
    end if;
    sum_lines := sum_lines + amount;
  end loop;
  if sum_lines <> bill.balance_due then
    raise exception 'PAYMENT_TOTAL_MISMATCH';
  end if;

  insert into invoices(
    venue_id, session_id, customer_id, total, created_by
  )
  values (
    s.venue_id, s.id, s.customer_id,
    bill.gaming_total + bill.products_total,
    auth.uid()
  )
  returning * into inv;
  update sessions
    set status = 'closed', version = version + 1, updated_at = now()
    where id = s.id;
  insert into session_events(venue_id, session_id, type, created_by)
  values (s.venue_id, s.id, 'payment', auth.uid());
  perform app._sync_post(s.post_id);
  perform app.audit(
    s.venue_id,
    'payment_created',
    'session',
    s.id::text,
    jsonb_build_object(
      'invoice_id', inv.id,
      'invoice_number', inv.number,
      'amount', sum_lines
    )
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'session_id', s.id,
      'invoice_id', inv.id,
      'invoice_number', inv.number,
      'total', bill.gaming_total + bill.products_total,
      'status', 'closed'
    )
  );
end
$$;

revoke all on function public.pay_session(uuid,uuid,jsonb,uuid) from public, anon;
grant execute on function public.pay_session(uuid,uuid,jsonb,uuid) to authenticated;
