create or replace function public.staff_reserve_post(
  p_op uuid,
  p_post uuid,
  p_customer uuid,
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

  select * into v_post
    from posts
   where id = p_post
   for update;
  if v_post.id is null then raise exception 'POST_NOT_FOUND'; end if;
  if not app.is_admin(v_post.venue_id) then raise exception 'FORBIDDEN'; end if;
  if v_post.status in ('maintenance', 'offline') then
    raise exception 'POST_UNAVAILABLE';
  end if;

  select * into v_customer
    from customers
   where id = p_customer and venue_id = v_post.venue_id;
  if v_customer.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;

  v_result := app.begin_op(
    p_op,
    v_post.venue_id,
    'staff_reserve_post',
    jsonb_build_object(
      'post_id', p_post,
      'customer_id', p_customer,
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
    v_post.venue_id, v_post.id, v_customer.id, p_starts_at, v_ends_at
  )
  returning * into v_reservation;
  perform app.audit(
    v_post.venue_id,
    'reservation_created_by_staff',
    'reservation',
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
      'customer_id', v_reservation.customer_id,
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

revoke all on function public.staff_reserve_post(
  uuid, uuid, uuid, timestamptz, int
) from public, anon;
grant execute on function public.staff_reserve_post(
  uuid, uuid, uuid, timestamptz, int
) to authenticated;
