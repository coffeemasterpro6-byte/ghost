-- Create the initial venue for an authenticated owner after email verification.
create or replace function public.setup_owner_venue()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_metadata jsonb;
  v_full_name text;
  v_venue_name text;
  v_phone text;
  v_venue venues;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));

  select v.* into v_venue
  from venues v
  join venue_members m on m.venue_id = v.id
  where m.user_id = v_user and m.role = 'owner' and m.is_active
  order by m.created_at
  limit 1;

  if v_venue.id is not null then
    return jsonb_build_object('venue_id', v_venue.id, 'name', v_venue.name);
  end if;

  select raw_user_meta_data into v_metadata
  from auth.users where id = v_user;

  v_full_name := nullif(trim(v_metadata ->> 'full_name'), '');
  v_venue_name := nullif(trim(v_metadata ->> 'venue_name'), '');
  v_phone := nullif(trim(v_metadata ->> 'phone'), '');
  if v_full_name is null or v_venue_name is null then
    raise exception 'OWNER_SETUP_DATA_REQUIRED';
  end if;
  if length(v_full_name) > 120 or length(v_venue_name) > 120
     or length(coalesce(v_phone, '')) > 32 then
    raise exception 'OWNER_SETUP_DATA_INVALID';
  end if;

  insert into profiles(id, full_name, phone)
  values (v_user, v_full_name, v_phone)
  on conflict (id) do update
    set full_name = excluded.full_name,
        phone = coalesce(excluded.phone, profiles.phone);

  insert into venues(name, created_by)
  values (v_venue_name, v_user)
  returning * into v_venue;

  insert into venue_members(venue_id, user_id, role)
  values (v_venue.id, v_user, 'owner');

  return jsonb_build_object('venue_id', v_venue.id, 'name', v_venue.name);
end
$$;

revoke all on function public.setup_owner_venue() from public, anon;
grant execute on function public.setup_owner_venue() to authenticated;

create or replace function public.setup_customer_venue()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_metadata jsonb;
  v_full_name text;
  v_venue_name text;
  v_phone text;
  v_email text;
  v_venue venues;
  v_customer customers;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  select raw_user_meta_data, email into v_metadata, v_email
  from auth.users where id = v_user;

  v_full_name := nullif(trim(v_metadata ->> 'full_name'), '');
  v_venue_name := nullif(trim(v_metadata ->> 'venue_name'), '');
  v_phone := nullif(trim(v_metadata ->> 'phone'), '');

  if v_venue_name is null then
    raise exception 'VENUE_NAME_REQUIRED';
  end if;

  select * into v_venue
  from venues
  where lower(trim(name)) = lower(trim(v_venue_name))
  limit 1;

  if v_venue.id is null then
    raise exception 'VENUE_NOT_FOUND';
  end if;

  insert into venue_members(venue_id, user_id, role)
  values (v_venue.id, v_user, 'customer')
  on conflict (venue_id, user_id) do nothing;

  insert into customers(venue_id, user_id, full_name, phone)
  values (v_venue.id, v_user, coalesce(v_full_name, v_email, 'Client'), v_phone)
  on conflict (venue_id, user_id) do update
  set full_name = excluded.full_name
  returning * into v_customer;

  return jsonb_build_object('venue_id', v_venue.id, 'venue_name', v_venue.name, 'customer_id', v_customer.id);
end
$$;

revoke all on function public.setup_customer_venue() from public, anon;
grant execute on function public.setup_customer_venue() to authenticated;
