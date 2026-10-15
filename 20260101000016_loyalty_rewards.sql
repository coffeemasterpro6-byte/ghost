create table loyalty_transactions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid not null references customers(id),
  delta integer not null check (delta <> 0),
  reason text not null check (
    reason in ('invoice_earned', 'reward_redeemed', 'reward_refunded')
  ),
  invoice_id uuid references invoices(id),
  redemption_id uuid,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (
    (reason = 'invoice_earned' and delta > 0 and invoice_id is not null)
    or
    (reason = 'reward_redeemed' and delta < 0 and redemption_id is not null)
    or
    (reason = 'reward_refunded' and delta > 0 and redemption_id is not null)
  )
);
create unique index loyalty_invoice_once_idx
  on loyalty_transactions(invoice_id)
  where reason = 'invoice_earned';
create unique index loyalty_redemption_once_idx
  on loyalty_transactions(redemption_id, reason)
  where redemption_id is not null;
create index loyalty_customer_history_idx
  on loyalty_transactions(customer_id, created_at desc);

create table loyalty_rewards (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  description text,
  points_cost integer not null check (points_cost > 0),
  stock_quantity integer check (stock_quantity is null or stock_quantity >= 0),
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index loyalty_rewards_venue_idx on loyalty_rewards(venue_id, is_active);

create table loyalty_redemptions (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid not null references customers(id),
  reward_id uuid not null references loyalty_rewards(id),
  status text not null default 'pending'
    check (status in ('pending', 'fulfilled', 'rejected')),
  points_cost integer not null check (points_cost > 0),
  note text,
  handled_by uuid references auth.users(id),
  handled_at timestamptz,
  created_at timestamptz not null default now()
);
create index loyalty_redemptions_customer_idx
  on loyalty_redemptions(customer_id, created_at desc);
create index loyalty_redemptions_pending_idx
  on loyalty_redemptions(venue_id, created_at)
  where status = 'pending';
alter table loyalty_transactions
  add constraint loyalty_transaction_redemption_fk
  foreign key (redemption_id) references loyalty_redemptions(id);

create view loyalty_balances with (security_invoker = true) as
  select c.id as customer_id,
         c.venue_id,
         coalesce(sum(t.delta), 0)::bigint as points_balance
    from customers c
    left join loyalty_transactions t on t.customer_id = c.id
   group by c.id, c.venue_id;

alter table loyalty_transactions enable row level security;
alter table loyalty_rewards enable row level security;
alter table loyalty_redemptions enable row level security;
create policy loyalty_transactions_staff_read on loyalty_transactions
  for select using (app.is_staff(venue_id));
create policy loyalty_transactions_customer_read on loyalty_transactions
  for select using (
    exists (
      select 1 from customers c
       where c.id = loyalty_transactions.customer_id
         and c.user_id = auth.uid()
    )
  );
create policy loyalty_rewards_member_read on loyalty_rewards
  for select using (is_active and app.is_member(venue_id));
create policy loyalty_rewards_staff_read on loyalty_rewards
  for select using (app.is_staff(venue_id));
create policy loyalty_rewards_admin_write on loyalty_rewards
  for all using (app.is_admin(venue_id))
  with check (app.is_admin(venue_id));
create policy loyalty_redemptions_staff_read on loyalty_redemptions
  for select using (app.is_staff(venue_id));
create policy loyalty_redemptions_customer_read on loyalty_redemptions
  for select using (
    exists (
      select 1 from customers c
       where c.id = loyalty_redemptions.customer_id
         and c.user_id = auth.uid()
    )
  );
grant select on loyalty_transactions, loyalty_rewards, loyalty_redemptions,
  loyalty_balances to authenticated;
grant insert, update, delete on loyalty_rewards to authenticated;

create trigger loyalty_rewards_rt
after insert or update or delete on loyalty_rewards
for each row execute function app.broadcast_row('loyalty');
create trigger loyalty_rewards_audit
after insert or update or delete on loyalty_rewards
for each row execute function app.audit_row();

create or replace function app.award_invoice_loyalty_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_points integer;
  v_user uuid;
begin
  if new.customer_id is null then return new; end if;
  v_points := floor(new.total / 100)::integer;
  if v_points <= 0 then return new; end if;

  insert into loyalty_transactions(
    venue_id, customer_id, delta, reason, invoice_id
  )
  values (
    new.venue_id, new.customer_id, v_points, 'invoice_earned', new.id
  )
  on conflict (invoice_id) where reason = 'invoice_earned' do nothing;

  select user_id into v_user
    from customers
   where id = new.customer_id and venue_id = new.venue_id;
  if v_user is not null then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      new.venue_id, v_user, 'loyalty_points_earned',
      'Points de fidélité gagnés',
      v_points::text || ' point(s) crédité(s)',
      'invoice', new.id,
      jsonb_build_object('points', v_points, 'invoice_id', new.id)
    );
  end if;
  return new;
end
$$;
create trigger invoices_loyalty_points
after insert on invoices
for each row execute function app.award_invoice_loyalty_points();
revoke all on function app.award_invoice_loyalty_points()
  from public, anon, authenticated;

