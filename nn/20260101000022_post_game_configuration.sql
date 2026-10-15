create table post_game_prices (
  post_id uuid not null references posts(id) on delete cascade,
  game_id uuid not null references games(id) on delete cascade,
  price_override numeric(12, 2) not null check (price_override >= 0),
  primary key (post_id, game_id)
);

alter table post_game_prices enable row level security;
create policy post_game_prices_member_read on post_game_prices
  for select using (
    exists (
      select 1 from posts p
      where p.id = post_game_prices.post_id and app.is_member(p.venue_id)
    )
  );
create policy post_game_prices_admin_write on post_game_prices
  for all using (
    exists (
      select 1 from posts p
      where p.id = post_game_prices.post_id and app.is_admin(p.venue_id)
    )
  )
  with check (
    exists (
      select 1 from posts p
      join games g
        on g.id = post_game_prices.game_id
       and g.venue_id = p.venue_id
      where p.id = post_game_prices.post_id
        and app.is_admin(p.venue_id)
    )
  );
grant select on post_game_prices to authenticated;

create or replace function app._add_match(
  p_session uuid,
  p_qty int,
  p_request uuid default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  g games;
  add_s int;
  price numeric(12, 2);
begin
  select * into s from sessions where id = p_session;
  select * into g from games where id = s.game_id;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if g.game_mode <> 'match_based' then raise exception 'GAME_NOT_MATCH_BASED'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;
  select price_override into price
  from post_game_prices
  where post_id = s.post_id and game_id = g.id;
  g.price := coalesce(price, g.price);
  add_s := p_qty * g.effective_match_seconds;
  insert into session_events(venue_id, session_id, type, qty, unit_price, amount, added_seconds, game_id, meta, created_by)
  values (s.venue_id, s.id, 'match_added', p_qty, g.price, p_qty * g.price, add_s, g.id,
          jsonb_build_object('match_from', s.match_count + 1, 'match_to', s.match_count + p_qty, 'request_id', p_request), auth.uid());
  update sessions set match_count = match_count + p_qty,
                      planned_duration_seconds = planned_duration_seconds + add_s,
                      version = version + 1, updated_at = now() where id = s.id;
  perform app.audit(s.venue_id, 'match_added', 'session', s.id::text,
                    jsonb_build_object('qty', p_qty, 'unit_price', g.price, 'added_seconds', add_s));
end;
$$;

create or replace function app._add_time(
  p_session uuid,
  p_minutes int,
  p_request uuid default null,
  p_first boolean default false
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  g games;
  amt numeric;
  price numeric(12, 2);
begin
  select * into s from sessions where id = p_session;
  select * into g from games where id = s.game_id;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if g.game_mode = 'match_based' then raise exception 'GAME_NOT_TIME_BASED'; end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 600 then raise exception 'INVALID_DURATION'; end if;
  select price_override into price
  from post_game_prices
  where post_id = s.post_id and game_id = g.id;
  g.price := coalesce(price, g.price);
  amt := app._time_amount(g, p_minutes, p_first);
  if amt is null then raise exception 'PRICING_NOT_TIME_COMPATIBLE'; end if;
  insert into session_events(venue_id, session_id, type, minutes, unit_price, amount, added_seconds, game_id, meta, created_by)
  values (s.venue_id, s.id, 'time_added', 1, g.price, amt, p_minutes * 60, g.id,
          jsonb_build_object('minutes', p_minutes, 'pricing_unit', g.pricing_unit, 'request_id', p_request), auth.uid());
  update sessions set planned_duration_seconds = planned_duration_seconds + p_minutes * 60,
                      version = version + 1, updated_at = now() where id = s.id;
  perform app.audit(s.venue_id, 'time_added', 'session', s.id::text, jsonb_build_object('minutes', p_minutes, 'amount', amt));
end;
$$;

create or replace function public.save_post_configuration(
  p_op uuid,
  p_venue uuid,
  p_post uuid,
  p_number integer,
  p_name text,
  p_device device_type,
  p_max_players integer,
  p_zone text,
  p_game_ids uuid[],
  p_price_overrides jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post uuid;
  v_result jsonb;
  v_game_count integer;
  v_override record;
  v_override_game uuid;
  v_override_price numeric;
begin
  if auth.uid() is null or not app.is_admin(p_venue) then
    raise exception 'FORBIDDEN';
  end if;
  if p_name is null
     or length(trim(p_name)) = 0
     or p_device is null
     or p_max_players is null
     or p_max_players <= 0 then
    raise exception 'INVALID_POST_CONFIGURATION';
  end if;
  if p_post is null and (p_number is null or p_number <= 0) then
    raise exception 'INVALID_POST_NUMBER';
  end if;
  if p_price_overrides is not null
     and jsonb_typeof(p_price_overrides) <> 'object' then
    raise exception 'INVALID_PRICE_OVERRIDES';
  end if;

  v_result := app.begin_op(
    p_op,
    p_venue,
    'save_post_configuration',
    jsonb_build_object(
      'post', p_post,
      'number', p_number,
      'name', trim(p_name),
      'device', p_device,
      'max_players', p_max_players,
      'zone', nullif(trim(p_zone), ''),
      'game_ids', coalesce(p_game_ids, array[]::uuid[]),
      'price_overrides', coalesce(p_price_overrides, '{}'::jsonb)
    )
  );
  if v_result is not null then
    return v_result;
  end if;

  if p_post is null then
    insert into posts (venue_id, number, name, device, max_players, zone)
    values (
      p_venue,
      p_number,
      trim(p_name),
      p_device,
      p_max_players,
      nullif(trim(p_zone), '')
    )
    returning id into v_post;
  else
    update posts
    set name = trim(p_name),
        device = p_device,
        max_players = p_max_players,
        zone = nullif(trim(p_zone), '')
    where id = p_post
      and venue_id = p_venue
    returning id into v_post;
    if v_post is null then
      raise exception 'POST_NOT_FOUND';
    end if;
  end if;

  select count(distinct game_id)
  into v_game_count
  from unnest(coalesce(p_game_ids, array[]::uuid[])) as selected(game_id)
  where game_id is not null;

  if exists (
    select 1
    from unnest(coalesce(p_game_ids, array[]::uuid[])) as selected(game_id)
    left join games g
      on g.id = selected.game_id
     and g.venue_id = p_venue
    where selected.game_id is not null
      and g.id is null
  ) then
    raise exception 'GAME_NOT_IN_VENUE';
  end if;

  if v_game_count > 0 then
    if exists (
      select 1
      from sessions s
      where s.post_id = v_post
        and s.status in ('starting', 'active', 'paused', 'waiting_payment')
        and not (s.game_id = any(coalesce(p_game_ids, array[]::uuid[])))
    ) then
      raise exception 'POST_HAS_ACTIVE_UNSUPPORTED_GAME';
    end if;
  end if;

  for v_override in
    select key, value
    from jsonb_each(coalesce(p_price_overrides, '{}'::jsonb))
  loop
    begin
      v_override_game := v_override.key::uuid;
      if jsonb_typeof(v_override.value) <> 'number' then
        raise exception 'INVALID_PRICE_OVERRIDE';
      end if;
      v_override_price := v_override.value::text::numeric;
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        raise exception 'INVALID_PRICE_OVERRIDE';
    end;

    if v_override_price < 0 or v_override_price > 9999999999.99 then
      raise exception 'INVALID_PRICE_OVERRIDE';
    end if;
    if v_override_price <> round(v_override_price, 2) then
      raise exception 'INVALID_PRICE_OVERRIDE';
    end if;
    if not exists (
      select 1 from games g
      where g.id = v_override_game and g.venue_id = p_venue
    ) then
      raise exception 'GAME_NOT_IN_VENUE';
    end if;
    if v_game_count > 0
       and not (v_override_game = any(coalesce(p_game_ids, array[]::uuid[]))) then
      raise exception 'PRICE_OVERRIDE_FOR_UNSUPPORTED_GAME';
    end if;
  end loop;

  delete from post_games where post_id = v_post;
  delete from post_game_prices where post_id = v_post;
  if v_game_count > 0 then
    insert into post_games (post_id, game_id)
    select v_post, selected.game_id
    from unnest(coalesce(p_game_ids, array[]::uuid[])) as selected(game_id)
    where selected.game_id is not null
    on conflict do nothing;
  end if;

  for v_override in
    select key, value
    from jsonb_each(coalesce(p_price_overrides, '{}'::jsonb))
  loop
    insert into post_game_prices (post_id, game_id, price_override)
    values (v_post, v_override.key::uuid, v_override.value::text::numeric);
  end loop;

  select to_jsonb(p) into v_result
  from posts p
  where p.id = v_post;

  perform app.audit(
    p_venue,
    'post_configuration_changed',
    'post',
    v_post::text,
    jsonb_build_object(
      'game_ids', coalesce(p_game_ids, array[]::uuid[]),
      'price_overrides', coalesce(p_price_overrides, '{}'::jsonb)
    )
  );

  return app.end_op(p_op, v_result);
end;
$$;

create or replace function app.validate_session_post_game()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post_venue uuid;
  v_game_venue uuid;
begin
  select venue_id into v_post_venue from posts where id = new.post_id;
  select venue_id into v_game_venue from games where id = new.game_id;
  if v_post_venue is null or v_post_venue is distinct from v_game_venue then
    raise exception 'POST_GAME_VENUE_MISMATCH';
  end if;
  if exists (select 1 from post_games where post_id = new.post_id)
     and not exists (
       select 1 from post_games
       where post_id = new.post_id and game_id = new.game_id
     ) then
    raise exception 'POST_GAME_NOT_SUPPORTED';
  end if;
  return new;
end;
$$;

create trigger sessions_validate_post_game
before insert or update of post_id, game_id on sessions
for each row execute function app.validate_session_post_game();

revoke all on function public.save_post_configuration(
  uuid, uuid, uuid, integer, text, device_type, integer, text, uuid[], jsonb
) from public;
grant execute on function public.save_post_configuration(
  uuid, uuid, uuid, integer, text, device_type, integer, text, uuid[], jsonb
) to authenticated;
