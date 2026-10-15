-- Atomic POS sales, products attached to sessions, split cash/card settlement and invoices.
create type order_status as enum ('paid','added_to_session','cancelled');
create type payment_method as enum ('cash','card');

create table orders (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid references customers(id),
  session_id uuid references sessions(id),
  status order_status not null,
  total numeric(12,2) not null check (total >= 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid not null references products(id),
  quantity int not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) generated always as (quantity * unit_price) stored,
  created_at timestamptz not null default now()
);

create table payments (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  session_id uuid references sessions(id),
  order_id uuid references orders(id),
  method payment_method not null,
  amount numeric(12,2) not null check (amount > 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check ((session_id is null) <> (order_id is null))
);

create table invoices (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  number bigint generated always as identity,
  session_id uuid references sessions(id),
  order_id uuid references orders(id),
  customer_id uuid references customers(id),
  total numeric(12,2) not null check (total >= 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check ((session_id is null) <> (order_id is null)),
  unique (session_id),
  unique (order_id)
);

create index orders_venue_created_idx on orders(venue_id, created_at desc);
create index order_items_order_idx on order_items(order_id);
create index payments_session_idx on payments(session_id) where session_id is not null;
create index payments_order_idx on payments(order_id) where order_id is not null;
create index invoices_venue_created_idx on invoices(venue_id, created_at desc);

alter table orders enable row level security;
alter table order_items enable row level security;
alter table payments enable row level security;
alter table invoices enable row level security;

create policy orders_staff_read on orders
  for select using (app.is_staff(venue_id));
create policy order_items_staff_read on order_items
  for select using (app.is_staff(venue_id));
create policy payments_staff_read on payments
  for select using (app.is_staff(venue_id));
create policy invoices_staff_read on invoices
  for select using (app.is_staff(venue_id));

grant select on orders, order_items, payments, invoices to authenticated;

create trigger orders_rt after insert or update on orders
  for each row execute function app.broadcast_row('orders');
create trigger payments_rt after insert on payments
  for each row execute function app.broadcast_row('payments');

create or replace view session_bill with (security_invoker = true) as
  select s.id as session_id,
         s.venue_id,
         coalesce((
           select sum(e.amount)
           from session_events e
           where e.session_id = s.id
             and e.type in ('match_added','time_added','discount')
         ), 0) as gaming_total,
         coalesce((
           select sum(e.amount)
           from session_events e
           where e.session_id = s.id and e.type = 'product_added'
         ), 0) as products_total,
         coalesce((
           select sum(p.amount)
           from payments p
           where p.session_id = s.id
         ), 0) as paid_total,
         coalesce((
           select sum(e.amount)
           from session_events e
           where e.session_id = s.id
             and e.type in ('match_added','time_added','discount','product_added')
         ), 0) - coalesce((
           select sum(p.amount)
           from payments p
           where p.session_id = s.id
         ), 0) as balance_due
  from sessions s;

create or replace function public.sell_product(
  p_op uuid,
  p_product uuid,
  p_quantity int,
  p_method payment_method default 'cash'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p products;
  o orders;
  i order_items;
  inv invoices;
  r jsonb;
  total_amount numeric(12,2);
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'INVALID_QUANTITY';
  end if;
  if p_method is null then raise exception 'INVALID_PAYMENT_METHOD'; end if;

  select * into p from products where id = p_product for update;
  if p.id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if not app.is_staff(p.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(
    p_op,
    p.venue_id,
    'sell_product',
    jsonb_build_object(
      'product_id', p_product,
      'quantity', p_quantity,
      'method', p_method
    )
  );
  if r is not null then return r; end if;
  if not p.is_available then raise exception 'PRODUCT_NOT_AVAILABLE'; end if;
  if p.stock_quantity < p_quantity then raise exception 'INSUFFICIENT_STOCK'; end if;

  total_amount := round(p.sale_price * p_quantity, 2);
  insert into orders(venue_id, status, total, created_by)
  values (p.venue_id, 'paid', total_amount, auth.uid())
  returning * into o;
  insert into order_items(venue_id, order_id, product_id, quantity, unit_price)
  values (p.venue_id, o.id, p.id, p_quantity, p.sale_price)
  returning * into i;

  perform set_config('app.inventory_rpc', 'on', true);
  update products
    set stock_quantity = stock_quantity - p_quantity
    where id = p.id
    returning * into p;
  perform set_config('app.inventory_rpc', 'off', true);

  insert into inventory_movements(
    venue_id, product_id, quantity_delta, reason, created_by
  )
  values (p.venue_id, p.id, -p_quantity, 'sale', auth.uid());
  insert into payments(venue_id, order_id, method, amount, created_by)
  values (p.venue_id, o.id, p_method, total_amount, auth.uid());
  insert into invoices(venue_id, order_id, total, created_by)
  values (p.venue_id, o.id, total_amount, auth.uid())
  returning * into inv;

  perform app.audit(
    p.venue_id,
    'product_sale',
    'order',
    o.id::text,
    jsonb_build_object(
      'product_id', p.id,
      'quantity', p_quantity,
      'total', total_amount,
      'invoice_id', inv.id
    )
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'order_id', o.id,
      'invoice_id', inv.id,
      'invoice_number', inv.number,
      'total', total_amount,
      'stock_quantity', p.stock_quantity
    )
  );
end
$$;

create or replace function public.add_product_to_session(
  p_op uuid,
  p_session uuid,
  p_product uuid,
  p_quantity int default 1
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  p products;
  o orders;
  i order_items;
  r jsonb;
  total_amount numeric(12,2);
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'INVALID_QUANTITY';
  end if;

  select * into p from products
    where id = p_product and venue_id = s.venue_id
    for update;
  if p.id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  r := app.begin_op(
    p_op,
    s.venue_id,
    'add_product_to_session',
    jsonb_build_object(
      'session_id', p_session,
      'product_id', p_product,
      'quantity', p_quantity
    )
  );
  if r is not null then return r; end if;
  if not p.is_available then raise exception 'PRODUCT_NOT_AVAILABLE'; end if;
  if p.stock_quantity < p_quantity then raise exception 'INSUFFICIENT_STOCK'; end if;

  total_amount := round(p.sale_price * p_quantity, 2);
  insert into orders(venue_id, session_id, customer_id, status, total, created_by)
  values (s.venue_id, s.id, s.customer_id, 'added_to_session', total_amount, auth.uid())
  returning * into o;
  insert into order_items(venue_id, order_id, product_id, quantity, unit_price)
  values (s.venue_id, o.id, p.id, p_quantity, p.sale_price)
  returning * into i;

  perform set_config('app.inventory_rpc', 'on', true);
  update products
    set stock_quantity = stock_quantity - p_quantity
    where id = p.id
    returning * into p;
  perform set_config('app.inventory_rpc', 'off', true);

  insert into inventory_movements(
    venue_id, product_id, quantity_delta, reason, created_by
  )
  values (s.venue_id, p.id, -p_quantity, 'sale', auth.uid());
  insert into session_events(
    venue_id, session_id, type, qty, unit_price, amount, game_id, meta, created_by
  )
  values (
    s.venue_id, s.id, 'product_added', p_quantity, p.sale_price,
    total_amount, s.game_id,
    jsonb_build_object('product_id', p.id, 'order_id', o.id),
    auth.uid()
  );
  perform app.audit(
    s.venue_id,
    'product_added',
    'session',
    s.id::text,
    jsonb_build_object('product_id', p.id, 'quantity', p_quantity, 'total', total_amount)
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'order_id', o.id,
      'session_id', s.id,
      'total', total_amount,
      'stock_quantity', p.stock_quantity
    )
  );
end
$$;

create or replace function public.pay_session(
  p_op uuid,
  p_session uuid,
  p_lines jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  line jsonb;
  method payment_method;
  amount numeric(12,2);
  sum_lines numeric(12,2) := 0;
  bill session_bill;
  inv invoices;
  r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  if s.status <> 'waiting_payment' then raise exception 'SESSION_NOT_WAITING_PAYMENT'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'INVALID_PAYMENT_LINES';
  end if;
  r := app.begin_op(
    p_op,
    s.venue_id,
    'pay_session',
    jsonb_build_object('session_id', p_session, 'lines', p_lines)
  );
  if r is not null then return r; end if;

  select * into bill from session_bill where session_id = s.id;
  if bill.balance_due < 0 then raise exception 'NEGATIVE_SESSION_BALANCE'; end if;
  if bill.balance_due > 0 and jsonb_array_length(p_lines) = 0 then
    raise exception 'INVALID_PAYMENT_LINES';
  end if;
  for line in select * from jsonb_array_elements(p_lines) loop
    begin
      method := (line ->> 'method')::payment_method;
      amount := (line ->> 'amount')::numeric;
    exception when others then
      raise exception 'INVALID_PAYMENT_LINE';
    end;
    if amount is null or amount <= 0 then raise exception 'INVALID_PAYMENT_AMOUNT'; end if;
    insert into payments(venue_id, session_id, method, amount, created_by)
    values (s.venue_id, s.id, method, amount, auth.uid());
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

revoke all on function public.sell_product(uuid,uuid,int,payment_method)
  from public, anon;
revoke all on function public.add_product_to_session(uuid,uuid,uuid,int)
  from public, anon;
revoke all on function public.pay_session(uuid,uuid,jsonb)
  from public, anon;
grant execute on function public.sell_product(uuid,uuid,int,payment_method)
  to authenticated;
grant execute on function public.add_product_to_session(uuid,uuid,uuid,int)
  to authenticated;
grant execute on function public.pay_session(uuid,uuid,jsonb)
  to authenticated;
