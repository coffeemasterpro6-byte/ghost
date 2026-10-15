-- Informational memberships and prepaid bundles of play minutes and products.
create unique index products_venue_id_id_idx on products(venue_id, id);
alter table inventory_movements
  drop constraint inventory_movements_reason_check;
alter table inventory_movements
  add constraint inventory_movements_reason_check
  check (reason in (
    'sale', 'package_sale', 'restock', 'return', 'damage',
    'manual_adjustment', 'correction'
  ));

create table membership_plans (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  duration_days integer not null check (duration_days between 1 and 3650),
  benefits text not null default '' check (length(benefits) <= 2000),
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (venue_id, id)
);
create index membership_plans_venue_idx
  on membership_plans(venue_id, is_active, name);

create table customer_memberships (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid not null references customers(id),
  plan_id uuid not null references membership_plans(id),
  plan_name text not null,
  benefits text not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index customer_memberships_customer_idx
  on customer_memberships(customer_id, ends_at desc);

create table packages (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 100),
  description text,
  price numeric(12,2) not null check (price > 0),
  gaming_minutes integer not null check (gaming_minutes between 1 and 100000),
  is_active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (venue_id, id)
);
create index packages_venue_idx on packages(venue_id, is_active, price);

create table package_items (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  package_id uuid not null,
  product_id uuid not null,
  quantity integer not null check (quantity between 1 and 100),
  unique (package_id, product_id),
  foreign key (venue_id, package_id)
    references packages(venue_id, id) on delete cascade,
  foreign key (venue_id, product_id)
    references products(venue_id, id)
);
create index package_items_package_idx on package_items(package_id);

