-- 028 ENABLE REALTIME FOR NOTIFICATIONS TABLE
-- Ensures that Postgres changes on notifications table are streamed to connected clients via Supabase Realtime.

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1
      from pg_publication_rel pr
      join pg_class c on c.oid = pr.prrelid
      join pg_publication p on p.oid = pr.prpubid
      where p.pubname = 'supabase_realtime' and c.relname = 'notifications'
    ) then
      alter publication supabase_realtime add table notifications;
    end if;
  end if;
end $$;
