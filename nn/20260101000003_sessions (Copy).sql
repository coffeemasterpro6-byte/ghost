-- =====================================================================
-- 003 SESSIONS ENGINE — sessions, charges timeline, requests, notifications, atomic RPCs
-- Rules:
--  * Timers are NEVER stored as "remaining". Truth = started_at, paused_at, ended_at, total_paused_seconds, planned_duration_seconds.
--  * Money/time are computed here, in one transaction, with row locks. The client only calls RPCs.
--  * Every mutating RPC takes p_op (client-generated UUID) => retries are idempotent.
--  * Errors are machine codes (e.g. SESSION_NOT_ACTIVE). Flutter maps them to French messages.
-- =====================================================================
create type session_status as enum ('starting','active','paused','waiting_payment','closed','cancelled');
create type session_event_type as enum ('started','match_added','time_added','paused','resumed','transferred',
                                        'product_added','discount','ended','cancelled','payment','note');
create type request_type   as enum ('start_session','match','time','product','checkout');
create type request_status as enum ('pending','approved','rejected','cancelled','completed');

create table sessions (
  id                       uuid primary key default gen_random_uuid(),
  venue_id                 uuid not null references venues(id) on delete cascade,
  number                   bigint generated always as identity,          -- "Session #501"
  customer_id              uuid references customers(id),
  post_id                  uuid not null references posts(id),
  game_id                  uuid not null references games(id),
  created_by               uuid references auth.users(id),
  status                   session_status not null default 'starting',
  started_at               timestamptz,
  paused_at                timestamptz,
  ended_at                 timestamptz,
  total_paused_seconds     int not null default 0 check (total_paused_seconds >= 0),
  planned_duration_seconds int not null default 0 check (planned_duration_seconds >= 0),
  match_count              int not null default 0 check (match_count >= 0),
  version                  int not null default 1,                       -- optimistic concurrency token for the UI
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create unique index one_open_session_per_post on sessions(post_id)
  where status in ('starting','active','paused','waiting_payment');
create index sessions_venue_status_idx on sessions(venue_id, status);
create index sessions_customer_idx on sessions(customer_id);

-- append-only timeline = single source of every gaming charge (price SNAPSHOT at the moment of the event)
create table session_events (
  id             bigint generated always as identity primary key,
  venue_id       uuid not null,
  session_id     uuid not null references sessions(id),
  type           session_event_type not null,
  qty            int not null default 1,
  minutes        int,
  unit_price     numeric(12,2),
  amount         numeric(12,2) not null default 0,       -- negative for discounts
  added_seconds  int not null default 0,                 -- contribution to planned_duration_seconds
  game_id        uuid,
  meta           jsonb not null default '{}'::jsonb,
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create index session_events_session_idx on session_events(session_id, created_at);

create view session_matches with (security_invoker = true) as
  select id, venue_id, session_id, (meta->>'match_from')::int as match_from, (meta->>'match_to')::int as match_to,
         qty, unit_price, amount, added_seconds, created_by, created_at
  from session_events where type = 'match_added';

create view session_bill with (security_invoker = true) as
  select s.id as session_id, s.venue_id,
         coalesce((select sum(e.amount) from session_events e
                   where e.session_id = s.id and e.type in ('match_added','time_added','discount')), 0) as gaming_total
  from sessions s;      -- later migrations add: products_total, payments_total, balance_due

create table session_requests (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references venues(id) on delete cascade,
  session_id  uuid not null references sessions(id),
  post_id     uuid not null references posts(id),
  customer_id uuid references customers(id),
  type        request_type not null,
  payload     jsonb not null default '{}'::jsonb,         -- {"qty":1} | {"minutes":30}
  status      request_status not null default 'pending',
  created_by  uuid,
  handled_by  uuid,
  handled_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index session_requests_venue_idx on session_requests(venue_id, status);
create unique index one_pending_request_per_type on session_requests(session_id, type) where status = 'pending';

create table notifications (
  id             uuid primary key default gen_random_uuid(),
  venue_id       uuid not null references venues(id) on delete cascade,
  recipient_id   uuid not null references auth.users(id) on delete cascade,
  type           text not null,                  -- request_created | request_decided | ...
  title          text not null,                  -- French, ready to display / push
  body           text,
  reference_type text,                           -- 'session_request' | 'session' | 'order' ...  (deep link target)
  reference_id   uuid,
  data           jsonb not null default '{}'::jsonb,   -- {"post_id":..., "session_id":...}
  is_read        boolean not null default false,
  created_at     timestamptz not null default now()
);
create index notifications_recipient_idx on notifications(recipient_id, is_read, created_at desc);

-- =====================================================================
-- INTERNAL HELPERS (schema app — not exposed)
-- =====================================================================
create or replace function app.elapsed_seconds(s sessions) returns int language sql stable as $$
  select case when s.started_at is null then 0
              else greatest(0, (floor(extract(epoch from (
                     case when s.status = 'paused' and s.paused_at is not null then s.paused_at
                          when s.ended_at is not null then s.ended_at
                          else now() end) - s.started_at)) - s.total_paused_seconds)::int) end
$$;

create or replace function app._session_json(p_id uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(s) || jsonb_build_object(
           'gaming_total', coalesce((select sum(e.amount) from session_events e
                                     where e.session_id = s.id and e.type in ('match_added','time_added','discount')), 0),
           'elapsed_seconds', app.elapsed_seconds(s),
           'remaining_seconds', s.planned_duration_seconds - app.elapsed_seconds(s))
  from sessions s where s.id = p_id
$$;

-- post.status is derived from the open session. Only this function (and admin for maintenance/offline/reserved) writes it.
create or replace function app._sync_post(p_post uuid) returns void language plpgsql security definer set search_path = public as $$
declare s sessions;
begin
  perform set_config('app.in_rpc', 'on', true);
  select * into s from sessions where post_id = p_post and status in ('starting','active','paused','waiting_payment') limit 1;
  update posts set status = case
      when s.id is null                    then 'available'::post_status
      when s.status = 'starting'           then 'starting'
      when s.status = 'active'             then 'playing'
      when s.status = 'paused'             then 'paused'
      when s.status = 'waiting_payment'    then 'waiting_payment' end
  where id = p_post;
  perform set_config('app.in_rpc', 'off', true);
end $$;

create or replace function app.posts_guard() returns trigger language plpgsql as $$
begin
  if new.status is distinct from old.status
     and coalesce(current_setting('app.in_rpc', true), '') <> 'on'
     and (old.status in ('starting','playing','paused','waiting_payment')
          or new.status in ('starting','playing','paused','waiting_payment')) then
    raise exception 'POST_STATUS_MANAGED_BY_SESSION';
  end if;
  return new;
end $$;
create trigger posts_guard before update on posts for each row execute function app.posts_guard();

create or replace function app._lock_session(p_id uuid) returns sessions language plpgsql security definer set search_path = public as $$
declare s sessions;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from sessions where id = p_id for update;
  if s.id is null then raise exception 'SESSION_NOT_FOUND'; end if;
  return s;
end $$;

-- price of N added minutes: whole units ROUNDED UP for 15/30/60 (assumption D4 in MASTER_BRIEF), exact for per_minute
create or replace function app._time_amount(g games, p_minutes int, p_first boolean default false) returns numeric
language plpgsql immutable as $$
begin
  return round(case g.pricing_unit
    when 'per_minute'     then g.price * p_minutes
    when 'per_15_minutes' then g.price * ceil(p_minutes / 15.0)
    when 'per_30_minutes' then g.price * ceil(p_minutes / 30.0)
    when 'per_hour'       then g.price * ceil(p_minutes / 60.0)
    when 'fixed_price'    then case when p_first then g.price else 0 end
    else null end, 2);
end $$;

create or replace function app._add_match(p_session uuid, p_qty int, p_request uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare s sessions; g games; add_s int;
begin
  select * into s from sessions where id = p_session;
  select * into g from games where id = s.game_id;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if g.game_mode <> 'match_based' then raise exception 'GAME_NOT_MATCH_BASED'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 10 then raise exception 'INVALID_QUANTITY'; end if;
  add_s := p_qty * g.effective_match_seconds;
  insert into session_events(venue_id, session_id, type, qty, unit_price, amount, added_seconds, game_id, meta, created_by)
  values (s.venue_id, s.id, 'match_added', p_qty, g.price, p_qty * g.price, add_s, g.id,
          jsonb_build_object('match_from', s.match_count + 1, 'match_to', s.match_count + p_qty, 'request_id', p_request), auth.uid());
  update sessions set match_count = match_count + p_qty,
                      planned_duration_seconds = planned_duration_seconds + add_s,
                      version = version + 1, updated_at = now() where id = s.id;
  perform app.audit(s.venue_id, 'match_added', 'session', s.id::text,
                    jsonb_build_object('qty', p_qty, 'unit_price', g.price, 'added_seconds', add_s));
end $$;

create or replace function app._add_time(p_session uuid, p_minutes int, p_request uuid default null, p_first boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare s sessions; g games; amt numeric;
begin
  select * into s from sessions where id = p_session;
  select * into g from games where id = s.game_id;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if g.game_mode = 'match_based' then raise exception 'GAME_NOT_TIME_BASED'; end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 600 then raise exception 'INVALID_DURATION'; end if;
  amt := app._time_amount(g, p_minutes, p_first);
  if amt is null then raise exception 'PRICING_NOT_TIME_COMPATIBLE'; end if;
  insert into session_events(venue_id, session_id, type, minutes, unit_price, amount, added_seconds, game_id, meta, created_by)
  values (s.venue_id, s.id, 'time_added', 1, g.price, amt, p_minutes * 60, g.id,
          jsonb_build_object('minutes', p_minutes, 'pricing_unit', g.pricing_unit, 'request_id', p_request), auth.uid());
  update sessions set planned_duration_seconds = planned_duration_seconds + p_minutes * 60,
                      version = version + 1, updated_at = now() where id = s.id;
  perform app.audit(s.venue_id, 'time_added', 'session', s.id::text, jsonb_build_object('minutes', p_minutes, 'amount', amt));
end $$;

create or replace function app._end(p_session uuid) returns void language plpgsql security definer set search_path = public as $$
declare s sessions;
begin
  select * into s from sessions where id = p_session;
  update sessions set status = 'waiting_payment', ended_at = now(),
         total_paused_seconds = total_paused_seconds + case when status = 'paused' then floor(extract(epoch from now() - paused_at))::int else 0 end,
         paused_at = null, version = version + 1, updated_at = now()
  where id = p_session;
  update session_requests set status = 'cancelled', handled_at = now() where session_id = p_session and status = 'pending';
  insert into session_events(venue_id, session_id, type, created_by) values (s.venue_id, s.id, 'ended', auth.uid());
  perform app._sync_post(s.post_id);
  perform app.audit(s.venue_id, 'session_end', 'session', s.id::text, '{}');
end $$;

-- =====================================================================
-- PUBLIC RPCs (called by Flutter)
-- =====================================================================
create or replace function public.start_session(p_op uuid, p_post uuid, p_game uuid, p_customer uuid default null, p_initial_minutes int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare po posts; g games; s sessions; r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into po from posts where id = p_post for update;
  if po.id is null then raise exception 'POST_NOT_FOUND'; end if;
  if not app.is_staff(po.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, po.venue_id, 'start_session'); if r is not null then return r; end if;
  if po.status not in ('available','reserved') then raise exception 'POST_NOT_AVAILABLE'; end if;
  select * into g from games where id = p_game and venue_id = po.venue_id;
  if g.id is null or not g.is_available then raise exception 'GAME_NOT_AVAILABLE'; end if;
  if exists (select 1 from post_games where post_id = p_post)
     and not exists (select 1 from post_games where post_id = p_post and game_id = p_game) then
    raise exception 'GAME_NOT_SUPPORTED_ON_POST'; end if;
  if p_customer is not null and not exists (select 1 from customers where id = p_customer and venue_id = po.venue_id) then
    raise exception 'CUSTOMER_NOT_FOUND'; end if;

  insert into sessions(venue_id, customer_id, post_id, game_id, created_by, status, started_at)
  values (po.venue_id, p_customer, p_post, p_game, auth.uid(), 'active', now()) returning * into s;
  insert into session_events(venue_id, session_id, type, game_id, created_by) values (s.venue_id, s.id, 'started', g.id, auth.uid());

  if g.game_mode = 'match_based' then
    perform app._add_match(s.id, 1);
  elsif g.game_mode = 'time_based' then
    if coalesce(p_initial_minutes, 0) <= 0 then raise exception 'INITIAL_DURATION_REQUIRED'; end if;
    perform app._add_time(s.id, p_initial_minutes, null, true);
  end if;
  perform app._sync_post(po.id);
  perform app.audit(s.venue_id, 'session_start', 'session', s.id::text, jsonb_build_object('post', po.name, 'game', g.name));
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.add_match(p_op uuid, p_session uuid, p_qty int default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'add_match'); if r is not null then return r; end if;
  perform app._add_match(s.id, p_qty);
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.add_time(p_op uuid, p_session uuid, p_minutes int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'add_time'); if r is not null then return r; end if;
  perform app._add_time(s.id, p_minutes);
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.pause_session(p_op uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'pause_session'); if r is not null then return r; end if;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  update sessions set status = 'paused', paused_at = now(), version = version + 1, updated_at = now() where id = s.id;
  insert into session_events(venue_id, session_id, type, created_by) values (s.venue_id, s.id, 'paused', auth.uid());
  perform app._sync_post(s.post_id);
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.resume_session(p_op uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'resume_session'); if r is not null then return r; end if;
  if s.status <> 'paused' then raise exception 'SESSION_NOT_PAUSED'; end if;
  update sessions set status = 'active', total_paused_seconds = total_paused_seconds + floor(extract(epoch from now() - paused_at))::int,
                      paused_at = null, version = version + 1, updated_at = now() where id = s.id;
  insert into session_events(venue_id, session_id, type, created_by) values (s.venue_id, s.id, 'resumed', auth.uid());
  perform app._sync_post(s.post_id);
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.end_session(p_op uuid, p_session uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'end_session'); if r is not null then return r; end if;
  if s.status not in ('active','paused') then raise exception 'SESSION_NOT_ACTIVE'; end if;
  perform app._end(s.id);
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.cancel_session(p_op uuid, p_session uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.has_perm(s.venue_id, 'cancel_session') then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'cancel_session'); if r is not null then return r; end if;
  if s.status in ('closed','cancelled') then raise exception 'SESSION_ALREADY_FINISHED'; end if;
  update sessions set status = 'cancelled', ended_at = now(), paused_at = null, version = version + 1, updated_at = now() where id = s.id;
  update session_requests set status = 'cancelled', handled_at = now() where session_id = s.id and status = 'pending';
  insert into session_events(venue_id, session_id, type, meta, created_by) values (s.venue_id, s.id, 'cancelled', jsonb_build_object('reason', p_reason), auth.uid());
  perform app._sync_post(s.post_id);
  perform app.audit(s.venue_id, 'session_cancel', 'session', s.id::text, jsonb_build_object('reason', p_reason));
  return app.end_op(p_op, app._session_json(s.id));
end $$;

create or replace function public.transfer_session(p_op uuid, p_session uuid, p_new_post uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sessions; np posts; old_post uuid; r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.is_staff(s.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'transfer_session'); if r is not null then return r; end if;
  if s.status not in ('active','paused') then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if p_new_post = s.post_id then raise exception 'SAME_POST'; end if;
  perform 1 from posts where id in (s.post_id, p_new_post) order by id for update;   -- fixed lock order => no deadlocks
  select * into np from posts where id = p_new_post and venue_id = s.venue_id;
  if np.id is null then raise exception 'POST_NOT_FOUND'; end if;
  if np.status not in ('available','reserved') then raise exception 'POST_NOT_AVAILABLE'; end if;
  old_post := s.post_id;
  update sessions set post_id = p_new_post, version = version + 1, updated_at = now() where id = s.id;
  insert into session_events(venue_id, session_id, type, meta, created_by)
    values (s.venue_id, s.id, 'transferred', jsonb_build_object('from', old_post, 'to', p_new_post), auth.uid());
  perform app._sync_post(old_post);
  perform app._sync_post(p_new_post);
  perform app.audit(s.venue_id, 'session_transfer', 'session', s.id::text, jsonb_build_object('from', old_post, 'to', p_new_post));
  return app.end_op(p_op, app._session_json(s.id));
end $$;

-- Customer (owner of the session) or staff creates a request. Product orders use the Orders module (phase 5).
create or replace function public.create_request(p_op uuid, p_session uuid, p_type request_type, p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare s sessions; g games; po posts; c customers; req session_requests; r jsonb; qty int; mins int; label text;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into s from sessions where id = p_session;
  if s.id is null then raise exception 'SESSION_NOT_FOUND'; end if;
  if not (app.is_staff(s.venue_id)
          or exists (select 1 from customers cc where cc.id = s.customer_id and cc.user_id = auth.uid())) then
    raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(p_op, s.venue_id, 'create_request'); if r is not null then return r; end if;
  if p_type not in ('match','time','checkout') then raise exception 'REQUEST_TYPE_NOT_SUPPORTED'; end if;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  select * into g from games where id = s.game_id;
  select * into po from posts where id = s.post_id;
  select * into c from customers where id = s.customer_id;
  if p_type = 'match' then
    qty := coalesce((p_payload ->> 'qty')::int, 1);
    if g.game_mode <> 'match_based' then raise exception 'GAME_NOT_MATCH_BASED'; end if;
    if qty < 1 or qty > 10 then raise exception 'INVALID_QUANTITY'; end if;
    label := ' demande +' || qty || ' match';
    p_payload := jsonb_build_object('qty', qty);
  elsif p_type = 'time' then
    mins := (p_payload ->> 'minutes')::int;
    if g.game_mode = 'match_based' then raise exception 'GAME_NOT_TIME_BASED'; end if;
    if mins is null or mins < 5 or mins > 240 then raise exception 'INVALID_DURATION'; end if;
    label := ' demande +' || mins || ' min';
    p_payload := jsonb_build_object('minutes', mins);
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
  return app.end_op(p_op, to_jsonb(req));
end $$;

create or replace function public.decide_request(p_op uuid, p_request uuid, p_approve boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare req session_requests; s sessions; po posts; cust_user uuid; r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into req from session_requests where id = p_request;
  if req.id is null then raise exception 'REQUEST_NOT_FOUND'; end if;
  if not app.is_staff(req.venue_id) then raise exception 'FORBIDDEN'; end if;
  s := app._lock_session(req.session_id);                                      -- lock order: session first, then request
  select * into req from session_requests where id = p_request for update;
  r := app.begin_op(p_op, req.venue_id, 'decide_request'); if r is not null then return r; end if;
  if req.status <> 'pending' then raise exception 'REQUEST_NOT_PENDING'; end if;
  if p_approve then
    if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
    if req.type = 'match' then perform app._add_match(s.id, (req.payload ->> 'qty')::int, req.id);
    elsif req.type = 'time' then perform app._add_time(s.id, (req.payload ->> 'minutes')::int, req.id);
    elsif req.type = 'checkout' then perform app._end(s.id);
    else raise exception 'REQUEST_TYPE_NOT_SUPPORTED'; end if;
  end if;
  update session_requests set status = case when p_approve then 'completed'::request_status else 'rejected' end,
                              handled_by = auth.uid(), handled_at = now()
   where id = req.id returning * into req;
  select * into po from posts where id = req.post_id;
  select user_id into cust_user from customers where id = req.customer_id;
  if cust_user is not null then
    insert into notifications(venue_id, recipient_id, type, title, body, reference_type, reference_id, data)
    values (req.venue_id, cust_user, 'request_decided',
            case when p_approve then 'Demande acceptée' else 'Demande refusée' end,
            po.name || case req.type when 'match' then ' : match' when 'time' then ' : temps' else ' : clôture' end,
            'session', s.id, jsonb_build_object('post_id', po.id, 'request_id', req.id));
  end if;
  perform app.audit(req.venue_id, 'request_' || req.status, 'session_request', req.id::text, to_jsonb(req));
  return app.end_op(p_op, jsonb_build_object('request', to_jsonb(req), 'session', app._session_json(s.id)));
end $$;

-- =====================================================================
-- REALTIME broadcast triggers (private channels)
-- =====================================================================
create or replace function app.broadcast_child() returns trigger language plpgsql security definer set search_path = public as $$
declare
  sid uuid;
  col text := tg_argv[0];
  rec jsonb;
begin
  rec := coalesce(to_jsonb(new), to_jsonb(old));
  if col = 'session_id' and rec ? 'session_id' then
    sid := (rec ->> 'session_id')::uuid;
  else
    sid := (rec ->> 'id')::uuid;
  end if;
  perform realtime.broadcast_changes('session:' || sid, tg_op, tg_op, tg_table_name, tg_table_schema, new, old);
  return coalesce(new, old);
end $$;
create or replace function app.broadcast_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform realtime.broadcast_changes('user:' || coalesce(new.recipient_id, old.recipient_id), tg_op, tg_op, tg_table_name, tg_table_schema, new, old);
  return coalesce(new, old);
end $$;

create trigger sessions_rt1  after insert or update on sessions         for each row execute function app.broadcast_row('sessions');
create trigger sessions_rt2  after insert or update on sessions         for each row execute function app.broadcast_child('id');
create trigger events_rt1    after insert on session_events             for each row execute function app.broadcast_row('sessions');
create trigger events_rt2    after insert on session_events             for each row execute function app.broadcast_child('session_id');
create trigger requests_rt1  after insert or update on session_requests for each row execute function app.broadcast_row('requests');
create trigger requests_rt2  after insert or update on session_requests for each row execute function app.broadcast_child('session_id');
create trigger notif_rt      after insert on notifications              for each row execute function app.broadcast_user();

-- who may subscribe to which private topic
create or replace function app.can_listen(p_topic text) returns boolean language plpgsql stable security definer set search_path = public as $$
declare parts text[] := string_to_array(p_topic, ':');
begin
  if parts[1] = 'venue' and array_length(parts, 1) = 3 then
    return case when parts[3] = 'catalog' then app.is_member(parts[2]::uuid) else app.is_staff(parts[2]::uuid) end;
  elsif parts[1] = 'session' then
    return exists (select 1 from sessions s where s.id = parts[2]::uuid
                   and (app.is_staff(s.venue_id) or exists (select 1 from customers c where c.id = s.customer_id and c.user_id = auth.uid())));
  elsif parts[1] = 'user' then
    return parts[2]::uuid = auth.uid();
  end if;
  return false;
exception when others then return false;
end $$;

do $$ begin
  if to_regclass('realtime.messages') is not null then
    execute $p$create policy "ghost_private_channels_read" on realtime.messages for select to authenticated
               using (extension in ('broadcast','presence') and app.can_listen(realtime.topic()))$p$;
  end if;
end $$;

-- =====================================================================
-- RLS — clients can READ; every WRITE goes through the RPCs above
-- =====================================================================
alter table sessions         enable row level security;
alter table session_events   enable row level security;
alter table session_requests enable row level security;
alter table notifications    enable row level security;

create policy sessions_staff_read on sessions for select using (app.is_staff(venue_id));
create policy sessions_own_read   on sessions for select using (exists (select 1 from customers c where c.id = customer_id and c.user_id = auth.uid()));
create policy events_staff_read   on session_events for select using (app.is_staff(venue_id));
create policy events_own_read     on session_events for select using (exists (
  select 1 from sessions s join customers c on c.id = s.customer_id where s.id = session_id and c.user_id = auth.uid()));
create policy requests_staff_read on session_requests for select using (app.is_staff(venue_id));
create policy requests_own_read   on session_requests for select using (exists (select 1 from customers c where c.id = customer_id and c.user_id = auth.uid()));
create policy notif_own_read      on notifications for select using (recipient_id = auth.uid());
create policy notif_own_update    on notifications for update using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

grant select on sessions, session_events, session_requests, session_matches, session_bill, notifications to authenticated;
grant update (is_read) on notifications to authenticated;

-- ---------- function privileges ----------
revoke all on all functions in schema app from public, anon, authenticated;
grant usage on schema app to authenticated;
grant execute on function app.role_in(uuid), app.is_member(uuid), app.is_staff(uuid), app.is_admin(uuid),
                          app.has_perm(uuid, text), app.can_listen(text), app.elapsed_seconds(sessions) to authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('start_session','add_match','add_time','pause_session','resume_session',
                 'end_session','cancel_session','transfer_session','create_request','decide_request') loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
