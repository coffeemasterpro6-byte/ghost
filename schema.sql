-- =====================================================================
-- Gaming Lounge OS — Supabase / Postgres schema (v1)
-- Money: numeric(12,2), currency DA. All tables carry lounge_id (multi-tenant ready).
-- Rule: the app NEVER writes session/stock/ledger tables directly; it calls RPC functions.
-- =====================================================================
create extension if not exists "pgcrypto";
create extension if not exists btree_gist;   -- needed for booking overlap constraint
create schema if not exists app;

-- ---------- ENUMS ----------
create type user_role        as enum ('owner','manager','employee','customer');
create type post_status      as enum ('available','playing','reserved','waiting_payment','disabled');
create type device_type      as enum ('ps4','ps5','xbox','pc','vr','pool','billiard','racing','other');
create type pricing_mode     as enum ('per_match','per_time');
create type session_status   as enum ('active','paused','waiting_payment','closed','cancelled');
create type event_type       as enum ('started','match_added','time_added','paused','resumed',
                                      'transferred','product_added','discount','ended','payment','cancelled','note');
create type request_type     as enum ('match','time','product','checkout');
create type request_status   as enum ('pending','accepted','rejected','cancelled');
create type order_status     as enum ('pending','confirmed','preparing','ready','served','paid',
                                      'added_to_session','completed','cancelled');
create type pay_method       as enum ('cash','card','wallet','credit');
create type ledger_account   as enum ('wallet','credit');
create type booking_status   as enum ('pending','confirmed','rejected','cancelled','no_show','completed');
create type shift_status     as enum ('open','closed');

-- ---------- TENANT / USERS ----------
create table lounges (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_id uuid not null,                       -- auth.users.id
  currency text not null default 'DA',
  settings jsonb not null default '{}'::jsonb,  -- e.g. {"customer_can_start_session":false,"time_mode":"prepaid"}
  created_at timestamptz not null default now()
);

create table profiles (
  id uuid primary key,                          -- = auth.users.id
  lounge_id uuid references lounges(id),
  role user_role not null default 'customer',
  full_name text,
  phone text,
  avatar_url text,
  is_active boolean not null default true,
  fcm_token text,
  created_at timestamptz not null default now()
);

-- fine-grained permissions for manager/employee (owner decides)
create table staff_permissions (
  profile_id uuid primary key references profiles(id) on delete cascade,
  lounge_id uuid not null references lounges(id),
  can_give_discount boolean not null default false,
  can_cancel_session boolean not null default false,
  can_refund boolean not null default false,
  can_edit_prices boolean not null default false,
  can_manage_stock boolean not null default false,
  can_see_reports boolean not null default false,
  can_manage_credit boolean not null default false,
  max_discount_percent numeric(5,2) not null default 0
);

create table customers (                         -- a customer may exist without an app account (walk-in)
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null references lounges(id),
  profile_id uuid references profiles(id),
  full_name text not null,
  phone text,
  photo_url text,
  membership_tier text,                          -- phase 2
  loyalty_points integer not null default 0,     -- phase 2 (cached; truth = ledger)
  created_at timestamptz not null default now(),
  unique (lounge_id, phone)
);

-- ---------- POSTS / GAMES ----------
create table posts (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null references lounges(id),
  number int not null,
  name text not null,
  device device_type not null default 'ps5',
  zone text,
  image_url text,
  screen_info text,                              -- e.g. 'PS5 · 55" Screen'
  max_players int not null default 2,
  status post_status not null default 'available',
  settings jsonb not null default '{}'::jsonb,
  qr_token text not null default encode(gen_random_bytes(12),'hex') unique,
  created_at timestamptz not null default now(),
  unique (lounge_id, number)
);

