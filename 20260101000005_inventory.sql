-- Venue-scoped product catalogue with a traceable, atomic stock ledger.
create table product_categories (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  unique (venue_id, name),
  unique (venue_id, id)
);

create table products (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  category_id uuid references product_categories(id) on delete set null,
  name text not null check (length(trim(name)) between 1 and 120),
  image_url text,
  sale_price numeric(12,2) not null check (sale_price >= 0),
  cost_price numeric(12,2) not null default 0 check (cost_price >= 0),
  stock_quantity int not null default 0 check (stock_quantity >= 0),
  minimum_stock int not null default 0 check (minimum_stock >= 0),
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_category_same_venue foreign key (venue_id, category_id)
    references product_categories(venue_id, id) deferrable initially immediate
);

create table inventory_movements (
  id bigint generated always as identity primary key,
  venue_id uuid not null references venues(id) on delete cascade,
  product_id uuid not null references products(id),
  quantity_delta int not null check (quantity_delta <> 0),
  reason text not null check (reason in (
    'sale', 'restock', 'return', 'damage', 'manual_adjustment', 'correction'
  )),
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index products_venue_name_idx on products(venue_id, name);
create index products_low_stock_idx on products(venue_id, stock_quantity)
  where is_available;
create index inventory_movements_product_idx
  on inventory_movements(product_id, created_at desc);

create trigger products_touch before update on products
  for each row execute function app.touch();
create trigger products_audit after insert or update or delete on products
  for each row execute function app.audit_row();
create trigger products_rt after insert or update or delete on products
  for each row execute function app.broadcast_row('inventory');

create or replace function app.products_stock_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' and new.stock_quantity <> 0 then
    raise exception 'INITIAL_STOCK_REQUIRES_MOVEMENT';
  end if;
  if tg_op = 'UPDATE'
     and new.stock_quantity is distinct from old.stock_quantity
     and coalesce(current_setting('app.inventory_rpc', true), '') <> 'on' then
    raise exception 'STOCK_MUTATION_REQUIRES_RPC';
  end if;
  return new;
end
$$;
create trigger products_stock_guard
  before insert or update on products
  for each row execute function app.products_stock_guard();

alter table product_categories enable row level security;
alter table products enable row level security;
alter table inventory_movements enable row level security;

create policy product_categories_staff_read on product_categories
  for select using (app.is_staff(venue_id));
create policy product_categories_admin_write on product_categories
  for all using (app.is_admin(venue_id)) with check (app.is_admin(venue_id));
create policy products_staff_read on products
  for select using (app.is_staff(venue_id));
create policy products_admin_write on products
  for all using (app.is_admin(venue_id)) with check (app.is_admin(venue_id));
create policy inventory_movements_staff_read on inventory_movements
  for select using (app.is_staff(venue_id));

grant select, insert, update, delete on product_categories, products to authenticated;
grant select on inventory_movements to authenticated;

create or replace function public.adjust_product_stock(
  p_op uuid,
  p_product uuid,
  p_delta int,
  p_reason text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p products;
  r jsonb;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_delta is null or p_delta = 0 then raise exception 'INVALID_QUANTITY'; end if;
  if p_reason is null
     or p_reason not in ('restock','return','damage','manual_adjustment','correction') then
    raise exception 'INVALID_MOVEMENT_REASON';
  end if;
  if length(coalesce(p_note, '')) > 500 then raise exception 'NOTE_TOO_LONG'; end if;

  select * into p from products where id = p_product for update;
  if p.id is null then raise exception 'PRODUCT_NOT_FOUND'; end if;
  if not app.has_perm(p.venue_id, 'manage_stock') then raise exception 'FORBIDDEN'; end if;

  r := app.begin_op(
    p_op,
    p.venue_id,
    'adjust_product_stock',
    jsonb_build_object(
      'product_id', p_product,
      'delta', p_delta,
      'reason', p_reason,
      'note', p_note
    )
  );
  if r is not null then return r; end if;
  if p.stock_quantity + p_delta < 0 then raise exception 'INSUFFICIENT_STOCK'; end if;

  perform set_config('app.inventory_rpc', 'on', true);
  update products
    set stock_quantity = stock_quantity + p_delta
    where id = p.id
    returning * into p;
  perform set_config('app.inventory_rpc', 'off', true);

  insert into inventory_movements(
    venue_id, product_id, quantity_delta, reason, note, created_by
  )
  values (p.venue_id, p.id, p_delta, p_reason, nullif(trim(p_note), ''), auth.uid());

  perform app.audit(
    p.venue_id,
    'inventory_adjustment',
    'product',
    p.id::text,
    jsonb_build_object(
      'delta', p_delta,
      'reason', p_reason,
      'stock_quantity', p.stock_quantity
    )
  );

  return app.end_op(
    p_op,
    jsonb_build_object(
      'product_id', p.id,
      'stock_quantity', p.stock_quantity,
      'quantity_delta', p_delta,
      'reason', p_reason
    )
  );
end
$$;

revoke all on function public.adjust_product_stock(uuid,uuid,int,text,text)
  from public, anon;
grant execute on function public.adjust_product_stock(uuid,uuid,int,text,text)
  to authenticated;
