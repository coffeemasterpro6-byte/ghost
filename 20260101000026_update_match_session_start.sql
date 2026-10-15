-- Migration: Update public.start_session to calculate initial match count dynamically from p_initial_minutes and g.match_minutes
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
  v_match_count int := 1;
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
    if p_initial_minutes is not null and g.match_minutes is not null and g.match_minutes > 0 then
      v_match_count := greatest(1, p_initial_minutes / g.match_minutes);
    elsif p_initial_minutes is not null then
      v_match_count := greatest(1, p_initial_minutes / 10);
    end if;
    perform app._add_match(s.id, v_match_count); -- internal helper or app._add_match
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
    jsonb_build_object('post', po.name, 'game', g.name, 'match_count', v_match_count)
  );
  return app.end_op(p_op, app._session_json(s.id));
end
$$;

revoke all on function public.start_session(uuid, uuid, uuid, uuid, int) from public, anon;
grant execute on function public.start_session(uuid, uuid, uuid, uuid, int) to authenticated;
