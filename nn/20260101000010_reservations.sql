-- Confirmed reservations are serialized per post, so overlapping bookings
-- cannot be created concurrently by separate clients.
alter table posts
  add constraint posts_venue_id_id_key unique (venue_id, id);
alter table customers
  add constraint customers_venue_id_id_key unique (venue_id, id);

create table reservations (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  post_id uuid not null,
  customer_id uuid not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confirmed'
    check (status in ('confirmed', 'cancelled', 'completed', 'no_show')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  foreign key (venue_id, post_id) references posts(venue_id, id),
  foreign key (venue_id, customer_id) references customers(venue_id, id)
);

create index reservations_customer_start_idx
  on reservations(customer_id, starts_at desc);
create index reservations_venue_start_idx
  on reservations(venue_id, starts_at);

alter table reservations enable row level security;
create policy reservations_staff_read on reservations
  for select using (app.is_staff(venue_id));
create policy reservations_customer_read on reservations
  for select using (
    exists (
      select 1
        from customers c
        join venue_members m
          on m.venue_id = c.venue_id
         and m.user_id = c.user_id
       where c.id = reservations.customer_id
         and c.user_id = auth.uid()
         and m.is_active
         and m.role = 'customer'
    )
  );
grant select on reservations to authenticated;

alter table reservations
  add constraint reservations_no_overlapping_post
  exclude using gist (
    post_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status = 'confirmed');

create trigger reservations_touch before update on reservations
  for each row execute function app.touch();
create trigger reservations_rt after insert or update on reservations
  for each row execute function app.broadcast_row('reservations');

create or replace function app.notify_reservation_customer()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_post text;
  v_title text;
  v_body text;
begin
  select user_id into v_user
    from customers
   where id = new.customer_id;
  if v_user is null then return new; end if;

  select name into v_post from posts where id = new.post_id;
  if tg_op = 'INSERT' then
    v_title := 'Réservation confirmée';
    v_body := coalesce(v_post, 'Votre poste') || ' · '
      || to_char(new.starts_at at time zone 'UTC', 'DD/MM/YYYY HH24:MI')
      || ' UTC';
  elsif new.status is distinct from old.status then
    v_title := case new.status
      when 'cancelled' then 'Réservation annulée'
      when 'completed' then 'Réservation terminée'
      when 'no_show' then 'Réservation manquée'
      else 'Réservation mise à jour'
    end;
    v_body := coalesce(v_post, 'Votre poste');
  else
    return new;
  end if;

  insert into notifications(
    venue_id, recipient_id, type, title, body,
    reference_type, reference_id, data
  )
  values (
    new.venue_id, v_user, 'reservation_updated', v_title, v_body,
    'reservation', new.id,
    jsonb_build_object('reservation_id', new.id, 'status', new.status)
  );
  return new;
end
$$;

create trigger reservation_customer_notification
after insert or update on reservations
for each row execute function app.notify_reservation_customer();
revoke all on function app.notify_reservation_customer()
  from public, anon, authenticated;

create or replace function public.reserve_post(
  p_op uuid,
  p_post uuid,
  p_starts_at timestamptz,
  p_duration_minutes int
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post posts;
  v_customer customers;
  v_ends_at timestamptz;
  v_reservation reservations;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_starts_at is null or p_starts_at <= now()
     or p_starts_at > now() + interval '30 days' then
    raise exception 'INVALID_RESERVATION_TIME';
  end if;
  if p_duration_minutes is null
     or p_duration_minutes not in (30, 60, 90, 120, 180, 240) then
    raise exception 'INVALID_RESERVATION_DURATION';
  end if;

  select c.* into v_customer
    from customers c
    join venue_members m
      on m.venue_id = c.venue_id and m.user_id = c.user_id
   where c.user_id = auth.uid()
     and m.is_active and m.role = 'customer'
   order by c.created_at
   limit 1;
  if v_customer.id is null then raise exception 'CUSTOMER_NOT_LINKED'; end if;

  select * into v_post
    from posts
   where id = p_post and venue_id = v_customer.venue_id
   for update;
  if v_post.id is null then raise exception 'POST_NOT_FOUND'; end if;
  if v_post.status in ('maintenance', 'offline') then
    raise exception 'POST_UNAVAILABLE';
  end if;

  v_result := app.begin_op(
    p_op,
    v_customer.venue_id,
    'reserve_post',
    jsonb_build_object(
      'post_id', p_post,
      'starts_at', p_starts_at,
      'duration_minutes', p_duration_minutes
    )
  );
  if v_result is not null then return v_result; end if;

  v_ends_at := p_starts_at + make_interval(mins => p_duration_minutes);
  insert into reservations(
    venue_id, post_id, customer_id, starts_at, ends_at
  )
  values (
    v_customer.venue_id, v_post.id, v_customer.id, p_starts_at, v_ends_at
  )
  returning * into v_reservation;
  perform app.audit(
    v_customer.venue_id, 'reservation_created', 'reservation',
    v_reservation.id::text,
    jsonb_build_object(
      'customer_id', v_customer.id,
      'post_id', v_post.id,
      'starts_at', v_reservation.starts_at,
      'ends_at', v_reservation.ends_at
    )
  );

  return app.end_op(
    p_op,
    jsonb_build_object(
      'id', v_reservation.id,
      'post_id', v_reservation.post_id,
      'starts_at', v_reservation.starts_at,
      'ends_at', v_reservation.ends_at,
      'status', v_reservation.status
    )
  );
exception
  when exclusion_violation then
    raise exception 'RESERVATION_SLOT_TAKEN';
end
$$;

create or replace function public.cancel_reservation(
  p_op uuid,
  p_reservation uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation reservations;
  v_customer customers;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_reservation
    from reservations
   where id = p_reservation
   for update;
  if v_reservation.id is null then raise exception 'RESERVATION_NOT_FOUND'; end if;

  select c.* into v_customer
    from customers c
    join venue_members m
      on m.venue_id = c.venue_id and m.user_id = c.user_id
   where c.id = v_reservation.customer_id
     and c.user_id = auth.uid()
     and m.is_active and m.role = 'customer';
  if v_customer.id is null then raise exception 'FORBIDDEN'; end if;

  v_result := app.begin_op(
    p_op,
    v_reservation.venue_id,
    'cancel_reservation',
    jsonb_build_object('reservation_id', p_reservation)
  );
  if v_result is not null then return v_result; end if;
  if v_reservation.status <> 'confirmed' then
    raise exception 'RESERVATION_NOT_CONFIRMED';
  end if;
  if v_reservation.starts_at <= now() then
    raise exception 'RESERVATION_ALREADY_STARTED';
  end if;

  update reservations
     set status = 'cancelled'
   where id = v_reservation.id
   returning * into v_reservation;
  perform app.audit(
    v_reservation.venue_id, 'reservation_cancelled', 'reservation',
    v_reservation.id::text, jsonb_build_object('customer_id', v_customer.id)
  );
  return app.end_op(
    p_op,
    jsonb_build_object('id', v_reservation.id, 'status', v_reservation.status)
  );
end
$$;

create or replace function public.set_reservation_status(
  p_op uuid,
  p_reservation uuid,
  p_status text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reservation reservations;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into v_reservation
    from reservations
   where id = p_reservation
   for update;
  if v_reservation.id is null then raise exception 'RESERVATION_NOT_FOUND'; end if;
  if not app.is_admin(v_reservation.venue_id) then raise exception 'FORBIDDEN'; end if;
  if p_status is null or p_status not in ('cancelled', 'completed', 'no_show') then
    raise exception 'INVALID_RESERVATION_STATUS';
  end if;

  v_result := app.begin_op(
    p_op,
    v_reservation.venue_id,
    'set_reservation_status',
    jsonb_build_object('reservation_id', p_reservation, 'status', p_status)
  );
  if v_result is not null then return v_result; end if;
  if v_reservation.status <> 'confirmed' then
    raise exception 'RESERVATION_NOT_CONFIRMED';
  end if;

  update reservations
     set status = p_status
   where id = v_reservation.id
   returning * into v_reservation;
  perform app.audit(
    v_reservation.venue_id, 'reservation_' || p_status, 'reservation',
    v_reservation.id::text, jsonb_build_object('customer_id', v_reservation.customer_id)
  );
  return app.end_op(
    p_op,
    jsonb_build_object('id', v_reservation.id, 'status', v_reservation.status)
  );
end
$$;

revoke all on function public.reserve_post(uuid,uuid,timestamptz,int)
  from public, anon;
revoke all on function public.cancel_reservation(uuid,uuid)
  from public, anon;
revoke all on function public.set_reservation_status(uuid,uuid,text)
  from public, anon;
grant execute on function public.reserve_post(uuid,uuid,timestamptz,int)
  to authenticated;
grant execute on function public.cancel_reservation(uuid,uuid)
  to authenticated;
grant execute on function public.set_reservation_status(uuid,uuid,text)
  to authenticated;
