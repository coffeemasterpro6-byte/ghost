-- Owner-managed employee invitations. Tokens are stored only as SHA-256 hashes.
create table staff_invitations (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  email text not null,
  token_hash text not null unique,
  permissions jsonb not null default '{}'::jsonb,
  invited_by uuid not null references auth.users(id),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_by uuid references auth.users(id),
  accepted_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  check (email = lower(trim(email))),
  check (jsonb_typeof(permissions) = 'object')
);
create index staff_invitations_venue_idx
  on staff_invitations(venue_id, created_at desc);

alter table staff_invitations enable row level security;
create policy staff_invitations_owner_read on staff_invitations
  for select using (app.role_in(venue_id) = 'owner');
grant select on staff_invitations to authenticated;

create or replace function public.create_staff_invitation(
  p_email text,
  p_permissions jsonb default '{}'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_email text := lower(trim(coalesce(p_email, '')));
  v_token text := encode(gen_random_bytes(32), 'hex');
  v_permissions jsonb := coalesce(p_permissions, '{}'::jsonb);
  v_invitation staff_invitations;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'INVALID_EMAIL';
  end if;
  if jsonb_typeof(v_permissions) <> 'object' then
    raise exception 'INVALID_PERMISSIONS';
  end if;
  if exists (
    select 1
      from jsonb_each(v_permissions) item
     where item.key not in (
       'manage_stock', 'view_reports', 'give_discount',
       'cancel_session', 'refund', 'edit_prices', 'manage_credit'
     )
        or jsonb_typeof(item.value) <> 'boolean'
  ) then
    raise exception 'INVALID_PERMISSIONS';
  end if;

  select venue_id into v_venue
    from venue_members
   where user_id = auth.uid() and is_active and role = 'owner'
   order by created_at
   limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;

  if exists (
    select 1 from venue_members m
    join auth.users u on u.id = m.user_id
    where m.venue_id = v_venue and lower(u.email) = v_email
  ) then
    raise exception 'MEMBER_ALREADY_EXISTS';
  end if;

  update staff_invitations
     set cancelled_at = now()
   where venue_id = v_venue and email = v_email
     and accepted_at is null and cancelled_at is null;

  insert into staff_invitations(
    venue_id, email, token_hash, permissions, invited_by
  )
  values (
    v_venue, v_email, encode(digest(v_token, 'sha256'), 'hex'),
    v_permissions, auth.uid()
  )
  returning * into v_invitation;

  perform app.audit(
    v_venue, 'employee_invited', 'staff_invitation',
    v_invitation.id::text, jsonb_build_object('email', v_email)
  );
  return jsonb_build_object(
    'invitation_id', v_invitation.id,
    'email', v_email,
    'token', v_token,
    'expires_at', v_invitation.expires_at
  );
end
$$;

create or replace function public.accept_staff_invitation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_email text;
  v_confirmed_at timestamptz;
  v_invitation staff_invitations;
  v_name text;
begin
  if v_user is null then raise exception 'UNAUTHENTICATED'; end if;
  if nullif(trim(p_token), '') is null then raise exception 'INVITATION_INVALID'; end if;

  select lower(email), email_confirmed_at
    into v_email, v_confirmed_at
    from auth.users where id = v_user;
  if v_email is null or v_confirmed_at is null then
    raise exception 'CONFIRMED_EMAIL_REQUIRED';
  end if;

  select * into v_invitation
    from staff_invitations
   where token_hash = encode(digest(trim(p_token), 'sha256'), 'hex')
   for update;
  if v_invitation.id is null then raise exception 'INVITATION_INVALID'; end if;
  if v_invitation.email <> v_email then raise exception 'INVITATION_EMAIL_MISMATCH'; end if;
  if v_invitation.cancelled_at is not null then raise exception 'INVITATION_CANCELLED'; end if;
  if v_invitation.accepted_at is not null then
    if v_invitation.accepted_by = v_user then
      return jsonb_build_object('venue_id', v_invitation.venue_id);
    end if;
    raise exception 'INVITATION_ALREADY_USED';
  end if;
  if v_invitation.expires_at <= now() then raise exception 'INVITATION_EXPIRED'; end if;
  if exists (
    select 1 from venue_members
     where venue_id = v_invitation.venue_id and user_id = v_user
  ) then
    raise exception 'MEMBER_ALREADY_EXISTS';
  end if;

  v_name := nullif(trim((select raw_user_meta_data ->> 'full_name'
                           from auth.users where id = v_user)), '');
  insert into profiles(id, full_name)
  values (v_user, coalesce(v_name, split_part(v_email, '@', 1)))
  on conflict (id) do update
    set full_name = coalesce(profiles.full_name, excluded.full_name);

  insert into venue_members(venue_id, user_id, role, permissions)
  values (
    v_invitation.venue_id, v_user, 'employee', v_invitation.permissions
  );
  update staff_invitations
     set accepted_by = v_user, accepted_at = now()
   where id = v_invitation.id;
  perform app.audit(
    v_invitation.venue_id, 'employee_joined', 'venue_member', v_user::text,
    jsonb_build_object('email', v_email, 'invitation_id', v_invitation.id)
  );

  return jsonb_build_object('venue_id', v_invitation.venue_id);
end
$$;

create or replace function public.set_employee_permissions(
  p_user uuid,
  p_permissions jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
begin
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid() and m.is_active and m.role = 'owner'
   order by m.created_at limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;
  if p_permissions is null or jsonb_typeof(p_permissions) <> 'object' then
    raise exception 'INVALID_PERMISSIONS';
  end if;
  if exists (
    select 1 from jsonb_each(p_permissions) item
     where item.key not in (
       'manage_stock', 'view_reports', 'give_discount',
       'cancel_session', 'refund', 'edit_prices', 'manage_credit'
     )
        or jsonb_typeof(item.value) <> 'boolean'
  ) then
    raise exception 'INVALID_PERMISSIONS';
  end if;
  update venue_members
     set permissions = p_permissions
   where venue_id = v_venue and user_id = p_user and role = 'employee';
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  perform app.audit(
    v_venue, 'employee_permissions_changed', 'venue_member', p_user::text,
    p_permissions
  );
end
$$;

create or replace function public.set_employee_active(
  p_user uuid,
  p_is_active boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
begin
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid() and m.is_active and m.role = 'owner'
   order by m.created_at limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;
  update venue_members
     set is_active = p_is_active
   where venue_id = v_venue and user_id = p_user and role = 'employee';
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  perform app.audit(
    v_venue,
    case when p_is_active then 'employee_activated' else 'employee_deactivated' end,
    'venue_member', p_user::text, '{}'
  );
end
$$;

create or replace function public.cancel_staff_invitation(p_invitation uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
begin
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid() and m.is_active and m.role = 'owner'
   order by m.created_at limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;
  update staff_invitations
     set cancelled_at = now()
   where id = p_invitation and venue_id = v_venue
     and accepted_at is null and cancelled_at is null;
  if not found then raise exception 'INVITATION_NOT_FOUND'; end if;
  perform app.audit(
    v_venue, 'employee_invitation_cancelled', 'staff_invitation',
    p_invitation::text, '{}'
  );
end
$$;

create or replace function public.list_venue_staff()
returns table (
  user_id uuid,
  email text,
  full_name text,
  phone text,
  role member_role,
  is_active boolean,
  permissions jsonb,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
begin
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid() and m.is_active and m.role = 'owner'
   order by m.created_at limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;

  return query
  select m.user_id, u.email::text, p.full_name, p.phone,
         m.role, m.is_active, m.permissions, m.created_at
    from venue_members m
    join auth.users u on u.id = m.user_id
    left join profiles p on p.id = m.user_id
   where m.venue_id = v_venue and m.role in ('employee', 'manager')
   order by m.created_at;
end
$$;

revoke all on function public.create_staff_invitation(text, jsonb) from public, anon;
revoke all on function public.accept_staff_invitation(text) from public, anon;
revoke all on function public.set_employee_permissions(uuid, jsonb) from public, anon;
revoke all on function public.set_employee_active(uuid, boolean) from public, anon;
revoke all on function public.cancel_staff_invitation(uuid) from public, anon;
revoke all on function public.list_venue_staff() from public, anon;
grant execute on function public.create_staff_invitation(text, jsonb) to authenticated;
grant execute on function public.accept_staff_invitation(text) to authenticated;
grant execute on function public.set_employee_permissions(uuid, jsonb) to authenticated;
grant execute on function public.set_employee_active(uuid, boolean) to authenticated;
grant execute on function public.cancel_staff_invitation(uuid) to authenticated;
grant execute on function public.list_venue_staff() to authenticated;
