create table promotions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  description text,
  discount_percent numeric(5,2) not null
    check (discount_percent > 0 and discount_percent <= 100),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index promotions_venue_period_idx
  on promotions(venue_id, starts_at, ends_at)
  where is_active;

create table promotion_redemptions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  promotion_id uuid not null references promotions(id),
  session_id uuid not null references sessions(id),
  session_event_id bigint not null references session_events(id),
  discount_amount numeric(12,2) not null check (discount_amount > 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(session_id)
);

alter table promotions enable row level security;
alter table promotion_redemptions enable row level security;
create policy promotions_staff_read on promotions
  for select using (app.is_staff(venue_id));
create policy promotions_admin_write on promotions
  for all using (app.is_admin(venue_id))
  with check (app.is_admin(venue_id));
create policy promotion_redemptions_staff_read on promotion_redemptions
  for select using (app.is_staff(venue_id));
grant select, insert, update, delete on promotions to authenticated;
grant select on promotion_redemptions to authenticated;

create trigger promotions_rt
after insert or update or delete on promotions
for each row execute function app.broadcast_row('promotions');
create trigger promotions_audit
after insert or update or delete on promotions
for each row execute function app.audit_row();

create or replace function public.apply_session_promotion(
  p_op uuid,
  p_session uuid,
  p_promotion uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s sessions;
  p promotions;
  v_subtotal numeric(12,2);
  v_discount numeric(12,2);
  v_event_id bigint;
  v_balance numeric(12,2);
  v_customer_user uuid;
  r jsonb;
begin
  s := app._lock_session(p_session);
  if not app.has_perm(s.venue_id, 'give_discount') then
    raise exception 'FORBIDDEN';
  end if;
  r := app.begin_op(
    p_op,
    s.venue_id,
    'apply_session_promotion',
    jsonb_build_object('session_id', p_session, 'promotion_id', p_promotion)
  );
  if r is not null then return r; end if;
  if s.status <> 'waiting_payment' then
    raise exception 'SESSION_NOT_WAITING_PAYMENT';
  end if;
  if exists (
    select 1 from promotion_redemptions where session_id = s.id
  ) then
    raise exception 'PROMOTION_ALREADY_APPLIED';
  end if;

  select * into p
    from promotions
   where id = p_promotion and venue_id = s.venue_id
   for share;
  if p.id is null then raise exception 'PROMOTION_NOT_FOUND'; end if;
  if not p.is_active or p.starts_at > now() or p.ends_at <= now() then
    raise exception 'PROMOTION_NOT_ACTIVE';
  end if;

  select coalesce(sum(amount), 0)
    into v_subtotal
    from session_events
   where session_id = s.id
     and type in ('match_added', 'time_added')
     and amount > 0;
  v_discount := round(v_subtotal * p.discount_percent / 100, 2);
  if v_discount <= 0 then raise exception 'PROMOTION_NO_ELIGIBLE_CHARGES'; end if;

  insert into session_events(
    venue_id, session_id, type, unit_price, amount, game_id, meta, created_by
  )
  values (
    s.venue_id, s.id, 'discount', v_discount, -v_discount, s.game_id,
    jsonb_build_object(
      'promotion_id', p.id,
      'promotion_name', p.name,
      'discount_percent', p.discount_percent
    ),
    auth.uid()
  )
  returning id into v_event_id;

  insert into promotion_redemptions(
    venue_id, promotion_id, session_id, session_event_id,
    discount_amount, created_by
  )
  values (
    s.venue_id, p.id, s.id, v_event_id, v_discount, auth.uid()
  );

  select user_id into v_customer_user
    from customers where id = s.customer_id;
  if v_customer_user is not null then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      s.venue_id, v_customer_user, 'promotion_applied',
      'Promotion appliquée',
      p.name || ' · ' || v_discount::text || ' DA',
      'session', s.id,
      jsonb_build_object('promotion_id', p.id, 'discount_amount', v_discount)
    );
  end if;

  select balance_due into v_balance from session_bill where session_id = s.id;
  perform app.audit(
    s.venue_id, 'promotion_applied', 'session', s.id::text,
    jsonb_build_object(
      'promotion_id', p.id,
      'promotion_name', p.name,
      'discount_amount', v_discount
    )
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'session_id', s.id,
      'promotion_id', p.id,
      'discount_amount', v_discount,
      'balance_due', v_balance
    )
  );
end
$$;

revoke all on function public.apply_session_promotion(uuid,uuid,uuid)
  from public, anon;
grant execute on function public.apply_session_promotion(uuid,uuid,uuid)
  to authenticated;
