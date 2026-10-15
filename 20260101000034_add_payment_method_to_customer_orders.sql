-- 034 ADD PAYMENT METHOD TO CUSTOMER ORDER REQUESTS
alter table customer_order_requests add column if not exists payment_method payment_method not null default 'cash';

create or replace function public.request_standalone_product_order(
  p_op uuid,
  p_product uuid,
  p_quantity int,
  p_expected_price numeric(12,2),
  p_method text default 'cash'
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
  method_label text;
  v_method payment_method;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'INVALID_QUANTITY';
  end if;
  if p_method is null or p_method = '' then raise exception 'INVALID_PAYMENT_METHOD'; end if;

  begin
    v_method := p_method::payment_method;
  exception when others then
    v_method := 'cash'::payment_method;
  end;

  select * into p from products where id = p_product for update;
  if p.id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  select * into c from customers
   where venue_id = p.venue_id and user_id = auth.uid();
  if c.id is null then
    raise exception 'FORBIDDEN';
  end if;

  r := app.begin_op(
    p_op,
    p.venue_id,
    'request_standalone_product_order',
    jsonb_build_object(
      'product_id', p_product,
      'quantity', p_quantity,
      'expected_price', p_expected_price,
      'method', v_method
    )
  );
  if r is not null then return r; end if;
  if p_expected_price is null or p.sale_price <> p_expected_price then
    raise exception 'PRODUCT_PRICE_CHANGED';
  end if;
  if not p.is_available then raise exception 'PRODUCT_NOT_AVAILABLE'; end if;
  if p.stock_quantity < p_quantity then raise exception 'INSUFFICIENT_STOCK'; end if;

  insert into customer_order_requests(
    venue_id, customer_id, product_id, quantity, expected_unit_price, payment_method
  )
  values (p.venue_id, c.id, p.id, p_quantity, p.sale_price, v_method)
  returning * into req;

  method_label := case v_method
    when 'cash' then 'espèces'
    when 'card' then 'carte'
    when 'wallet' then 'portefeuille'
    when 'credit' then 'à crédit (sur facture / sur l''äjel)'
    else v_method::text
  end;

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
      format('%s × %s · paiement : %s', p_quantity, p.name, method_label),
      'customer_order_request', req.id,
      jsonb_build_object('customer_id', c.id, 'product_id', p.id, 'payment_method', v_method)
    );
  end loop;

  return app.end_op(
    p_op,
    jsonb_build_object('request_id', req.id, 'status', req.status, 'payment_method', v_method)
  );
end
$$;

revoke all on function public.request_standalone_product_order(uuid, uuid, int, numeric, text);
grant execute on function public.request_standalone_product_order(uuid, uuid, int, numeric, text) to authenticated;
