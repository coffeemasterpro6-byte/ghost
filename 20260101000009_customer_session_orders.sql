-- Customers may browse available products in venues where they are registered.
create policy products_customer_read on products
  for select using (
    is_available
    and exists (
      select 1
        from customers c
        join venue_members m
          on m.venue_id = c.venue_id
         and m.user_id = c.user_id
       where c.venue_id = products.venue_id
         and c.user_id = auth.uid()
         and m.is_active
         and m.role = 'customer'
    )
  );

-- Let linked customers receive product stock updates for their venue catalog.
create or replace function app.can_listen(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  parts text[] := string_to_array(p_topic, ':');
begin
  if parts[1] = 'venue' and array_length(parts, 1) = 3 then
    return case
      when parts[3] in ('catalog', 'inventory') then app.is_member(parts[2]::uuid)
      else app.is_staff(parts[2]::uuid)
    end;
  elsif parts[1] = 'session' then
    return exists (
      select 1
        from sessions s
       where s.id = parts[2]::uuid
         and (
           app.is_staff(s.venue_id)
           or exists (
             select 1
               from customers c
              where c.id = s.customer_id
                and c.user_id = auth.uid()
           )
         )
    );
  elsif parts[1] = 'user' then
    return parts[2]::uuid = auth.uid();
  end if;
  return false;
exception when others then
  return false;
end
$$;

create or replace function public.customer_add_product_to_session(
  p_op uuid,
  p_session uuid,
  p_product uuid,
  p_quantity int,
  p_expected_price numeric(12,2)
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  p products;
  o orders;
  total_amount numeric(12,2);
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;

  s := app._lock_session(p_session);
  if not exists (
    select 1
      from customers c
      join venue_members m
        on m.venue_id = c.venue_id
       and m.user_id = c.user_id
     where c.id = s.customer_id
       and c.venue_id = s.venue_id
       and c.user_id = auth.uid()
       and m.is_active
       and m.role = 'customer'
  ) then
    raise exception 'FORBIDDEN';
  end if;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'INVALID_QUANTITY';
  end if;

  select * into p
    from products
   where id = p_product and venue_id = s.venue_id
   for update;
  if p.id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;

  r := app.begin_op(
    p_op,
    s.venue_id,
    'customer_add_product_to_session',
    jsonb_build_object(
      'session_id', p_session,
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

  total_amount := round(p.sale_price * p_quantity, 2);
  insert into orders(venue_id, session_id, customer_id, status, total, created_by)
  values (s.venue_id, s.id, s.customer_id, 'added_to_session', total_amount, auth.uid())
  returning * into o;
  insert into order_items(venue_id, order_id, product_id, quantity, unit_price)
  values (s.venue_id, o.id, p.id, p_quantity, p.sale_price);

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
    'customer_product_ordered',
    'order',
    o.id::text,
    jsonb_build_object(
      'customer_id', s.customer_id,
      'session_id', s.id,
      'product_id', p.id,
      'quantity', p_quantity,
      'total', total_amount
    )
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

revoke all on function public.customer_add_product_to_session(uuid,uuid,uuid,int,numeric)
  from public, anon;
grant execute on function public.customer_add_product_to_session(uuid,uuid,uuid,int,numeric)
  to authenticated;
