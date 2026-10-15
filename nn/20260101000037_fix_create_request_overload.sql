-- Fix function overloading conflict (PGRST203) for create_request
drop function if exists public.create_request(uuid, uuid, text, jsonb);
drop function if exists public.create_request(uuid, uuid, request_type, jsonb);

create or replace function public.create_request(
  p_op uuid,
  p_session uuid,
  p_type text,
  p_payload jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s sessions;
  g games;
  po posts;
  c customers;
  req session_requests;
  r jsonb;
  qty int;
  mins int;
  label text;
  v_req_type request_type;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;

  begin
    v_req_type := p_type::request_type;
  exception when others then
    raise exception 'REQUEST_TYPE_NOT_SUPPORTED';
  end;

  s := app._lock_session(p_session);
  if not (app.is_staff(s.venue_id)
          or exists (select 1 from customers cc where cc.id = s.customer_id and cc.user_id = auth.uid())) then
    raise exception 'FORBIDDEN';
  end if;

  r := app.begin_op(p_op, s.venue_id, 'create_request',
                    jsonb_build_object('session_id', p_session, 'type', p_type, 'payload', p_payload));
  if r is not null then return r; end if;

  if p_type not in ('match','time','checkout','product') then
    raise exception 'REQUEST_TYPE_NOT_SUPPORTED';
  end if;

  if s.status not in ('active', 'paused') then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

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
  elsif p_type = 'product' then
    label := ' demande un snack / produit';
  else
    label := ' demande la clôture';
    p_payload := '{}'::jsonb;
  end if;

  begin
    insert into session_requests(venue_id, session_id, post_id, customer_id, type, payload, created_by)
    values (s.venue_id, s.id, s.post_id, s.customer_id, v_req_type, p_payload, auth.uid())
    returning * into req;
  exception when unique_violation then
    raise exception 'REQUEST_ALREADY_PENDING';
  end;

  insert into notifications(venue_id, recipient_id, type, title, body, reference_type, reference_id, data)
  select s.venue_id, m.user_id, 'request_created', 'Nouvelle demande',
         po.name || ' : ' || coalesce(c.full_name, 'Client') || label,
         'session_request', req.id, jsonb_build_object('post_id', po.id, 'session_id', s.id)
  from venue_members m where m.venue_id = s.venue_id and m.is_active and m.role in ('owner','manager','employee');

  return app.end_op(p_op, jsonb_build_object('request', to_jsonb(req), 'session', app._session_json(s.id)));
end;
$$;

grant execute on function public.create_request(uuid, uuid, text, jsonb) to authenticated;
