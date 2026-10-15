-- =====================================================================
-- 002 CATALOG — posts, games (match / time policy), customers
-- Server NEVER guesses whether a game is football. Classification happens ONCE in Flutter
-- (GameClassificationService), the Owner may override, and the RESULT is stored in games.game_mode.
-- All server math reads the stored fields only.
-- =====================================================================
create type device_type  as enum ('ps4','ps5','xbox','pc','vr','pool','billiard','racing','other');
create type post_status  as enum ('available','reserved','starting','playing','paused','waiting_payment','maintenance','offline');
create type game_mode    as enum ('match_based','time_based','custom');
create type mode_source  as enum ('auto','owner');      -- owner = explicit override, auto-detection must never touch it
create type pricing_unit as enum ('per_match','per_minute','per_15_minutes','per_30_minutes','per_hour','fixed_price');
-- later migrations extend pricing with: package, promotion, membership_discount (separate tables, not enum values)

create table posts (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references venues(id) on delete cascade,
  number      int  not null check (number > 0),          -- never hard-code 12: dynamic
  name        text not null,
  device      device_type not null default 'ps5',
  zone        text,
  image_url   text,
  screen_info text,                                      -- 'PS5 · 55" Screen'
  max_players int  not null default 2 check (max_players > 0),
  status      post_status not null default 'available',  -- maintained ONLY by session RPCs, or by admin for maintenance/offline/available
  qr_token    text not null unique default encode(gen_random_bytes(16), 'hex'),
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (venue_id, number)
);
create index posts_venue_idx on posts(venue_id);

create table games (
  id              uuid primary key default gen_random_uuid(),
  venue_id        uuid not null references venues(id) on delete cascade,
  name            text not null,
  subtitle        text,
  platform        device_type not null default 'ps5',
  category        text,
  image_url       text,
  description     text,
  game_mode       game_mode    not null default 'time_based',
  mode_source     mode_source  not null default 'auto',
  pricing_unit    pricing_unit not null default 'per_hour',
  price           numeric(12,2) not null check (price >= 0),
  match_minutes   int check (match_minutes > 0),                       -- in-game match length (e.g. 10)
  time_multiplier numeric(4,2) not null default 1 check (time_multiplier > 0), -- eFootball 1.7 / other football 1.5 (set by GameTimingPolicy at creation, owner-editable)
  effective_match_seconds int generated always as
      (case when match_minutes is null then null
            else round(match_minutes * time_multiplier * 60)::int end) stored,
  is_available    boolean not null default true,
  is_trending     boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint games_match_rules check (game_mode <> 'match_based' or (pricing_unit = 'per_match' and match_minutes is not null)),
  constraint games_time_rules  check (game_mode <> 'time_based'  or pricing_unit <> 'per_match')
);
create index games_venue_idx on games(venue_id);

create table post_games (          -- which games a post supports (empty set = all games)
  post_id uuid not null references posts(id) on delete cascade,
  game_id uuid not null references games(id) on delete cascade,
  primary key (post_id, game_id)
);

create table customers (
  id         uuid primary key default gen_random_uuid(),
  venue_id   uuid not null references venues(id) on delete cascade,
  user_id    uuid references auth.users(id) on delete set null,   -- null = walk-in customer without app account
  full_name  text not null,
  phone      text,
  photo_url  text,
  created_at timestamptz not null default now(),
  unique (venue_id, user_id),
  unique (venue_id, phone)
);
create index customers_user_idx on customers(user_id);

-- ---------- triggers: updated_at, audit, realtime ----------
create or replace function app.touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger posts_touch before update on posts for each row execute function app.touch();
create trigger games_touch before update on games for each row execute function app.touch();

create trigger posts_audit after insert or update or delete on posts for each row execute function app.audit_row();
create trigger games_audit after insert or update or delete on games for each row execute function app.audit_row();

create trigger posts_rt after insert or update or delete on posts for each row execute function app.broadcast_row('posts');
create trigger games_rt after insert or update or delete on games for each row execute function app.broadcast_row('catalog');

-- ---------- RLS ----------
alter table posts      enable row level security;
alter table games      enable row level security;
alter table post_games enable row level security;
alter table customers  enable row level security;

-- customers (app users) must see the catalog => any member of the venue can read posts & games
create policy posts_member_read on posts for select using (app.is_member(venue_id));
create policy games_member_read on games for select using (app.is_member(venue_id));
create policy post_games_read   on post_games for select using (exists (select 1 from posts p where p.id = post_id and app.is_member(p.venue_id)));
-- only admins edit the catalog
create policy posts_admin_write on posts for all using (app.is_admin(venue_id)) with check (app.is_admin(venue_id));
create policy games_admin_write on games for all using (app.is_admin(venue_id)) with check (app.is_admin(venue_id));
create policy post_games_admin  on post_games for all
  using (exists (select 1 from posts p where p.id = post_id and app.is_admin(p.venue_id)))
  with check (exists (select 1 from posts p where p.id = post_id and app.is_admin(p.venue_id)));
-- customers: staff see all of the venue, a customer sees only himself
create policy customers_staff_read on customers for select using (app.is_staff(venue_id));
create policy customers_self_read  on customers for select using (user_id = auth.uid());
create policy customers_staff_write on customers for insert with check (app.is_staff(venue_id));
create policy customers_staff_upd   on customers for update using (app.is_staff(venue_id)) with check (app.is_staff(venue_id));

grant select, insert, update, delete on posts, games, post_games to authenticated;
grant select, insert, update on customers to authenticated;
