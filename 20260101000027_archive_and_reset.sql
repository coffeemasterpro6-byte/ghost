-- 027 ARCHIVE & RESET ENGINE — Atomic venue transactional data wipe while preserving master records
-- Preserves: venues, venue_members, profiles, customers, customer_balances, posts, post_games, post_game_prices, games, products, product_categories, promotions, packages, loyalty_rewards

create or replace function public.archive_and_reset_venue_data(
  p_op uuid,
  p_venue_id uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  r jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED';
  end if;

  select role into v_role
    from venue_members
   where venue_id = p_venue_id
     and user_id = auth.uid()
     and is_active = true
   limit 1;

  if v_role is null or v_role not in ('owner', 'manager') then
    raise exception 'FORBIDDEN';
  end if;

  r := app.begin_op(p_op, p_venue_id, 'archive_and_reset_venue_data', jsonb_build_object('venue_id', p_venue_id));
  if r is not null then return r; end if;

  -- 1. Delete transactional order & session requests
  delete from customer_order_requests where venue_id = p_venue_id;
  delete from session_requests where venue_id = p_venue_id;

  -- 2. Delete session events, matches, timelines & sessions
  delete from session_events where venue_id = p_venue_id;
  delete from session_matches where session_id in (select id from sessions where venue_id = p_venue_id);
  delete from sessions where venue_id = p_venue_id;

  -- 3. Delete order items, orders, payments & invoices
  delete from order_items where order_id in (select id from orders where venue_id = p_venue_id);
  delete from payments where venue_id = p_venue_id;
  delete from invoices where venue_id = p_venue_id;
  delete from orders where venue_id = p_venue_id;

  -- 4. Delete customer ledger history (wallet balance & credit limits in customer_balances remain intact!)
  delete from customer_ledger_entries where customer_id in (select id from customers where venue_id = p_venue_id);

  -- 5. Delete inventory movements history (products stock_quantity remains intact!)
  delete from inventory_movements where venue_id = p_venue_id;

  -- 6. Delete shift transactions & cash shifts
  delete from shift_transactions where shift_id in (select id from shifts where venue_id = p_venue_id);
  delete from shifts where venue_id = p_venue_id;

  -- 7. Delete expenses
  delete from expenses where venue_id = p_venue_id;

  -- 8. Delete reservations
  delete from reservations where venue_id = p_venue_id;

  -- 9. Delete redemptions & history
  delete from promotion_redemptions where venue_id = p_venue_id;
  delete from package_purchase_items where purchase_id in (select id from package_purchases where venue_id = p_venue_id);
  delete from package_purchases where venue_id = p_venue_id;
  delete from loyalty_redemptions where venue_id = p_venue_id;
  delete from loyalty_transactions where venue_id = p_venue_id;

  -- 10. Delete notifications & operational audit logs
  delete from notifications where venue_id = p_venue_id;
  delete from audit_logs where venue_id = p_venue_id;

  -- Reset posts status back to available
  update posts set status = 'available' where venue_id = p_venue_id and status <> 'maintenance';

  perform app.audit(p_venue_id, 'archive_and_reset', 'venue', p_venue_id::text, jsonb_build_object('reset_at', now()));

  return app.end_op(p_op, jsonb_build_object('success', true, 'reset_at', now()));
end;
$$;

grant execute on function public.archive_and_reset_venue_data(uuid, uuid) to authenticated;
