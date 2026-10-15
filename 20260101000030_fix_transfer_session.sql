-- 030 FIX SESSION TRANSFER ENGINE
-- Ensures robust post transfer between stations with automatic post status sync and audit logs.

create or replace function public.transfer_session(
  p_op uuid,
  p_session uuid,
  p_new_post uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s sessions;
  np posts;
  old_post uuid;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;

  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;

  r := app.begin_op(p_op, s.venue_id, 'transfer_session', jsonb_build_object('session_id', p_session, 'new_post_id', p_new_post));
  if r is not null then return r; end if;

  if s.status not in ('active', 'paused') then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if p_new_post = s.post_id then raise exception 'SAME_POST'; end if;

  select * into np from posts where id = p_new_post and venue_id = s.venue_id;
  if np.id is null then raise exception 'POST_NOT_FOUND'; end if;
  if np.status not in ('available', 'reserved') then raise exception 'POST_NOT_AVAILABLE'; end if;

  -- Check if new post supports the session's active game
  if exists (select 1 from post_games where post_id = p_new_post)
     and not exists (select 1 from post_games where post_id = p_new_post and game_id = s.game_id) then
    raise exception 'GAME_NOT_SUPPORTED_ON_POST';
  end if;

  old_post := s.post_id;

  -- Update session to point to the new post
  update sessions
     set post_id = p_new_post,
         version = version + 1,
         updated_at = now()
   where id = s.id;

  -- Insert transferred session event
  insert into session_events(venue_id, session_id, type, meta, created_by)
  values (s.venue_id, s.id, 'transferred', jsonb_build_object('from', old_post, 'to', p_new_post), auth.uid());

  -- Sync status of old post and new post
  update posts set status = 'available' where id = old_post and status <> 'maintenance';
  update posts set status = 'occupied' where id = p_new_post and status <> 'maintenance';

  perform app._sync_post(old_post);
  perform app._sync_post(p_new_post);

  perform app.audit(
    s.venue_id, 'session_transfer', 'session', s.id::text,
    jsonb_build_object('from', old_post, 'to', p_new_post)
  );

  return app.end_op(p_op, app._session_json(s.id));
end;
$$;

grant execute on function public.transfer_session(uuid, uuid, uuid) to authenticated;