create table games (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null references lounges(id),
  name text not null,
  subtitle text,                                 -- 'Modern Warfare III'
  platform device_type not null default 'ps5',
  image_url text,
  description text,
  category text,
  pricing pricing_mode not null default 'per_match',
  price numeric(12,2) not null,                  -- per match OR per time_unit
  time_unit_minutes int,                         -- required when per_time
  is_available boolean not null default true,
  is_trending boolean not null default false,
  created_at timestamptz not null default now(),
  check (pricing='per_match' or time_unit_minutes is not null)
);

create table post_games (
  post_id uuid references posts(id) on delete cascade,
  game_id uuid references games(id) on delete cascade,
  primary key (post_id, game_id)
);

-- ---------- PRODUCTS / STOCK ----------
create table product_categories (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null references lounges(id),
  name text not null, sort int not null default 0
);

create table products (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null references lounges(id),
  category_id uuid references product_categories(id),
  name text not null,
  image_url text,
  price numeric(12,2) not null,
  cost numeric(12,2) not null default 0,         -- for profit reports
  stock int not null default 0,
  min_stock int not null default 10,
  track_stock boolean not null default true,
  is_available boolean not null default true,
  created_at timestamptz not null default now()
);

create table stock_movements (                   -- append-only
  id bigint generated always as identity primary key,
  lounge_id uuid not null,
  product_id uuid not null references products(id),
  delta int not null,                            -- negative = sale
  reason text not null,                          -- sale | restock | adjustment | cancel_restore
  order_item_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);

-- ---------- SESSIONS (heart of the system) ----------
create table sessions (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null references lounges(id),
  number bigint generated always as identity,    -- Session #501
  customer_id uuid references customers(id),
  post_id uuid not null references posts(id),
  game_id uuid references games(id),
  employee_id uuid references profiles(id),
  status session_status not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  paused_at timestamptz,
  paused_total_seconds int not null default 0,
  paid_minutes int not null default 0,           -- cached sum of time_added (truth = events)
  version int not null default 1,                -- optimistic concurrency
  updated_at timestamptz not null default now()
);
-- only ONE open session per post:
create unique index one_open_session_per_post on sessions(post_id)
  where status in ('active','paused','waiting_payment');

