-- 029 FIX MATCH DURATION & PRICING CALCULATION WITH REAL TIME MULTIPLIER
-- Formula: real_time_seconds = round(selected_match_minutes * time_multiplier * 60)

create or replace function app._add_match_custom(
  p_session uuid,
  p_initial_minutes int,
  p_request uuid default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  s sessions;
  g games;
  v_multiplier numeric;
  v_add_seconds int;
  v_unit_price numeric;
  v_tier_key text;
begin
  select * into s from sessions where id = p_session;
  select * into g from games where id = s.game_id;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;

  v_multiplier := coalesce(g.time_multiplier, 1.0);
  v_add_seconds := round(p_initial_minutes * v_multiplier * 60)::int;
  v_tier_key := p_initial_minutes::text;

  -- Check if pricing_tiers contains a specific tier price for this minute duration (e.g. 6m, 8m, 10m, 16m)
  if g.pricing_tiers is not null and g.pricing_tiers ? v_tier_key then
    v_unit_price := (g.pricing_tiers ->> v_tier_key)::numeric;
  else
    v_unit_price := g.price;
  end if;

  insert into session_events(
    venue_id, session_id, type, qty, unit_price, amount, added_seconds, game_id, meta, created_by
  )
  values (
    s.venue_id, s.id, 'match_added', 1, v_unit_price, v_unit_price, v_add_seconds, g.id,
    jsonb_build_object('match_minutes', p_initial_minutes, 'time_multiplier', v_multiplier, 'request_id', p_request), auth.uid()
  );

  update sessions
     set match_count = match_count + 1,
         planned_duration_seconds = planned_duration_seconds + v_add_seconds,
         version = version + 1,
         updated_at = now()
   where id = s.id;

  perform app.audit(
    s.venue_id, 'match_added', 'session', s.id::text,
    jsonb_build_object('match_minutes', p_initial_minutes, 'multiplier', v_multiplier, 'price', v_unit_price, 'added_seconds', v_add_seconds)
  );
end;
$$;

create or replace function public.start_session(
  p_op uuid,
  p_post uuid,
  p_game uuid,
  p_customer uuid default null,
  p_initial_minutes int default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  po posts;
  g games;
  s sessions;
  r jsonb;
  v_minutes int;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into po from posts where id = p_post for update;
  if po.id is null then raise exception 'POST_NOT_FOUND'; end if;
  if not app.is_staff(po.venue_id) then raise exception 'FORBIDDEN'; end if;

  r := app.begin_op(
    p_op,
    po.venue_id,
    'start_session',
    jsonb_build_object(
      'post_id', p_post,
      'game_id', p_game,
      'customer_id', p_customer,
      'initial_minutes', p_initial_minutes
    )
  );
  if r is not null then return r; end if;
  if po.status not in ('available', 'reserved') then raise exception 'POST_NOT_AVAILABLE'; end if;

  select * into g from games where id = p_game and venue_id = po.venue_id;
  if g.id is null or not g.is_available then raise exception 'GAME_NOT_AVAILABLE'; end if;

  if exists (select 1 from post_games where post_id = p_post)
     and not exists (select 1 from post_games where post_id = p_post and game_id = p_game) then
    raise exception 'GAME_NOT_SUPPORTED_ON_POST';
  end if;

  if p_customer is not null and not exists (select 1 from customers where id = p_customer and venue_id = po.venue_id) then
    raise exception 'CUSTOMER_NOT_FOUND';
  end if;

  insert into sessions(venue_id, customer_id, post_id, game_id, created_by, status, started_at)
  values (po.venue_id, p_customer, p_post, p_game, auth.uid(), 'active', now())
  returning * into s;

  insert into session_events(venue_id, session_id, type, game_id, created_by)
  values (s.venue_id, s.id, 'started', g.id, auth.uid());

  if g.game_mode = 'match_based' then
    v_minutes := coalesce(p_initial_minutes, g.match_minutes, 10);
    perform app._add_match_custom(s.id, v_minutes);
  elsif g.game_mode in ('time_based', 'custom') then
    if coalesce(p_initial_minutes, 0) <= 0 then raise exception 'INITIAL_DURATION_REQUIRED'; end if;
    perform app._add_time(s.id, p_initial_minutes, null, true);
  end if;

  perform app._sync_post(po.id);
  perform app.audit(
    s.venue_id,
    'session_start',
    'session',
    s.id::text,
    jsonb_build_object('post', po.name, 'game', g.name, 'minutes', v_minutes)
  );
  return app.end_op(p_op, app._session_json(s.id));
end;
$$;

grant execute on function public.start_session(uuid, uuid, uuid, uuid, int) to authenticated;
