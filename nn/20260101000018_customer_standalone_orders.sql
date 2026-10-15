create type customer_order_request_status as enum ('pending', 'completed', 'rejected');

create table customer_order_requests (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid not null references customers(id),
  product_id uuid not null references products(id),
  quantity int not null check (quantity between 1 and 100),
  expected_unit_price numeric(12,2) not null check (expected_unit_price >= 0),
  status customer_order_request_status not null default 'pending',
  order_id uuid references orders(id),
  handled_by uuid references auth.users(id),
  handled_at timestamptz,
  created_at timestamptz not null default now()
);

create index customer_order_requests_venue_status_idx
  on customer_order_requests(venue_id, status, created_at);
create index customer_order_requests_customer_idx
  on customer_order_requests(customer_id, created_at desc);

alter table customer_order_requests enable row level security;

create policy customer_order_requests_staff_read on customer_order_requests
  for select using (app.is_staff(venue_id));
create policy customer_order_requests_own_read on customer_order_requests
  for select using (
    exists (
      select 1 from customers c
      where c.id = customer_id and c.user_id = auth.uid()
    )
  );

grant select on customer_order_requests to authenticated;

create trigger customer_order_requests_rt
  after insert or update on customer_order_requests
  for each row execute function app.broadcast_row('requests');

create or replace function public.request_standalone_product_order(
  p_op uuid,
  p_product uuid,
  p_quantity int,
  p_expected_price numeric(12,2)
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p products;
  c customers;
  req customer_order_requests;
  r jsonb;
  staff_user record;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'INVALID_QUANTITY';
  end if;

  select * into p from products where id = p_product for update;
  if p.id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  select * into c from customers
   where venue_id = p.venue_id and user_id = auth.uid();
  if c.id is null or not exists (
    select 1 from venue_members m
    where m.venue_id = p.venue_id and m.user_id = auth.uid()
      and m.is_active and m.role = 'customer'
  ) then
    raise exception 'FORBIDDEN';
  end if;

  r := app.begin_op(
    p_op,
    p.venue_id,
    'request_standalone_product_order',
    jsonb_build_object(
      'product_id', p_product,
      'quantity', p_quantity,
      'expected_price', p_expected_price
    )
  );
  if r is not null then return r; end if;
  if p_expected_price is null or p.sale_price <> p_expected_price then
    raise exception 'PRODUCT_PRICE_CHANGED';
  end if;
  if not p.is_available then raise exception 'PRODUCT_NOT_AVAILABLE'; end if;
  if p.stock_quantity < p_quantity then raise exception 'INSUFFICIENT_STOCK'; end if;

  insert into customer_order_requests(
    venue_id, customer_id, product_id, quantity, expected_unit_price
  )
  values (p.venue_id, c.id, p.id, p_quantity, p.sale_price)
  returning * into req;

  for staff_user in
    select m.user_id from venue_members m
    where m.venue_id = p.venue_id and m.is_active
      and m.role in ('owner', 'manager', 'employee')
  loop
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      p.venue_id, staff_user.user_id, 'standalone_order_requested',
      'Nouvelle commande client',
      format('%s × %s · paiement au comptoir', p_quantity, p.name),
      'customer_order_request', req.id,
      jsonb_build_object('customer_id', c.id, 'product_id', p.id)
    );
  end loop;

  return app.end_op(
    p_op,
    jsonb_build_object('request_id', req.id, 'status', req.status)
  );
end
$$;

