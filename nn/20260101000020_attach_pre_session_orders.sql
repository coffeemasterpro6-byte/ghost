create policy orders_customer_read on orders
  for select using (
    exists (
      select 1 from customers c
      where c.id = customer_id and c.user_id = auth.uid()
    )
  );

create or replace function public.attach_pre_session_order(
  p_op uuid,
  p_request uuid,
  p_session uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  req customer_order_requests;
  s sessions;
  o orders;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;

  select * into req
    from customer_order_requests
   where id = p_request
   for update;
  if req.id is null or req.status <> 'completed' or req.order_id is null then
    raise exception 'PRE_SESSION_ORDER_NOT_FOUND';
  end if;

  s := app._lock_session(p_session);
  if s.venue_id <> req.venue_id or s.customer_id <> req.customer_id then
    raise exception 'FORBIDDEN';
  end if;
  if not exists (
    select 1 from customers c
    join venue_members m on m.venue_id = c.venue_id and m.user_id = c.user_id
    where c.id = s.customer_id
      and c.user_id = auth.uid()
      and m.is_active
      and m.role = 'customer'
  ) then
    raise exception 'FORBIDDEN';
  end if;
  if s.status not in ('active', 'paused') then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

  select * into o from orders where id = req.order_id for update;
  if o.id is null or o.venue_id <> req.venue_id
     or o.customer_id <> req.customer_id then
    raise exception 'PRE_SESSION_ORDER_NOT_FOUND';
  end if;

  r := app.begin_op(
    p_op,
    req.venue_id,
    'attach_pre_session_order',
    jsonb_build_object('request_id', p_request, 'session_id', p_session)
  );
  if r is not null then return r; end if;

  if o.status <> 'paid' or o.session_id is not null then
    raise exception 'PRE_SESSION_ORDER_ALREADY_ATTACHED';
  end if;

  update orders set session_id = s.id where id = o.id;
  perform app.audit(
    req.venue_id,
    'pre_session_order_attached',
    'order',
    o.id::text,
    jsonb_build_object('request_id', req.id, 'session_id', s.id)
  );

  return app.end_op(
    p_op,
    jsonb_build_object(
      'order_id', o.id,
      'session_id', s.id,
      'already_paid', true,
      'added_to_session_bill', false
    )
  );
end
$$;

revoke all on function public.attach_pre_session_order(uuid,uuid,uuid)
  from public, anon;
grant execute on function public.attach_pre_session_order(uuid,uuid,uuid)
  to authenticated;
