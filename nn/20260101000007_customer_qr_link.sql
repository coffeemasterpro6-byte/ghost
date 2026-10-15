-- Verified customer accounts can link themselves to a venue by scanning a post QR.
-- The QR identifies the post; the verified Supabase phone identity authorizes the link.
create or replace function public.link_customer_to_post(p_qr_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_phone text;
  v_phone_confirmed_at timestamptz;
  v_name text;
  v_post posts;
  v_member venue_members;
  v_customer customers;
begin
  if v_user is null then
    raise exception 'UNAUTHENTICATED';
  end if;
  if nullif(trim(p_qr_token), '') is null then
    raise exception 'POST_QR_INVALID';
  end if;

  select phone, email, raw_user_meta_data ->> 'full_name'
    into v_phone, v_name, v_name
    from auth.users
   where id = v_user;

  select * into v_post
    from posts
   where qr_token = trim(p_qr_token);
  if v_post.id is null then
    raise exception 'POST_QR_NOT_FOUND';
  end if;
  if v_post.status in ('maintenance', 'offline') then
    raise exception 'POST_UNAVAILABLE';
  end if;

  select * into v_member
    from venue_members
   where venue_id = v_post.venue_id and user_id = v_user
   for update;
  if v_member.venue_id is not null and v_member.role <> 'customer' then
    raise exception 'VENUE_MEMBER_ROLE_CONFLICT';
  end if;
  if v_member.venue_id is not null and not v_member.is_active then
    raise exception 'VENUE_ACCESS_REVOKED';
  end if;
  if v_member.venue_id is null then
    insert into venue_members(venue_id, user_id, role)
    values (v_post.venue_id, v_user, 'customer')
    on conflict (venue_id, user_id) do nothing;
    select * into v_member
      from venue_members
     where venue_id = v_post.venue_id and user_id = v_user
     for update;
    if v_member.role <> 'customer' then
      raise exception 'VENUE_MEMBER_ROLE_CONFLICT';
    end if;
    if not v_member.is_active then
      raise exception 'VENUE_ACCESS_REVOKED';
    end if;
  end if;

  select * into v_customer
    from customers
   where venue_id = v_post.venue_id and user_id = v_user
   for update;
  if v_customer.id is null then
    select * into v_customer
      from customers
     where venue_id = v_post.venue_id and phone = v_phone
     for update;
    if v_customer.id is not null then
      if v_customer.user_id is not null and v_customer.user_id <> v_user then
        raise exception 'CUSTOMER_ACCOUNT_ALREADY_LINKED';
      end if;
      update customers
         set user_id = v_user
       where id = v_customer.id
       returning * into v_customer;
    else
      v_name := nullif(trim((select raw_user_meta_data ->> 'full_name'
                               from auth.users where id = v_user)), '');
      insert into customers(venue_id, user_id, full_name, phone)
      values (v_post.venue_id, v_user, coalesce(v_name, 'Client'), v_phone)
      on conflict (venue_id, user_id)
      do update set user_id = excluded.user_id
      returning * into v_customer;
    end if;
  end if;

  return jsonb_build_object(
    'venue_id', v_post.venue_id,
    'venue_name', (select name from venues where id = v_post.venue_id),
    'post_id', v_post.id,
    'post_name', v_post.name,
    'customer_id', v_customer.id
  );
exception
  when unique_violation then
    raise exception 'CUSTOMER_ACCOUNT_ALREADY_LINKED';
end
$$;

revoke all on function public.link_customer_to_post(text) from public, anon;
grant execute on function public.link_customer_to_post(text) to authenticated;

-- Wake a linked customer's app when staff starts a session for their account.
create or replace function app.notify_customer_session_started()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recipient uuid;
  v_post_name text;
begin
  if new.customer_id is null then
    return new;
  end if;

  select user_id into v_recipient
    from customers
   where id = new.customer_id;
  if v_recipient is null then
    return new;
  end if;

  select name into v_post_name
    from posts
   where id = new.post_id;
  insert into notifications(
    venue_id, recipient_id, type, title, body, reference_type, reference_id, data
  )
  values (
    new.venue_id,
    v_recipient,
    'session_started',
    'Votre session a démarré',
    coalesce(v_post_name, 'Votre poste'),
    'session',
    new.id,
    jsonb_build_object('session_id', new.id, 'post_id', new.post_id)
  );
  return new;
end
$$;

create trigger customer_session_started_notification
after insert on sessions
for each row execute function app.notify_customer_session_started();

revoke all on function app.notify_customer_session_started()
  from public, anon, authenticated;
