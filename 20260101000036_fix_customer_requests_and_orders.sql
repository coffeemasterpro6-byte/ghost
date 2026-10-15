-- Fix customer session product order RPC (remove invalid venue_members join for customers)
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
  if not (
    app.is_staff(s.venue_id)
    or exists (
      select 1
        from customers c
       where c.id = s.customer_id
         and c.venue_id = s.venue_id
         and c.user_id = auth.uid()
    )
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

-- Fix create_request RPC to support time, match, checkout, and pause requests properly
create or replace function public.create_request(p_op uuid, p_session uuid, p_type request_type, p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare s sessions; g games; po posts; c customers; req session_requests; r jsonb; qty int; mins int; label text;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  s := app._lock_session(p_session);
  if not (app.is_staff(s.venue_id)
          or exists (select 1 from customers cc where cc.id = s.customer_id and cc.user_id = auth.uid())) then
    raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'create_request',
                    jsonb_build_object('session_id', p_session, 'type', p_type, 'payload', p_payload));
  if r is not null then return r; end if;
  if p_type not in ('match','time','checkout','product') then raise exception 'REQUEST_TYPE_NOT_SUPPORTED'; end if;
  if s.status not in ('active', 'paused') then raise exception 'SESSION_NOT_ACTIVE'; end if;
  select * into g from games where id = s.game_id;
  select * into po from posts where id = s.post_id;
  select * into c from customers where id = s.customer_id;
  if p_type = 'match' then
    qty := coalesce((p_payload ->> 'qty')::int, 1);
    if qty < 1 or qty > 10 then raise exception 'INVALID_QUANTITY'; end if;
    label := ' demande +' || qty || ' match';
    p_payload := jsonb_build_object('qty', qty);
  elsif p_type = 'time' then
    mins := (p_payload ->> 'minutes')::int;
    if (p_payload ->> 'pause_requested')::boolean = true then
      label := ' demande une pause';
    else
      if mins is null or mins < 5 or mins > 240 then mins := 30; end if;
      label := ' demande +' || mins || ' min';
      p_payload := jsonb_build_object('minutes', mins);
    end if;
  else
    label := ' demande la clôture';
    p_payload := '{}'::jsonb;
  end if;
  begin
    insert into session_requests(venue_id, session_id, post_id, customer_id, type, payload, created_by)
    values (s.venue_id, s.id, s.post_id, s.customer_id, p_type, p_payload, auth.uid()) returning * into req;
  exception when unique_violation then raise exception 'REQUEST_ALREADY_PENDING';
  end;
  insert into notifications(venue_id, recipient_id, type, title, body, reference_type, reference_id, data)
  select s.venue_id, m.user_id, 'request_created', 'Nouvelle demande',
         po.name || ' : ' || coalesce(c.full_name, 'Client') || label,
         'session_request', req.id, jsonb_build_object('post_id', po.id, 'session_id', s.id)
  from venue_members m where m.venue_id = s.venue_id and m.is_active and m.role in ('owner','manager','employee');

  return app.end_op(p_op, jsonb_build_object('request', to_jsonb(req), 'session', app._session_json(s.id)));
end;
$$;

grant execute on function public.customer_add_product_to_session(uuid,uuid,uuid,int,numeric) to authenticated;
grant execute on function public.create_request(uuid,uuid,request_type,jsonb) to authenticated;