create or replace function public.redeem_loyalty_reward(
  p_op uuid,
  p_customer uuid,
  p_reward uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c customers;
  rw loyalty_rewards;
  v_points bigint;
  v_redemption loyalty_redemptions;
  v_staff record;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into c
    from customers
   where id = p_customer and user_id = auth.uid()
   for update;
  if c.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if not exists (
    select 1 from venue_members
     where venue_id = c.venue_id and user_id = auth.uid()
       and role = 'customer' and is_active
  ) then
    raise exception 'FORBIDDEN';
  end if;
  r := app.begin_op(
    p_op, c.venue_id, 'redeem_loyalty_reward',
    jsonb_build_object('customer_id', c.id, 'reward_id', p_reward)
  );
  if r is not null then return r; end if;

  select * into rw
    from loyalty_rewards
   where id = p_reward and venue_id = c.venue_id and is_active
   for update;
  if rw.id is null then raise exception 'REWARD_NOT_AVAILABLE'; end if;
  if rw.stock_quantity is not null and rw.stock_quantity < 1 then
    raise exception 'REWARD_OUT_OF_STOCK';
  end if;
  select coalesce(sum(delta), 0) into v_points
    from loyalty_transactions where customer_id = c.id;
  if v_points < rw.points_cost then raise exception 'INSUFFICIENT_LOYALTY_POINTS'; end if;

  insert into loyalty_redemptions(
    venue_id, customer_id, reward_id, points_cost
  )
  values (c.venue_id, c.id, rw.id, rw.points_cost)
  returning * into v_redemption;
  insert into loyalty_transactions(
    venue_id, customer_id, delta, reason, redemption_id, created_by
  )
  values (
    c.venue_id, c.id, -rw.points_cost, 'reward_redeemed',
    v_redemption.id, auth.uid()
  );
  if rw.stock_quantity is not null then
    update loyalty_rewards
       set stock_quantity = stock_quantity - 1
     where id = rw.id;
  end if;

  for v_staff in
    select user_id from venue_members
     where venue_id = c.venue_id and is_active
       and role in ('owner', 'manager', 'employee')
  loop
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      c.venue_id, v_staff.user_id, 'loyalty_reward_requested',
      'Récompense demandée',
      c.full_name || ' · ' || rw.name,
      'loyalty_redemption', v_redemption.id,
      jsonb_build_object('redemption_id', v_redemption.id)
    );
  end loop;
  perform app.audit(
    c.venue_id, 'loyalty_reward_requested', 'loyalty_redemption',
    v_redemption.id::text,
    jsonb_build_object('customer_id', c.id, 'reward_id', rw.id)
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'redemption_id', v_redemption.id,
      'status', v_redemption.status,
      'points_balance', v_points - rw.points_cost
    )
  );
end
$$;

create or replace function public.decide_loyalty_redemption(
  p_op uuid,
  p_redemption uuid,
  p_approve boolean,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d loyalty_redemptions;
  rw loyalty_rewards;
  v_customer_user uuid;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into d from loyalty_redemptions
   where id = p_redemption for update;
  if d.id is null then raise exception 'REDEMPTION_NOT_FOUND'; end if;
  if not app.is_staff(d.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(
    p_op, d.venue_id, 'decide_loyalty_redemption',
    jsonb_build_object(
      'redemption_id', d.id, 'approve', p_approve, 'note', p_note
    )
  );
  if r is not null then return r; end if;
  if d.status <> 'pending' then raise exception 'REDEMPTION_ALREADY_HANDLED'; end if;

  update loyalty_redemptions
     set status = case when p_approve then 'fulfilled' else 'rejected' end,
         note = nullif(trim(p_note), ''),
         handled_by = auth.uid(),
         handled_at = now()
   where id = d.id
   returning * into d;
  if not p_approve then
    insert into loyalty_transactions(
      venue_id, customer_id, delta, reason, redemption_id, created_by
    )
    values (
      d.venue_id, d.customer_id, d.points_cost,
      'reward_refunded', d.id, auth.uid()
    );
    select * into rw from loyalty_rewards where id = d.reward_id for update;
    if rw.stock_quantity is not null then
      update loyalty_rewards
         set stock_quantity = stock_quantity + 1
       where id = rw.id;
    end if;
  end if;

  select user_id into v_customer_user from customers where id = d.customer_id;
  if v_customer_user is not null then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      d.venue_id, v_customer_user,
      case when p_approve then 'loyalty_reward_fulfilled'
           else 'loyalty_reward_rejected' end,
      case when p_approve then 'Récompense disponible'
           else 'Demande de récompense refusée' end,
      coalesce(nullif(trim(p_note), ''), 'Votre demande a été traitée.'),
      'loyalty_redemption', d.id,
      jsonb_build_object('redemption_id', d.id, 'status', d.status)
    );
  end if;
  perform app.audit(
    d.venue_id,
    case when p_approve then 'loyalty_reward_fulfilled'
         else 'loyalty_reward_rejected' end,
    'loyalty_redemption', d.id::text,
    jsonb_build_object('customer_id', d.customer_id, 'note', p_note)
  );
  return app.end_op(
    p_op,
    jsonb_build_object('redemption_id', d.id, 'status', d.status)
  );
end
$$;

revoke all on function public.redeem_loyalty_reward(uuid,uuid,uuid)
  from public, anon;
grant execute on function public.redeem_loyalty_reward(uuid,uuid,uuid)
  to authenticated;
revoke all on function public.decide_loyalty_redemption(uuid,uuid,boolean,text)
  from public, anon;
grant execute on function public.decide_loyalty_redemption(uuid,uuid,boolean,text)
  to authenticated;
