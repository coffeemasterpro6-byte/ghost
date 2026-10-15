-- =====================================================================
-- 001 FOUNDATION — venues, membership, RBAC helpers, idempotency, audit
-- Multi-tenant: EVERY business table carries venue_id. RLS is the security boundary.
-- Client-callable RPCs live in `public`; internal helpers live in `app` (not exposed by the Data API).
-- =====================================================================
create extension if not exists pgcrypto;
create extension if not exists btree_gist;
create schema if not exists app;

create type member_role as enum ('owner','manager','employee','customer');

create table venues (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  timezone    text not null default 'Africa/Algiers',
  currency    text not null default 'DA',
  settings    jsonb not null default '{}'::jsonb,   -- e.g. {"customer_can_start_session":false}
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  phone       text,
  avatar_url  text,
  fcm_token   text,
  created_at  timestamptz not null default now()
);

create table venue_members (
  venue_id    uuid not null references venues(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        member_role not null,
  is_active   boolean not null default true,
  permissions jsonb not null default '{}'::jsonb,   -- fine-grained flags, see app.has_perm
  created_at  timestamptz not null default now(),
  primary key (venue_id, user_id)
);
create index venue_members_user_idx on venue_members(user_id);
-- exactly one owner per venue (ownership transfer = explicit operation later)
create unique index one_owner_per_venue on venue_members(venue_id) where role = 'owner';

-- ---------- RBAC helpers (SECURITY DEFINER so RLS policies can call them without recursion) ----------
create or replace function app.role_in(p_venue uuid) returns member_role
language sql stable security definer set search_path = public as $$
  select role from venue_members where venue_id = p_venue and user_id = auth.uid() and is_active
$$;
create or replace function app.is_member(p_venue uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from venue_members where venue_id = p_venue and user_id = auth.uid() and is_active)
$$;
create or replace function app.is_staff(p_venue uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.role_in(p_venue) in ('owner','manager','employee'), false)
$$;
create or replace function app.is_admin(p_venue uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.role_in(p_venue) in ('owner','manager'), false)
$$;
-- permission flags: owner = always true; manager = true unless explicitly false; employee = false unless explicitly true
-- known flags: give_discount, cancel_session, refund, edit_prices, manage_stock, view_reports, manage_credit
create or replace function app.has_perm(p_venue uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case m.role
             when 'owner'    then true
             when 'manager'  then coalesce((m.permissions ->> p_perm)::boolean, true)
             when 'employee' then coalesce((m.permissions ->> p_perm)::boolean, false)
             else false end
    from venue_members m
    where m.venue_id = p_venue and m.user_id = auth.uid() and m.is_active
  ), false)
$$;

-- ---------- Idempotency: every mutating RPC receives a client-generated operation_id (UUID) ----------
create table operations (
  operation_id uuid primary key,
  venue_id     uuid not null,
  rpc          text not null,
  actor_id     uuid,
  result       jsonb,
  created_at   timestamptz not null default now()
);
-- returns the stored result when the SAME operation was already executed (replay), otherwise NULL and registers it.
create or replace function app.begin_op(p_op uuid, p_venue uuid, p_rpc text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int; r jsonb; a uuid;
begin
  insert into operations(operation_id, venue_id, rpc, actor_id) values (p_op, p_venue, p_rpc, auth.uid())
  on conflict (operation_id) do nothing;
  get diagnostics n = row_count;
  if n = 1 then return null; end if;
  select result, actor_id into r, a from operations where operation_id = p_op;
  if a is distinct from auth.uid() then raise exception 'FORBIDDEN'; end if;
  if r is null then raise exception 'OPERATION_IN_PROGRESS'; end if;
  return r;
end $$;
create or replace function app.end_op(p_op uuid, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update operations set result = p_result where operation_id = p_op;
  return p_result;
end $$;

-- ---------- Audit log (append-only) ----------
create table audit_logs (
  id          bigint generated always as identity primary key,
  venue_id    uuid not null,
  actor_id    uuid,
  action      text not null,          -- price_change | session_start | match_added | time_added | payment_created | ...
  entity_type text not null,
  entity_id   text,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index audit_logs_venue_idx on audit_logs(venue_id, created_at desc);

create or replace function app.audit(p_venue uuid, p_action text, p_type text, p_id text, p_meta jsonb default '{}')
returns void language sql security definer set search_path = public as $$
  insert into audit_logs(venue_id, actor_id, action, entity_type, entity_id, metadata)
  values (p_venue, auth.uid(), p_action, p_type, p_id, coalesce(p_meta, '{}'::jsonb))
$$;

-- generic audit trigger for configuration tables
create or replace function app.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.audit(coalesce(new.venue_id, old.venue_id), lower(tg_op) || '_' || tg_table_name, tg_table_name,
                    coalesce(new.id, old.id)::text, jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)));
  return coalesce(new, old);
end $$;

-- ---------- Realtime: Broadcast-from-database over PRIVATE channels (see MASTER_BRIEF §9) ----------
-- topic format: venue:{venue_id}:{scope}   scope in: posts | sessions | orders | catalog | notifications ...
create or replace function app.broadcast_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare v uuid := coalesce(new.venue_id, old.venue_id);
begin
  perform realtime.broadcast_changes('venue:' || v || ':' || tg_argv[0], tg_op, tg_op, tg_table_name, tg_table_schema, new, old);
  return coalesce(new, old);
end $$;

-- ---------- RLS ----------
alter table venues enable row level security;
alter table profiles enable row level security;
alter table venue_members enable row level security;
alter table operations enable row level security;      -- no policies => client can never read/write
alter table audit_logs enable row level security;

create policy venues_member_read   on venues for select using (app.is_member(id));
create policy venues_owner_update  on venues for update using (app.role_in(id) = 'owner') with check (app.role_in(id) = 'owner');
create policy profiles_self        on profiles for all using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_staff_read  on profiles for select using (exists (
  select 1 from venue_members me join venue_members o on o.venue_id = me.venue_id
  where me.user_id = auth.uid() and me.is_active and me.role in ('owner','manager','employee') and o.user_id = profiles.id));
create policy members_read_self    on venue_members for select using (user_id = auth.uid() or app.is_admin(venue_id));
create policy members_owner_write  on venue_members for all using (app.role_in(venue_id) = 'owner' and role <> 'owner')
                                                       with check (app.role_in(venue_id) = 'owner' and role <> 'owner');
create policy audit_owner_read     on audit_logs for select using (app.role_in(venue_id) = 'owner');

grant select on venues, venue_members, audit_logs to authenticated;
grant update on venues to authenticated;
grant select, insert, update on profiles to authenticated;
grant insert, update, delete on venue_members to authenticated;
-- audit_logs / operations: never writable by clients