create or replace function public.process_standalone_order_request(
  p_op uuid,
  p_request uuid,
  p_complete boolean,
  p_method payment_method default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  req customer_order_requests;
  p products;
  o orders;
  inv invoices;
  total_amount numeric(12,2);
  customer_user uuid;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_complete is null then raise exception 'INVALID_ORDER_DECISION'; end if;
  select * into req from customer_order_requests where id = p_request for update;
  if req.id is null then raise exception 'ORDER_REQUEST_NOT_FOUND'; end if;
  if not app.is_staff(req.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(
    p_op,
    req.venue_id,
    'process_standalone_order_request',
    jsonb_build_object(
      'request_id', p_request,
      'complete', p_complete,
      'method', p_method
    )
  );
  if r is not null then return r; end if;
  if req.status <> 'pending' then raise exception 'ORDER_REQUEST_ALREADY_HANDLED'; end if;
  if p_complete and p_method is null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  if not p_complete then
    update customer_order_requests
       set status = 'rejected', handled_by = auth.uid(), handled_at = now()
     where id = req.id;
    perform app.audit(
      req.venue_id,
      'standalone_order_rejected',
      'customer_order_request',
      req.id::text,
      jsonb_build_object('customer_id', req.customer_id)
    );
    select user_id into customer_user from customers where id = req.customer_id;
    if customer_user is not null then
      insert into notifications(
        venue_id, recipient_id, type, title, body,
        reference_type, reference_id, data
      )
      values (
        req.venue_id, customer_user, 'standalone_order_rejected',
        'Commande indisponible',
        'L’équipe ne peut pas traiter votre demande. Contactez un employé.',
        'customer_order_request', req.id, '{}'::jsonb
      );
    end if;
    return app.end_op(
      p_op,
      jsonb_build_object('request_id', req.id, 'status', 'rejected')
    );
  end if;

  select * into p from products where id = req.product_id for update;
  if p.id is null or p.venue_id <> req.venue_id then
    raise exception 'PRODUCT_NOT_FOUND';
  end if;
  if not p.is_available then raise exception 'PRODUCT_NOT_AVAILABLE'; end if;
  if p.sale_price <> req.expected_unit_price then
    raise exception 'PRODUCT_PRICE_CHANGED';
  end if;
  if p.stock_quantity < req.quantity then raise exception 'INSUFFICIENT_STOCK'; end if;

  total_amount := round(p.sale_price * req.quantity, 2);
  insert into orders(venue_id, customer_id, status, total, created_by)
  values (req.venue_id, req.customer_id, 'paid', total_amount, auth.uid())
  returning * into o;
  insert into order_items(venue_id, order_id, product_id, quantity, unit_price)
  values (req.venue_id, o.id, p.id, req.quantity, p.sale_price);

  perform set_config('app.inventory_rpc', 'on', true);
  update products set stock_quantity = stock_quantity - req.quantity
   where id = p.id returning * into p;
  perform set_config('app.inventory_rpc', 'off', true);

  insert into inventory_movements(
    venue_id, product_id, quantity_delta, reason, created_by
  )
  values (req.venue_id, p.id, -req.quantity, 'sale', auth.uid());
  insert into payments(venue_id, order_id, method, amount, created_by)
  values (req.venue_id, o.id, p_method, total_amount, auth.uid());
  insert into invoices(venue_id, order_id, customer_id, total, created_by)
  values (req.venue_id, o.id, req.customer_id, total_amount, auth.uid())
  returning * into inv;

  update customer_order_requests
     set status = 'completed', order_id = o.id,
         handled_by = auth.uid(), handled_at = now()
   where id = req.id;

  perform app.audit(
    req.venue_id,
    'standalone_product_sale',
    'order',
    o.id::text,
    jsonb_build_object(
      'request_id', req.id,
      'customer_id', req.customer_id,
      'product_id', p.id,
      'quantity', req.quantity,
      'total', total_amount,
      'invoice_id', inv.id
    )
  );

  select user_id into customer_user from customers where id = req.customer_id;
  if customer_user is not null then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      req.venue_id, customer_user, 'standalone_order_completed',
      'Commande payée',
      format('Facture n° %s · %s DA', inv.number, total_amount),
      'order', o.id,
      jsonb_build_object(
        'request_id', req.id,
        'invoice_id', inv.id,
        'invoice_number', inv.number
      )
    );
  end if;

  return app.end_op(
    p_op,
    jsonb_build_object(
      'request_id', req.id,
      'order_id', o.id,
      'invoice_id', inv.id,
      'invoice_number', inv.number,
      'total', total_amount,
      'stock_quantity', p.stock_quantity
    )
  );
end
$$;

revoke all on function public.request_standalone_product_order(uuid,uuid,int,numeric)
  from public, anon;
revoke all on function public.process_standalone_order_request(uuid,uuid,boolean,payment_method)
  from public, anon;
grant execute on function public.request_standalone_product_order(uuid,uuid,int,numeric)
  to authenticated;
grant execute on function public.process_standalone_order_request(uuid,uuid,boolean,payment_method)
  to authenticated;