create table package_purchases (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  customer_id uuid not null references customers(id),
  package_id uuid not null references packages(id),
  package_name text not null,
  gaming_minutes_remaining integer not null check (gaming_minutes_remaining >= 0),
  expires_at timestamptz not null default (now() + interval '30 days'),
  order_id uuid not null unique references orders(id),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index package_purchases_customer_idx
  on package_purchases(customer_id, created_at desc);

create table package_purchase_items (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  purchase_id uuid not null references package_purchases(id) on delete cascade,
  product_id uuid not null,
  product_name text not null,
  purchased_quantity integer not null check (purchased_quantity > 0),
  remaining_quantity integer not null check (
    remaining_quantity >= 0 and remaining_quantity <= purchased_quantity
  ),
  foreign key (venue_id, product_id)
    references products(venue_id, id)
);
create index package_purchase_items_purchase_idx
  on package_purchase_items(purchase_id);

alter table membership_plans enable row level security;
alter table customer_memberships enable row level security;
alter table packages enable row level security;
alter table package_items enable row level security;
alter table package_purchases enable row level security;
alter table package_purchase_items enable row level security;

create policy membership_plans_member_read on membership_plans
  for select using (is_active and app.is_member(venue_id));
create policy membership_plans_staff_read on membership_plans
  for select using (app.is_staff(venue_id));
create policy membership_plans_admin_write on membership_plans
  for all using (app.is_admin(venue_id))
  with check (app.is_admin(venue_id));
create policy customer_memberships_staff_read on customer_memberships
  for select using (app.is_staff(venue_id));
create policy customer_memberships_customer_read on customer_memberships
  for select using (
    exists (select 1 from customers c
      where c.id = customer_memberships.customer_id and c.user_id = auth.uid())
  );
create policy packages_member_read on packages
  for select using (is_active and app.is_member(venue_id));
create policy packages_staff_read on packages
  for select using (app.is_staff(venue_id));
create policy packages_admin_write on packages
  for all using (app.is_admin(venue_id))
  with check (app.is_admin(venue_id));
create policy package_items_member_read on package_items
  for select using (exists (
    select 1 from packages p
     where p.id = package_items.package_id and p.is_active
       and app.is_member(p.venue_id)
  ));
create policy package_items_staff_read on package_items
  for select using (app.is_staff(venue_id));
create policy package_items_admin_write on package_items
  for all using (app.is_admin(venue_id))
  with check (
    app.is_admin(venue_id)
    and exists (select 1 from packages p
      where p.id = package_items.package_id and p.venue_id = package_items.venue_id)
  );
create policy package_purchases_staff_read on package_purchases
  for select using (app.is_staff(venue_id));
create policy package_purchases_customer_read on package_purchases
  for select using (
    exists (select 1 from customers c
      where c.id = package_purchases.customer_id and c.user_id = auth.uid())
  );
create policy package_purchase_items_staff_read on package_purchase_items
  for select using (app.is_staff(venue_id));
create policy package_purchase_items_customer_read on package_purchase_items
  for select using (exists (
    select 1 from package_purchases pp join customers c on c.id = pp.customer_id
     where pp.id = package_purchase_items.purchase_id and c.user_id = auth.uid()
  ));
grant select, insert, update, delete on membership_plans to authenticated;
grant select on packages, package_items to authenticated;
revoke insert, update, delete on packages, package_items from authenticated;
grant update (is_active) on packages to authenticated;
grant select on customer_memberships, package_purchases, package_purchase_items
  to authenticated;

create trigger membership_plans_audit
after insert or update or delete on membership_plans
for each row execute function app.audit_row();
create trigger membership_plans_rt
after insert or update or delete on membership_plans
for each row execute function app.broadcast_row('programs');
create trigger packages_audit
after insert or update or delete on packages
for each row execute function app.audit_row();
create trigger packages_rt
after insert or update or delete on packages
for each row execute function app.broadcast_row('programs');
create trigger package_items_rt
after insert or update or delete on package_items
for each row execute function app.broadcast_row('programs');
create trigger customer_memberships_rt
after insert on customer_memberships
for each row execute function app.broadcast_row('programs');
create trigger package_purchases_rt
after insert or update on package_purchases
for each row execute function app.broadcast_row('programs');
create trigger package_purchase_items_rt
after update on package_purchase_items
for each row execute function app.broadcast_row('programs');

create or replace function app.can_listen(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  parts text[] := string_to_array(p_topic, ':');
begin
  if parts[1] = 'venue' and array_length(parts, 1) = 3 then
    return case
      when parts[3] in ('catalog', 'inventory', 'programs')
        then app.is_member(parts[2]::uuid)
      else app.is_staff(parts[2]::uuid)
    end;
  elsif parts[1] = 'session' then
    return exists (
      select 1
        from sessions s
       where s.id = parts[2]::uuid
         and (
           app.is_staff(s.venue_id)
           or exists (
             select 1
               from customers c
              where c.id = s.customer_id
                and c.user_id = auth.uid()
           )
         )
    );
  elsif parts[1] = 'user' then
    return parts[2]::uuid = auth.uid();
  end if;
  return false;
exception when others then
  return false;
end
$$;

create or replace function public.save_program_package(
  p_op uuid,
  p_package uuid,
  p_name text,
  p_description text,
  p_price numeric,
  p_gaming_minutes integer,
  p_items jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venue uuid;
  v_package uuid;
  v_item record;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'INVALID_PACKAGE_ITEMS';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'INVALID_PACKAGE_ITEMS';
  end if;
  if p_name is null or length(trim(p_name)) not between 1 and 100
     or p_price is null or p_price <= 0 or p_price > 1000000000
     or p_price <> round(p_price, 2)
     or p_gaming_minutes is null or p_gaming_minutes < 1
     or p_gaming_minutes > 100000
     or length(coalesce(p_description, '')) > 2000 then
    raise exception 'INVALID_PACKAGE';
  end if;
  select m.venue_id into v_venue
    from venue_members m
   where m.user_id = auth.uid() and m.is_active
     and m.role in ('owner', 'manager')
   order by m.created_at limit 1;
  if v_venue is null then raise exception 'FORBIDDEN'; end if;
  if exists (
    select product_id
      from jsonb_to_recordset(p_items) as item(product_id uuid, quantity integer)
     group by product_id having count(*) > 1
  ) then raise exception 'DUPLICATE_PACKAGE_PRODUCT'; end if;
  if exists (
    select 1
      from jsonb_to_recordset(p_items) as item(product_id uuid, quantity integer)
     where item.product_id is null or item.quantity is null
        or item.quantity < 1 or item.quantity > 100
        or not exists (
          select 1 from products p
           where p.id = item.product_id and p.venue_id = v_venue
             and p.is_available
        )
  ) then raise exception 'INVALID_PACKAGE_PRODUCT'; end if;
  r := app.begin_op(
    p_op, v_venue, 'save_program_package',
    jsonb_build_object(
      'package_id', p_package, 'name', trim(p_name),
      'description', p_description, 'price', p_price,
      'gaming_minutes', p_gaming_minutes, 'items', p_items
    )
  );
  if r is not null then return r; end if;
  if p_package is null then
    insert into packages(
      venue_id, name, description, price, gaming_minutes, created_by
    )
    values (
      v_venue, trim(p_name), nullif(trim(p_description), ''),
      round(p_price, 2), p_gaming_minutes, auth.uid()
    ) returning id into v_package;
  else
    update packages
       set name = trim(p_name),
           description = nullif(trim(p_description), ''),
           price = round(p_price, 2),
           gaming_minutes = p_gaming_minutes
     where id = p_package and venue_id = v_venue
     returning id into v_package;
    if v_package is null then raise exception 'PACKAGE_NOT_FOUND'; end if;
  end if;
  delete from package_items where package_id = v_package;
  insert into package_items(venue_id, package_id, product_id, quantity)
  select v_venue, v_package, item.product_id, item.quantity
    from jsonb_to_recordset(p_items) as item(product_id uuid, quantity integer);
  return app.end_op(
    p_op, jsonb_build_object('package_id', v_package)
  );
end
$$;

create or replace function public.assign_customer_membership(
  p_op uuid,
  p_customer uuid,
  p_plan uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c customers;
  pl membership_plans;
  m customer_memberships;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  select * into c from customers where id = p_customer for update;
  if c.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if not app.is_admin(c.venue_id) then raise exception 'FORBIDDEN'; end if;
  select * into pl from membership_plans
   where id = p_plan and venue_id = c.venue_id and is_active for update;
  if pl.id is null then raise exception 'MEMBERSHIP_PLAN_NOT_AVAILABLE'; end if;
  r := app.begin_op(
    p_op, c.venue_id, 'assign_customer_membership',
    jsonb_build_object('customer_id', c.id, 'plan_id', pl.id)
  );
  if r is not null then return r; end if;
  if exists (
    select 1 from customer_memberships
     where customer_id = c.id and starts_at <= now() and ends_at > now()
  ) then raise exception 'MEMBERSHIP_ALREADY_ACTIVE'; end if;
  insert into customer_memberships(
    venue_id, customer_id, plan_id, plan_name, benefits, starts_at, ends_at,
    created_by
  )
  values (
    c.venue_id, c.id, pl.id, pl.name, pl.benefits, now(),
    now() + make_interval(days => pl.duration_days), auth.uid()
  ) returning * into m;
  if c.user_id is not null then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      c.venue_id, c.user_id, 'membership_activated',
      'Votre adhésion est active', pl.name,
      'membership', m.id,
      jsonb_build_object('ends_at', m.ends_at)
    );
  end if;
  perform app.audit(
    c.venue_id, 'membership_activated', 'customer_membership', m.id::text,
    jsonb_build_object('customer_id', c.id, 'plan_id', pl.id)
  );
  return app.end_op(
    p_op,
    jsonb_build_object('membership_id', m.id, 'ends_at', m.ends_at)
  );
end
$$;

create or replace function public.sell_customer_package(
  p_op uuid,
  p_customer uuid,
  p_package uuid,
  p_method payment_method
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c customers;
  pk packages;
  o orders;
  inv invoices;
  v_item record;
  v_purchase package_purchases;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_method is null or p_method not in ('cash', 'card') then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;
  select * into c from customers where id = p_customer for update;
  if c.id is null then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if not app.is_staff(c.venue_id) then raise exception 'FORBIDDEN'; end if;
  select * into pk from packages
   where id = p_package and venue_id = c.venue_id and is_active for update;
  if pk.id is null then raise exception 'PACKAGE_NOT_AVAILABLE'; end if;
  r := app.begin_op(
    p_op, c.venue_id, 'sell_customer_package',
    jsonb_build_object(
      'customer_id', c.id, 'package_id', pk.id, 'method', p_method
    )
  );
  if r is not null then return r; end if;

  insert into orders(venue_id, customer_id, status, total, created_by)
  values (c.venue_id, c.id, 'paid', pk.price, auth.uid())
  returning * into o;
  insert into package_purchases(
    venue_id, customer_id, package_id, package_name,
    gaming_minutes_remaining, order_id, created_by
  )
  values (
    c.venue_id, c.id, pk.id, pk.name, pk.gaming_minutes, o.id, auth.uid()
  ) returning * into v_purchase;

  perform set_config('app.inventory_rpc', 'on', true);
  for v_item in
    select pi.product_id, pi.quantity, p.name, p.stock_quantity, p.is_available
      from package_items pi
      join products p on p.id = pi.product_id and p.venue_id = pi.venue_id
     where pi.package_id = pk.id
     order by pi.product_id
     for update of p
  loop
    if not v_item.is_available then raise exception 'PACKAGE_PRODUCT_NOT_AVAILABLE'; end if;
    if v_item.stock_quantity < v_item.quantity then raise exception 'INSUFFICIENT_STOCK'; end if;
    update products
       set stock_quantity = stock_quantity - v_item.quantity
     where id = v_item.product_id;
    insert into inventory_movements(
      venue_id, product_id, quantity_delta, reason, note, created_by
    )
    values (
      c.venue_id, v_item.product_id, -v_item.quantity,
      'package_sale', pk.name, auth.uid()
    );
    insert into package_purchase_items(
      venue_id, purchase_id, product_id, product_name,
      purchased_quantity, remaining_quantity
    )
    values (
      c.venue_id, v_purchase.id, v_item.product_id, v_item.name,
      v_item.quantity, v_item.quantity
    );
  end loop;
  perform set_config('app.inventory_rpc', 'off', true);

  insert into payments(venue_id, order_id, method, amount, created_by)
  values (c.venue_id, o.id, p_method, pk.price, auth.uid());
  insert into invoices(venue_id, order_id, customer_id, total, created_by)
  values (c.venue_id, o.id, c.id, pk.price, auth.uid())
  returning * into inv;
  if c.user_id is not null then
    insert into notifications(
      venue_id, recipient_id, type, title, body,
      reference_type, reference_id, data
    )
    values (
      c.venue_id, c.user_id, 'package_purchased',
      'Forfait activé', pk.name,
      'package_purchase', v_purchase.id,
      jsonb_build_object(
        'gaming_minutes', pk.gaming_minutes,
        'order_id', o.id,
        'invoice_id', inv.id
      )
    );
  end if;
  perform app.audit(
    c.venue_id, 'package_sold', 'package_purchase', v_purchase.id::text,
    jsonb_build_object(
      'customer_id', c.id, 'package_id', pk.id,
      'total', pk.price, 'invoice_id', inv.id
    )
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'purchase_id', v_purchase.id, 'order_id', o.id,
      'invoice_id', inv.id, 'invoice_number', inv.number, 'total', pk.price
    )
  );
end
$$;

create or replace function public.redeem_package_minutes(
  p_op uuid,
  p_purchase uuid,
  p_session uuid,
  p_minutes integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pp package_purchases;
  s sessions;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 600 then
    raise exception 'INVALID_DURATION';
  end if;
  select * into pp from package_purchases where id = p_purchase for update;
  if pp.id is null then raise exception 'PACKAGE_PURCHASE_NOT_FOUND'; end if;
  if pp.expires_at <= now() then raise exception 'PACKAGE_EXPIRED'; end if;
  select * into s from sessions where id = p_session for update;
  if s.id is null then raise exception 'SESSION_NOT_FOUND'; end if;
  if s.venue_id <> pp.venue_id or s.customer_id <> pp.customer_id then
    raise exception 'PACKAGE_SESSION_MISMATCH';
  end if;
  if s.status <> 'active' then raise exception 'SESSION_NOT_ACTIVE'; end if;
  if exists (select 1 from games g
    where g.id = s.game_id and g.game_mode = 'match_based') then
    raise exception 'GAME_NOT_TIME_BASED';
  end if;
  if not app.is_staff(s.venue_id) and not exists (
    select 1 from customers c where c.id = pp.customer_id and c.user_id = auth.uid()
  ) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(
    p_op, s.venue_id, 'redeem_package_minutes',
    jsonb_build_object(
      'purchase_id', pp.id, 'session_id', s.id, 'minutes', p_minutes
    )
  );
  if r is not null then return r; end if;
  if pp.gaming_minutes_remaining < p_minutes then
    raise exception 'INSUFFICIENT_PACKAGE_MINUTES';
  end if;
  update package_purchases
     set gaming_minutes_remaining = gaming_minutes_remaining - p_minutes
   where id = pp.id;
  insert into session_events(
    venue_id, session_id, type, minutes, unit_price, amount,
    added_seconds, game_id, meta, created_by
  )
  values (
    s.venue_id, s.id, 'time_added', p_minutes, 0, 0,
    p_minutes * 60, s.game_id,
    jsonb_build_object('package_purchase_id', pp.id, 'package_minutes', p_minutes),
    auth.uid()
  );
  update sessions
     set planned_duration_seconds = planned_duration_seconds + p_minutes * 60,
         version = version + 1, updated_at = now()
   where id = s.id;
  perform app.audit(
    s.venue_id, 'package_minutes_redeemed', 'session', s.id::text,
    jsonb_build_object('purchase_id', pp.id, 'minutes', p_minutes)
  );
  return app.end_op(
    p_op,
    jsonb_build_object(
      'minutes_remaining', pp.gaming_minutes_remaining - p_minutes
    )
  );
end
$$;

create or replace function public.redeem_package_product(
  p_op uuid,
  p_purchase_item uuid,
  p_quantity integer default 1
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  pi package_purchase_items;
  pp package_purchases;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 100 then
    raise exception 'INVALID_QUANTITY';
  end if;
  select * into pi from package_purchase_items
   where id = p_purchase_item for update;
  if pi.id is null then raise exception 'PACKAGE_ITEM_NOT_FOUND'; end if;
  select * into pp from package_purchases where id = pi.purchase_id for update;
  if pp.id is null then raise exception 'PACKAGE_PURCHASE_NOT_FOUND'; end if;
  if pp.expires_at <= now() then raise exception 'PACKAGE_EXPIRED'; end if;
  if not app.is_staff(pp.venue_id) then raise exception 'FORBIDDEN'; end if;
  r := app.begin_op(
    p_op, pp.venue_id, 'redeem_package_product',
    jsonb_build_object('purchase_item_id', pi.id, 'quantity', p_quantity)
  );
  if r is not null then return r; end if;
  if pi.remaining_quantity < p_quantity then
    raise exception 'INSUFFICIENT_PACKAGE_PRODUCTS';
  end if;
  update package_purchase_items
     set remaining_quantity = remaining_quantity - p_quantity
   where id = pi.id;
  perform app.audit(
    pp.venue_id, 'package_product_redeemed', 'package_purchase', pp.id::text,
    jsonb_build_object('product_id', pi.product_id, 'quantity', p_quantity)
  );
  return app.end_op(
    p_op,
    jsonb_build_object('remaining_quantity', pi.remaining_quantity - p_quantity)
  );
end
$$;

revoke all on function public.save_program_package(uuid,uuid,text,text,numeric,integer,jsonb)
  from public, anon;
grant execute on function public.save_program_package(uuid,uuid,text,text,numeric,integer,jsonb)
  to authenticated;
revoke all on function public.assign_customer_membership(uuid,uuid,uuid)
  from public, anon;
grant execute on function public.assign_customer_membership(uuid,uuid,uuid)
  to authenticated;
revoke all on function public.sell_customer_package(uuid,uuid,uuid,payment_method)
  from public, anon;
grant execute on function public.sell_customer_package(uuid,uuid,uuid,payment_method)
  to authenticated;
revoke all on function public.redeem_package_minutes(uuid,uuid,uuid,integer)
  from public, anon;
grant execute on function public.redeem_package_minutes(uuid,uuid,uuid,integer)
  to authenticated;
revoke all on function public.redeem_package_product(uuid,uuid,integer)
  from public, anon;
grant execute on function public.redeem_package_product(uuid,uuid,integer)
  to authenticated;
