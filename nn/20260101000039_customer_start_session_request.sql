-- Migration 039: Support customer session start requests without staff privileges
-- 1. Make session_id nullable in session_requests for requests that precede a session (like start_session)
alter table session_requests alter column session_id drop not null;

-- 2. Create RPC function for customer to request starting a session
create or replace function public.request_start_session(
  p_op uuid,
  p_post uuid,
  p_game uuid,
  p_minutes int default 60
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  po posts;
  g games;
  c customers;
  req session_requests;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into po from posts where id = p_post for update;
  if po.id is null then raise exception 'POST_NOT_FOUND'; end if;

  select * into c from customers where user_id = auth.uid() and venue_id = po.venue_id;
  if c.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;

  r := app.begin_op(p_op, po.venue_id, 'request_start_session',
                    jsonb_build_object('post_id', p_post, 'game_id', p_game, 'minutes', p_minutes));
  if r is not null then return r; end if;

  if po.status not in ('available','reserved') then raise exception 'POST_NOT_AVAILABLE'; end if;

  select * into g from games where id = p_game and venue_id = po.venue_id;
  if g.id is null or not g.is_available then raise exception 'GAME_NOT_AVAILABLE'; end if;

  if exists (
    select 1 from session_requests
    where post_id = p_post and type = 'start_session' and status = 'pending'
  ) then
    raise exception 'REQUEST_ALREADY_PENDING';
  end if;

  insert into session_requests(venue_id, session_id, post_id, customer_id, type, payload, created_by)
  values (po.venue_id, null, po.id, c.id, 'start_session', jsonb_build_object('game_id', p_game, 'minutes', p_minutes), auth.uid())
  returning * into req;

  insert into notifications(venue_id, recipient_id, type, title, body, reference_type, reference_id, data)
  select po.venue_id, m.user_id, 'request_created', 'Demande de démarrage de session',
         po.name || ' : ' || coalesce(c.full_name, 'Client') || ' demande à démarrer une session',
         'session_request', req.id, jsonb_build_object('post_id', po.id)
  from venue_members m where m.venue_id = po.venue_id and m.is_active and m.role in ('owner','manager','employee');

  return app.end_op(p_op, to_jsonb(req));
end $$;

grant execute on function public.request_start_session(uuid, uuid, uuid, int) to authenticated;

-- 3. Update decide_request to handle start_session type by calling start_session
create or replace function public.decide_request(p_op uuid, p_request uuid, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare req session_requests; s sessions; po posts; cust_user uuid; r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into req from session_requests where id = p_request;
  if req.id is null then raise exception 'REQUEST_NOT_FOUND'; end if;
  if not app.is_staff(req.venue_id) then raise exception 'FORBIDDEN'; end if;

  if req.session_id is not null then
    s := app._lock_session(req.session_id);
  end if;

  select * into req from session_requests where id = p_request for update;
  r := app.begin_op(p_op, req.venue_id, 'decide_request',
                    jsonb_build_object('request_id', p_request, 'approve', p_approve));
  if r is not null then return r; end if;
  if req.status <> 'pending' then raise exception 'REQUEST_NOT_PENDING'; end if;

  if p_approve then
    if req.type = 'match' then
      if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
      perform app._add_match(s.id, (req.payload ->> 'qty')::int, req.id);
    elsif req.type = 'time' then
      if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
      perform app._add_time(s.id, (req.payload ->> 'minutes')::int, req.id);
    elsif req.type = 'checkout' then
      if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
      perform app._end(s.id);
    elsif req.type = 'start_session' then
      -- Call original start_session function
      perform public.start_session(
        p_op := gen_random_uuid(),
        p_post := req.post_id,
        p_game := (req.payload ->> 'game_id')::uuid,
        p_customer := req.customer_id,
        p_initial_minutes := (req.payload ->> 'minutes')::int
      );
      select id into req.session_id from sessions where post_id = req.post_id and status in ('active','paused') order by created_at desc limit 1;
    else raise exception 'REQUEST_TYPE_NOT_SUPPORTED'; end if;
  end if;

  update session_requests set status = case when p_approve then 'completed'::request_status else 'rejected' end,
                              session_id = req.session_id,
                              handled_by = auth.uid(), handled_at = now()
   where id = req.id returning * into req;

  select * into po from posts where id = req.post_id;
  select user_id into cust_user from customers where id = req.customer_id;
  if cust_user is not null then
    insert into notifications(venue_id, recipient_id, type, title, body, reference_type, reference_id, data)
    values (req.venue_id, cust_user, 'request_decided',
            case when p_approve then 'Demande acceptée' else 'Demande refusée' end,
            po.name || case req.type when 'match' then ' : match' when 'time' then ' : temps' when 'start_session' then ' : démarrage de session' else ' : clôture' end,
            'session', coalesce(req.session_id, req.post_id::uuid), jsonb_build_object('post_id', po.id, 'request_id', req.id));
  end if;
  perform app.audit(req.venue_id, 'request_' || req.status, 'session_request', req.id::text, to_jsonb(req));
  return app.end_op(p_op, jsonb_build_object('request', to_jsonb(req), 'session', case when req.session_id is not null then app._session_json(req.session_id) else null end));
end $$;