create table session_events (                    -- append-only timeline = source of the bill
  id bigint generated always as identity primary key,
  lounge_id uuid not null,
  session_id uuid not null references sessions(id),
  type event_type not null,
  qty int not null default 1,
  minutes int,
  unit_price numeric(12,2),                      -- SNAPSHOT of price at that moment
  amount numeric(12,2) not null default 0,       -- qty * unit_price (negative for discounts)
  game_id uuid, product_id uuid, order_id uuid,
  meta jsonb not null default '{}'::jsonb,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index on session_events(session_id, created_at);

-- ---------- CUSTOMER REQUESTS ----------
create table requests (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null,
  session_id uuid references sessions(id),
  post_id uuid references posts(id),
  customer_id uuid references customers(id),
  type request_type not null,
  payload jsonb not null default '{}'::jsonb,    -- {"qty":1} / {"minutes":30} / {"items":[...]}
  status request_status not null default 'pending',
  handled_by uuid, handled_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- ORDERS / POS ----------
create table orders (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null,
  number bigint generated always as identity,    -- POS Order #1005
  customer_id uuid references customers(id),
  session_id uuid references sessions(id),       -- null = standalone order
  post_id uuid references posts(id),
  status order_status not null default 'pending',
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid not null references products(id),
  qty int not null check (qty>0),
  unit_price numeric(12,2) not null,             -- snapshot
  unit_cost numeric(12,2) not null default 0     -- snapshot
);

-- ---------- PAYMENTS / LEDGER ----------
create table payments (                          -- one row per method used (split payment = N rows)
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null,
  session_id uuid references sessions(id),
  order_id uuid references orders(id),
  shift_id uuid,
  customer_id uuid references customers(id),
  method pay_method not null,
  amount numeric(12,2) not null check (amount>0),
  created_by uuid,
  created_at timestamptz not null default now(),
  check (session_id is not null or order_id is not null)
);

create table ledger_entries (                    -- append-only. wallet = prepaid money, credit = money owed BY customer
  id bigint generated always as identity primary key,
  lounge_id uuid not null,
  customer_id uuid not null references customers(id),
  account ledger_account not null,
  delta numeric(12,2) not null,                  -- wallet: +topup/-spend ; credit: +debt/-repayment
  reason text not null,                          -- topup | spend | debt_created | repayment | refund | adjustment
  session_id uuid, order_id uuid, payment_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
create view customer_balances as
  select customer_id,
         coalesce(sum(delta) filter (where account='wallet'),0) as wallet,
         coalesce(sum(delta) filter (where account='credit'),0) as credit
  from ledger_entries group by customer_id;

-- ---------- BOOKINGS / WAITLIST / NOTIFICATIONS ----------
create table bookings (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null, customer_id uuid not null references customers(id),
  post_id uuid not null references posts(id),
  starts_at timestamptz not null, duration_min int not null default 60,
  status booking_status not null default 'pending',
  created_at timestamptz not null default now(),
  exclude using gist (post_id with =, tstzrange(starts_at, starts_at + make_interval(mins=>duration_min)) with &&)
    where (status in ('pending','confirmed'))
);
create table waitlist (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null, customer_id uuid not null references customers(id),
  device device_type, notified_at timestamptz, created_at timestamptz not null default now()
);
create table notifications (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null, recipient_id uuid not null,   -- profiles.id
  title text not null, body text, data jsonb default '{}'::jsonb,
  read_at timestamptz, created_at timestamptz not null default now()
);

-- ---------- SHIFTS / EXPENSES / AUDIT ----------
create table shifts (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null, employee_id uuid not null references profiles(id),
  status shift_status not null default 'open',
  opening_cash numeric(12,2) not null default 0,
  closing_cash numeric(12,2), expected_cash numeric(12,2),
  opened_at timestamptz not null default now(), closed_at timestamptz
);
create table expenses (
  id uuid primary key default gen_random_uuid(),
  lounge_id uuid not null, shift_id uuid,
  category text not null,                        -- stock|electricity|maintenance|wages|rent|internet|other
  amount numeric(12,2) not null check (amount>0),
  note text, created_by uuid, created_at timestamptz not null default now()
);
create table activity_log (                      -- append-only audit
  id bigint generated always as identity primary key,
  lounge_id uuid not null, actor_id uuid,
  action text not null, entity text not null, entity_id text,
  old_value jsonb, new_value jsonb, post_id uuid,
  created_at timestamptz not null default now()
);

-- ---------- PHASE 2 (create later, not in MVP) ----------
-- promotions, combos, combo_items, membership_plans, customer_memberships,
-- loyalty rules, tournaments, tournament_players, matches_bracket

-- =====================================================================
-- HELPERS
-- =====================================================================
create or replace function app.lounge_id() returns uuid language sql stable security definer as
$$ select lounge_id from profiles where id = auth.uid() $$;
create or replace function app.role() returns user_role language sql stable security definer as
$$ select role from profiles where id = auth.uid() $$;
create or replace function app.is_staff() returns boolean language sql stable security definer as
$$ select coalesce(app.role() in ('owner','manager','employee'), false) $$;
create or replace function app.is_admin() returns boolean language sql stable security definer as
$$ select coalesce(app.role() in ('owner','manager'), false) $$;

create or replace function app.log(p_action text, p_entity text, p_id text, p_old jsonb, p_new jsonb, p_post uuid default null)
returns void language sql as $$
  insert into activity_log(lounge_id,actor_id,action,entity,entity_id,old_value,new_value,post_id)
  values (app.lounge_id(), auth.uid(), p_action, p_entity, p_id, p_old, p_new, p_post)
$$;

-- generic audit trigger for configuration tables (prices, products, games, posts...)
create or replace function app.audit_trigger() returns trigger language plpgsql security definer as $$
begin
  insert into activity_log(lounge_id,actor_id,action,entity,entity_id,old_value,new_value)
  values (coalesce(new.lounge_id,old.lounge_id), auth.uid(), tg_op, tg_table_name,
          coalesce(new.id,old.id)::text, to_jsonb(old), to_jsonb(new));
  return coalesce(new,old);
end $$;
create trigger audit_products after insert or update or delete on products for each row execute function app.audit_trigger();
create trigger audit_games   after insert or update or delete on games    for each row execute function app.audit_trigger();
create trigger audit_posts   after insert or update or delete on posts    for each row execute function app.audit_trigger();

-- =====================================================================
-- BILL (computed, never typed by hand)
-- =====================================================================
create or replace view session_bill as
select s.id as session_id, s.lounge_id,
       coalesce((select sum(amount) from session_events e
                 where e.session_id=s.id and e.type in ('match_added','time_added','discount')),0) as gaming_total,
       coalesce((select sum(oi.qty*oi.unit_price) from orders o join order_items oi on oi.order_id=o.id
                 where o.session_id=s.id and o.status<>'cancelled'),0) as products_total,
       coalesce((select sum(amount) from payments p where p.session_id=s.id),0) as paid_total
from sessions s;

create or replace function app.session_elapsed_seconds(p_session uuid) returns int
language sql stable as $$
  select greatest(0, extract(epoch from (coalesce(ended_at, case when status='paused' then paused_at else now() end) - started_at))::int
         - paused_total_seconds) from sessions where id=p_session
$$;

-- =====================================================================
-- CORE RPCs — every mutation: lock row -> validate state -> write event -> log
-- =====================================================================
create or replace function app.start_session(p_post uuid, p_game uuid, p_customer uuid default null)
returns sessions language plpgsql security definer as $$
declare po posts; g games; s sessions;
begin
  if not app.is_staff() then raise exception 'forbidden'; end if;
  select * into po from posts where id=p_post and lounge_id=app.lounge_id() for update;
  if po.id is null then raise exception 'post not found'; end if;
  if po.status not in ('available','reserved') then raise exception 'post not available (%)', po.status; end if;
  select * into g from games where id=p_game and lounge_id=app.lounge_id() and is_available;
  if g.id is null then raise exception 'game not available'; end if;
  insert into sessions(lounge_id,customer_id,post_id,game_id,employee_id)
    values (app.lounge_id(),p_customer,p_post,p_game,auth.uid()) returning * into s;
  insert into session_events(lounge_id,session_id,type,created_by) values (s.lounge_id,s.id,'started',auth.uid());
  update posts set status='playing' where id=p_post;
  perform app.log('start_session','sessions',s.id::text,null,to_jsonb(s),p_post);
  return s;
end $$;

create or replace function app.add_match(p_session uuid, p_qty int default 1)
returns session_events language plpgsql security definer as $$
declare s sessions; g games; ev session_events;
begin
  if not app.is_staff() then raise exception 'forbidden'; end if;
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;   -- LOCK
  if s.status <> 'active' then raise exception 'session is % — cannot add match', s.status; end if;
  select * into g from games where id=s.game_id;
  if g.pricing <> 'per_match' then raise exception 'game is not priced per match'; end if;
  insert into session_events(lounge_id,session_id,type,qty,unit_price,amount,game_id,created_by)
    values (s.lounge_id,s.id,'match_added',p_qty,g.price,p_qty*g.price,g.id,auth.uid()) returning * into ev;
  update sessions set version=version+1, updated_at=now() where id=s.id;
  return ev;
end $$;

create or replace function app.add_time(p_session uuid, p_minutes int)
returns session_events language plpgsql security definer as $$
declare s sessions; g games; ev session_events; units numeric;
begin
  if not app.is_staff() then raise exception 'forbidden'; end if;
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;
  if s.status not in ('active','paused') then raise exception 'session is % — cannot add time', s.status; end if;
  select * into g from games where id=s.game_id;
  if g.pricing <> 'per_time' then raise exception 'game is not priced per time'; end if;
  units := p_minutes::numeric / g.time_unit_minutes;
  insert into session_events(lounge_id,session_id,type,minutes,unit_price,amount,game_id,created_by)
    values (s.lounge_id,s.id,'time_added',p_minutes,g.price,round(units*g.price,2),g.id,auth.uid()) returning * into ev;
  update sessions set paid_minutes=paid_minutes+p_minutes, version=version+1, updated_at=now() where id=s.id;
  return ev;
end $$;

create or replace function app.pause_session(p_session uuid) returns sessions language plpgsql security definer as $$
declare s sessions;
begin
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;
  if s.status<>'active' then raise exception 'session is %', s.status; end if;
  update sessions set status='paused', paused_at=now(), version=version+1, updated_at=now() where id=s.id returning * into s;
  insert into session_events(lounge_id,session_id,type,created_by) values (s.lounge_id,s.id,'paused',auth.uid());
  return s;
end $$;

create or replace function app.resume_session(p_session uuid) returns sessions language plpgsql security definer as $$
declare s sessions;
begin
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;
  if s.status<>'paused' then raise exception 'session is %', s.status; end if;
  update sessions set status='active',
    paused_total_seconds = paused_total_seconds + extract(epoch from now()-paused_at)::int,
    paused_at=null, version=version+1, updated_at=now() where id=s.id returning * into s;
  insert into session_events(lounge_id,session_id,type,created_by) values (s.lounge_id,s.id,'resumed',auth.uid());
  return s;
end $$;

create or replace function app.transfer_session(p_session uuid, p_new_post uuid) returns sessions
language plpgsql security definer as $$
declare s sessions; old_post uuid; np posts;
begin
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;
  if s.status not in ('active','paused') then raise exception 'cannot transfer a % session', s.status; end if;
  select * into np from posts where id=p_new_post and lounge_id=app.lounge_id() for update;
  if np.status not in ('available','reserved') then raise exception 'target post not available'; end if;
  old_post := s.post_id;
  update sessions set post_id=p_new_post, version=version+1, updated_at=now() where id=s.id returning * into s;
  update posts set status='available' where id=old_post;
  update posts set status='playing' where id=p_new_post;
  insert into session_events(lounge_id,session_id,type,meta,created_by)
    values (s.lounge_id,s.id,'transferred',jsonb_build_object('from',old_post,'to',p_new_post),auth.uid());
  return s;
end $$;

create or replace function app.end_session(p_session uuid) returns sessions language plpgsql security definer as $$
declare s sessions;
begin
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;
  if s.status not in ('active','paused') then raise exception 'session already %', s.status; end if;
  update sessions set status='waiting_payment', ended_at=now(),
     paused_total_seconds = paused_total_seconds + case when status='paused' then extract(epoch from now()-paused_at)::int else 0 end,
     paused_at=null, version=version+1, updated_at=now() where id=s.id returning * into s;
  update posts set status='waiting_payment' where id=s.post_id;
  insert into session_events(lounge_id,session_id,type,created_by) values (s.lounge_id,s.id,'ended',auth.uid());
  return s;
end $$;

-- Customer requests -> staff decision
create or replace function app.create_request(p_session uuid, p_type request_type, p_payload jsonb)
returns requests language plpgsql security definer as $$
declare s sessions; r requests;
begin
  select * into s from sessions where id=p_session;
  if s.status <> 'active' then raise exception 'session not active'; end if;
  insert into requests(lounge_id,session_id,post_id,customer_id,type,payload)
    values (s.lounge_id,s.id,s.post_id,s.customer_id,p_type,p_payload) returning * into r;
  insert into notifications(lounge_id,recipient_id,title,body,data)
    select s.lounge_id, id, 'Request', p_type::text, jsonb_build_object('request_id',r.id,'post_id',s.post_id)
    from profiles where lounge_id=s.lounge_id and role in ('owner','manager','employee') and is_active;
  return r;
end $$;

create or replace function app.decide_request(p_request uuid, p_accept boolean)
returns requests language plpgsql security definer as $$
declare r requests;
begin
  if not app.is_staff() then raise exception 'forbidden'; end if;
  select * into r from requests where id=p_request and lounge_id=app.lounge_id() for update;
  if r.status<>'pending' then raise exception 'already %', r.status; end if;
  if p_accept then
    if r.type='match' then perform app.add_match(r.session_id,(r.payload->>'qty')::int);
    elsif r.type='time' then perform app.add_time(r.session_id,(r.payload->>'minutes')::int);
    end if;  -- 'product' handled by app.create_order; 'checkout' -> end_session
  end if;
  update requests set status = case when p_accept then 'accepted' else 'rejected' end::request_status,
         handled_by=auth.uid(), handled_at=now() where id=r.id returning * into r;
  return r;
end $$;

-- Stock deduction happens when an order is CONFIRMED (same transaction), restored on cancel.
create or replace function app.confirm_order(p_order uuid) returns orders language plpgsql security definer as $$
declare o orders; it record; p products;
begin
  select * into o from orders where id=p_order and lounge_id=app.lounge_id() for update;
  if o.status<>'pending' then raise exception 'order is %', o.status; end if;
  for it in select * from order_items where order_id=o.id loop
    select * into p from products where id=it.product_id for update;
    if p.track_stock and p.stock < it.qty then raise exception 'insufficient stock: %', p.name; end if;
    if p.track_stock then
      update products set stock=stock-it.qty where id=p.id;
      insert into stock_movements(lounge_id,product_id,delta,reason,order_item_id,created_by)
        values (o.lounge_id,p.id,-it.qty,'sale',it.id,auth.uid());
    end if;
  end loop;
  update orders set status='confirmed', updated_at=now() where id=o.id returning * into o;
  return o;
end $$;

create or replace function app.attach_order_to_session(p_order uuid, p_session uuid) returns orders
language plpgsql security definer as $$
declare o orders;
begin
  update orders set session_id=p_session, status='added_to_session', updated_at=now()
   where id=p_order and lounge_id=app.lounge_id() returning * into o;
  insert into session_events(lounge_id,session_id,type,order_id,created_by)
    values (o.lounge_id,p_session,'product_added',o.id,auth.uid());
  return o;
end $$;

-- Payment: p_lines = [{"method":"cash","amount":500},{"method":"wallet","amount":300},{"method":"credit","amount":200}]
create or replace function app.pay_session(p_session uuid, p_lines jsonb) returns sessions
language plpgsql security definer as $$
declare s sessions; b session_bill; l jsonb; amt numeric; m pay_method; pid uuid; sum_lines numeric := 0; bal numeric;
begin
  select * into s from sessions where id=p_session and lounge_id=app.lounge_id() for update;
  if s.status<>'waiting_payment' then raise exception 'session is %', s.status; end if;
  select * into b from session_bill where session_id=s.id;
  for l in select * from jsonb_array_elements(p_lines) loop
    m := (l->>'method')::pay_method; amt := (l->>'amount')::numeric;
    if m in ('wallet','credit') and s.customer_id is null then raise exception 'customer required for %', m; end if;
    if m='wallet' then
      select wallet into bal from customer_balances where customer_id=s.customer_id;
      if coalesce(bal,0) < amt then raise exception 'insufficient wallet'; end if;
    end if;
    insert into payments(lounge_id,session_id,customer_id,method,amount,created_by)
      values (s.lounge_id,s.id,s.customer_id,m,amt,auth.uid()) returning id into pid;
    if m='wallet' then insert into ledger_entries(lounge_id,customer_id,account,delta,reason,session_id,payment_id,created_by)
        values (s.lounge_id,s.customer_id,'wallet',-amt,'spend',s.id,pid,auth.uid()); end if;
    if m='credit' then insert into ledger_entries(lounge_id,customer_id,account,delta,reason,session_id,payment_id,created_by)
        values (s.lounge_id,s.customer_id,'credit',amt,'debt_created',s.id,pid,auth.uid()); end if;
    sum_lines := sum_lines + amt;
  end loop;
  if sum_lines <> (b.gaming_total + b.products_total) then
    raise exception 'payments (%) must equal total (%)', sum_lines, b.gaming_total + b.products_total;
  end if;
  update sessions set status='closed', version=version+1, updated_at=now() where id=s.id returning * into s;
  update posts set status='available' where id=s.post_id;
  insert into session_events(lounge_id,session_id,type,amount,created_by) values (s.lounge_id,s.id,'payment',0,auth.uid());
  return s;
end $$;
-- NOTE: credit repayment = separate RPC app.repay_credit(customer, amount, method) writing ledger credit -X.

-- =====================================================================
-- RLS
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['lounges','profiles','staff_permissions','customers','posts','games','post_games','product_categories',
    'products','stock_movements','sessions','session_events','requests','orders','order_items','payments','ledger_entries',
    'bookings','waitlist','notifications','shifts','expenses','activity_log']
  loop execute format('alter table %I enable row level security', t); end loop;
end $$;

-- staff of the lounge can READ everything of the lounge (writes go through RPCs or admin policies)
do $$
declare t text;
begin
  foreach t in array array['customers','posts','games','products','product_categories','sessions','session_events','requests',
    'orders','payments','ledger_entries','bookings','waitlist','shifts','expenses','stock_movements']
  loop execute format($f$create policy staff_read on %I for select using (app.is_staff() and lounge_id = app.lounge_id())$f$, t); end loop;
end $$;

-- CUSTOMERS can read catalog (games, products, posts) of their lounge  -> realtime catalog
create policy cust_read_games    on games    for select using (lounge_id = app.lounge_id() and is_available);
create policy cust_read_products on products for select using (lounge_id = app.lounge_id() and is_available);
create policy cust_read_posts    on posts    for select using (lounge_id = app.lounge_id());
-- ... and ONLY their own sessions/orders/requests/ledger/bookings/notifications
create policy cust_own_sessions on sessions for select using (customer_id in (select id from customers where profile_id=auth.uid()));
create policy cust_own_events   on session_events for select using (session_id in (select id from sessions where customer_id in (select id from customers where profile_id=auth.uid())));
create policy cust_own_orders   on orders for select using (customer_id in (select id from customers where profile_id=auth.uid()));
create policy cust_own_ledger   on ledger_entries for select using (customer_id in (select id from customers where profile_id=auth.uid()));
create policy cust_own_notifs   on notifications for select using (recipient_id = auth.uid());
create policy cust_own_bookings on bookings for select using (customer_id in (select id from customers where profile_id=auth.uid()));

-- ADMIN (owner/manager) CRUD on catalog
do $$
declare t text;
begin
  foreach t in array array['posts','games','post_games','products','product_categories','staff_permissions','expenses']
  loop execute format($f$create policy admin_write on %I for all using (app.is_admin()) with check (app.is_admin())$f$, t); end loop;
end $$;

-- append-only guarantees
revoke update, delete on session_events, ledger_entries, stock_movements, activity_log, payments from authenticated, anon;
-- activity_log readable by owner only
create policy owner_read_log on activity_log for select using (app.role()='owner' and lounge_id=app.lounge_id());

-- REALTIME: enable for posts, games, products, sessions, session_events, requests, orders, notifications
-- alter publication supabase_realtime add table posts, games, products, sessions, session_events, requests, orders, notifications;
