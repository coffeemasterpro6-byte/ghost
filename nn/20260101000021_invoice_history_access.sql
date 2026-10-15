create policy invoices_customer_read on invoices
  for select using (
    customer_id is not null
    and exists (
      select 1 from customers c
      where c.id = invoices.customer_id and c.user_id = auth.uid()
    )
  );

create or replace function app.broadcast_invoice_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  customer_user uuid;
begin
  if new.customer_id is null then return new; end if;
  select user_id into customer_user from customers where id = new.customer_id;
  if customer_user is not null then
    perform realtime.broadcast_changes(
      'user:' || customer_user,
      tg_op,
      tg_op,
      tg_table_name,
      tg_table_schema,
      new,
      old
    );
  end if;
  return new;
end
$$;

revoke all on function app.broadcast_invoice_user()
  from public, anon, authenticated;

create trigger invoices_customer_realtime
  after insert on invoices
  for each row execute function app.broadcast_invoice_user();
