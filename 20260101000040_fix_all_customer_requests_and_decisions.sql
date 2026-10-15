-- Migration 040: Fix all customer request types and decisions handling
-- Resolves: REQUEST_TYPE_NOT_SUPPORTED, GAME_NOT_TIME_BASED on decide_request, product requests approval, and pause requests

create or replace function public.decide_request(
  p_op uuid,
  p_request uuid,
  p_approve boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  req session_requests;
  s sessions;
  g games;
  po posts;
  cust_user uuid;
  r jsonb;
  v_prod_price numeric(12,2);
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;

  select * into req from session_requests where id = p_request;
  if req.id is null then raise exception 'REQUEST_NOT_FOUND'; end if;
  if not app.is_staff(req.venue_id) then raise exception 'FORBIDDEN'; end if;

  if req.session_id is not null then
    s := app._lock_session(req.session_id);
    if s.game_id is not null then
      select * into g from games where id = s.game_id;
    end if;
  end if;

  select * into req from session_requests where id = p_request for update;
  r := app.begin_op(p_op, req.venue_id, 'decide_request',
                    jsonb_build_object('request_id', p_request, 'approve', p_approve));
  if r is not null then return r; end if;
  if req.status <> 'pending' then raise exception 'REQUEST_NOT_PENDING'; end if;

  if p_approve then
    if req.type = 'match' then
      if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
      perform app._add_match_custom(s.id, coalesce((req.payload ->> 'qty')::int, 1), req.id);

    elsif req.type = 'time' then
      if (req.payload ->> 'pause_requested')::boolean = true then
        if s.status = 'active' then
          perform public.pause_session(gen_random_uuid(), s.id);
        elsif s.status = 'paused' then
          perform public.resume_session(gen_random_uuid(), s.id);
        end if;
      else
        if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
        if g.id is not null and g.game_mode = 'match_based' then
          perform app._add_match_custom(s.id, coalesce((req.payload ->> 'minutes')::int, 10), req.id);
        else
          perform app._add_time(s.id, coalesce((req.payload ->> 'minutes')::int, 30), req.id);
        end if;
      end if;

    elsif req.type = 'checkout' then
      if s.status not in ('active', 'paused') then raise exception 'SESSION_NOT_ACTIVE'; end if;
      perform app._end(s.id);

    elsif req.type = 'start_session' then
      perform public.start_session(
        p_op := gen_random_uuid(),
        p_post := req.post_id,
        p_game := (req.payload ->> 'game_id')::uuid,
        p_customer := req.customer_id,
        p_initial_minutes := (req.payload ->> 'minutes')::int
      );
      select id into req.session_id from sessions where post_id = req.post_id and status in ('active','paused') order by created_at desc limit 1;

    elsif req.type = 'product' then
      if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
      select sale_price into v_prod_price from products where id = (req.payload ->> 'product_id')::uuid;
      perform public.customer_add_product_to_session(
        p_op := gen_random_uuid(),
        p_session := s.id,
        p_product := (req.payload ->> 'product_id')::uuid,
        p_quantity := coalesce((req.payload ->> 'quantity')::int, 1),
        p_expected_price := coalesce((req.payload ->> 'unit_price')::numeric, v_prod_price)
      );

    else
      raise exception 'REQUEST_TYPE_NOT_SUPPORTED';
    end if;
  end if;

  update session_requests
     set status = case when p_approve then 'completed'::request_status else 'rejected' end,
         session_id = req.session_id,
         handled_by = auth.uid(),
         handled_at = now()
   where id = req.id
  returning * into req;

  select * into po from posts where id = req.post_id;
  select user_id into cust_user from customers where id = req.customer_id;
  if cust_user is not null then
    insert into notifications(venue_id, recipient_id, type, title, body, reference_type, reference_id, data)
    values (
      req.venue_id, cust_user, 'request_decided',
      case when p_approve then 'Demande acceptée' else 'Demande refusée' end,
      po.name || case req.type when 'match' then ' : match' when 'time' then ' : temps' when 'product' then ' : produit' when 'start_session' then ' : démarrage de session' else ' : clôture' end,
      'session', coalesce(req.session_id, req.post_id::uuid), jsonb_build_object('post_id', po.id, 'request_id', req.id)
    );
  end if;

  perform app.audit(req.venue_id, 'request_' || req.status, 'session_request', req.id::text, to_jsonb(req));
  return app.end_op(
    p_op,
    jsonb_build_object(
      'request', to_jsonb(req),
      'session', case when req.session_id is not null then app._session_json(req.session_id) else null end
    )
  );
end;
$$;

grant execute on function public.decide_request(uuid, uuid, boolean) to authenticated;
